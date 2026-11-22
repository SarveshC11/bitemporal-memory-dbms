--
-- PostgreSQL database dump
--

\restrict p8zBF12QJWwCFRrM6su3bQSqNA32RqgB8napHvuXGYW3fwDsg2FPgyrIsVYDwBB

-- Dumped from database version 16.14 (Homebrew)
-- Dumped by pg_dump version 16.14 (Homebrew)

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: btree_gist; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS btree_gist WITH SCHEMA public;


--
-- Name: EXTENSION btree_gist; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON EXTENSION btree_gist IS 'support for indexing common datatypes in GiST';


--
-- Name: pg_trgm; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS pg_trgm WITH SCHEMA public;


--
-- Name: EXTENSION pg_trgm; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON EXTENSION pg_trgm IS 'text similarity measurement and index searching based on trigrams';


--
-- Name: ensure_entity(text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.ensure_entity(p_name text, p_type text DEFAULT 'thing'::text) RETURNS bigint
    LANGUAGE plpgsql
    AS $$
DECLARE v_id bigint; v_name text := btrim(p_name);
BEGIN
  SELECT entity_id INTO v_id FROM entity_aliases WHERE alias = lower(v_name);
  IF v_id IS NOT NULL THEN RETURN v_id; END IF;
  INSERT INTO entities (canonical_name, entity_type) VALUES (v_name, p_type)
    ON CONFLICT (canonical_name) DO NOTHING RETURNING entity_id INTO v_id;
  IF v_id IS NULL THEN SELECT entity_id INTO v_id FROM entities WHERE canonical_name = v_name; END IF;
  INSERT INTO entity_aliases (alias, entity_id) VALUES (lower(v_name), v_id) ON CONFLICT DO NOTHING;
  RETURN v_id;
END $$;


--
-- Name: fact_history(text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fact_history(p_subject text, p_predicate text) RETURNS TABLE(fact_id bigint, object text, valid_period tstzrange, sys_period tstzrange, source_id bigint)
    LANGUAGE sql STABLE
    AS $$
  SELECT f.fact_id, COALESCE(o.canonical_name, f.object_text), f.valid_period, f.sys_period, f.source_id
  FROM facts f
  JOIN entities   s ON s.entity_id    = f.subject_id
  JOIN predicates p ON p.predicate_id = f.predicate_id
  LEFT JOIN entities o ON o.entity_id = f.object_entity_id
  WHERE lower(s.canonical_name) = lower(btrim(p_subject)) AND p.name = lower(p_predicate)
  ORDER BY lower(f.sys_period), lower(f.valid_period), f.fact_id
$$;


--
-- Name: memory_now(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.memory_now() RETURNS timestamp with time zone
    LANGUAGE sql STABLE
    AS $$
  SELECT COALESCE(NULLIF(current_setting('memory.txn_time', true), '')::timestamptz, now())
$$;


--
-- Name: facts_as_of(timestamp with time zone, timestamp with time zone); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.facts_as_of(p_valid timestamp with time zone, p_believed timestamp with time zone DEFAULT public.memory_now()) RETURNS TABLE(fact_id bigint, subject text, predicate text, object text, valid_period tstzrange, sys_period tstzrange, confidence real, source_id bigint)
    LANGUAGE sql STABLE
    AS $$
  SELECT f.fact_id, s.canonical_name, p.name, COALESCE(o.canonical_name, f.object_text),
         f.valid_period, f.sys_period, f.confidence, f.source_id
  FROM facts f
  JOIN entities   s ON s.entity_id    = f.subject_id
  JOIN predicates p ON p.predicate_id = f.predicate_id
  LEFT JOIN entities o ON o.entity_id = f.object_entity_id
  WHERE f.valid_period @> p_valid AND f.sys_period @> p_believed
$$;


--
-- Name: facts_before_insert(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.facts_before_insert() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  SELECT is_single_valued INTO NEW.single_valued
  FROM predicates WHERE predicate_id = NEW.predicate_id;
  NEW.sys_period := tstzrange(memory_now(), NULL, '[)');
  RETURN NEW;
END $$;


--
-- Name: facts_before_update(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.facts_before_update() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF (to_jsonb(NEW) - 'sys_period') IS DISTINCT FROM (to_jsonb(OLD) - 'sys_period') THEN
    RAISE EXCEPTION 'facts are immutable: only sys_period may be closed (fact_id=%)', OLD.fact_id
      USING ERRCODE = 'integrity_constraint_violation';
  END IF;
  IF NOT upper_inf(OLD.sys_period) THEN
    RAISE EXCEPTION 'fact % is already closed', OLD.fact_id
      USING ERRCODE = 'integrity_constraint_violation';
  END IF;
  IF lower(NEW.sys_period) IS DISTINCT FROM lower(OLD.sys_period) OR upper_inf(NEW.sys_period) THEN
    RAISE EXCEPTION 'sys_period may only be closed, not moved or reopened (fact_id=%)', OLD.fact_id
      USING ERRCODE = 'integrity_constraint_violation';
  END IF;
  RETURN NEW;
END $$;


--
-- Name: facts_block_delete(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.facts_block_delete() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF COALESCE(current_setting('memory.allow_erasure', true), 'off') <> 'on' THEN
    RAISE EXCEPTION 'facts are append-only; erasure requires memory.allow_erasure = on'
      USING ERRCODE = 'integrity_constraint_violation';
  END IF;
  RETURN OLD;
END $$;


--
-- Name: facts_changed_between(text, text, timestamp with time zone, timestamp with time zone, timestamp with time zone); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.facts_changed_between(p_subject text, p_predicate text, p_from timestamp with time zone, p_to timestamp with time zone, p_believed timestamp with time zone DEFAULT public.memory_now()) RETURNS TABLE(subject text, predicate text, before_objects text[], after_objects text[], changed boolean)
    LANGUAGE sql STABLE
    AS $$
  WITH before_snapshot AS (
    SELECT s.canonical_name AS subject, p.name AS predicate,
           array_agg(DISTINCT COALESCE(o.canonical_name, f.object_text)
                     ORDER BY COALESCE(o.canonical_name, f.object_text)) AS objects
    FROM facts f
    JOIN entities s ON s.entity_id = f.subject_id
    JOIN predicates p ON p.predicate_id = f.predicate_id
    LEFT JOIN entities o ON o.entity_id = f.object_entity_id
    WHERE f.valid_period @> p_from AND f.sys_period @> p_believed
    GROUP BY s.canonical_name, p.name
  ),
  after_snapshot AS (
    SELECT s.canonical_name AS subject, p.name AS predicate,
           array_agg(DISTINCT COALESCE(o.canonical_name, f.object_text)
                     ORDER BY COALESCE(o.canonical_name, f.object_text)) AS objects
    FROM facts f
    JOIN entities s ON s.entity_id = f.subject_id
    JOIN predicates p ON p.predicate_id = f.predicate_id
    LEFT JOIN entities o ON o.entity_id = f.object_entity_id
    WHERE f.valid_period @> p_to AND f.sys_period @> p_believed
    GROUP BY s.canonical_name, p.name
  )
  SELECT COALESCE(b.subject, a.subject), COALESCE(b.predicate, a.predicate),
         COALESCE(b.objects, '{}'), COALESCE(a.objects, '{}'),
         COALESCE(b.objects, '{}') IS DISTINCT FROM COALESCE(a.objects, '{}')
  FROM before_snapshot b
  FULL OUTER JOIN after_snapshot a USING (subject, predicate)
  WHERE lower(subject) = lower(btrim(p_subject))
    AND predicate = lower(btrim(p_predicate))
$$;


--
-- Name: forget_subject(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.forget_subject(p_subject text) RETURNS TABLE(facts_deleted integer, sources_deleted integer)
    LANGUAGE plpgsql
    AS $$
DECLARE
  v_subject_id bigint;
  v_facts integer;
  v_sources integer;
  v_source_ids bigint[];
BEGIN
  SELECT entity_id INTO v_subject_id
  FROM entities
  WHERE lower(canonical_name) = lower(btrim(p_subject));

  IF v_subject_id IS NULL THEN
    RETURN QUERY SELECT 0, 0;
    RETURN;
  END IF;

  SELECT count(*)::integer, count(DISTINCT source_id)::integer
    INTO v_facts, v_sources
  FROM facts
  WHERE subject_id = v_subject_id;
  SELECT array_agg(DISTINCT source_id) INTO v_source_ids
  FROM facts
  WHERE subject_id = v_subject_id;

  SET LOCAL memory.allow_erasure = 'on';
  DELETE FROM facts WHERE subject_id = v_subject_id;
  DELETE FROM sources src
  WHERE NOT EXISTS (SELECT 1 FROM facts f WHERE f.source_id = src.source_id)
    AND src.source_id = ANY(v_source_ids);

  DELETE FROM entity_aliases WHERE entity_id = v_subject_id;
  DELETE FROM entities e
  WHERE e.entity_id = v_subject_id
    AND NOT EXISTS (SELECT 1 FROM facts f
                    WHERE f.subject_id = e.entity_id OR f.object_entity_id = e.entity_id);

  INSERT INTO erasure_audit (facts_deleted, sources_deleted)
  VALUES (v_facts, v_sources);
  RETURN QUERY SELECT v_facts, v_sources;
END $$;


--
-- Name: log_source(text, integer, text, text, timestamp with time zone); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.log_source(p_conversation text, p_turn integer, p_speaker text, p_content text, p_occurred_at timestamp with time zone) RETURNS bigint
    LANGUAGE sql
    AS $$
  INSERT INTO sources (conversation_id, turn_no, speaker, content, occurred_at)
  VALUES (p_conversation, p_turn, p_speaker, p_content, p_occurred_at)
  ON CONFLICT (conversation_id, turn_no) DO UPDATE SET content = EXCLUDED.content
  RETURNING source_id
$$;


--
-- Name: predicates_freeze_flag(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.predicates_freeze_flag() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF NEW.is_single_valued IS DISTINCT FROM OLD.is_single_valued
     AND EXISTS (SELECT 1 FROM facts WHERE predicate_id = OLD.predicate_id) THEN
    RAISE EXCEPTION 'cannot change is_single_valued of "%": facts already exist', OLD.name;
  END IF;
  RETURN NEW;
END $$;


--
-- Name: reject_fact(bigint, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.reject_fact(p_fact_id bigint, p_actor text, p_reason text) RETURNS bigint
    LANGUAGE plpgsql
    AS $$
DECLARE v_now timestamptz := memory_now(); v_old text;
BEGIN
  SELECT COALESCE(o.canonical_name, f.object_text)
  INTO v_old
  FROM facts f LEFT JOIN entities o ON o.entity_id = f.object_entity_id
  WHERE f.fact_id = p_fact_id AND upper_inf(f.sys_period);
  IF NOT FOUND THEN RAISE EXCEPTION 'fact % is not currently active', p_fact_id; END IF;

  UPDATE facts SET sys_period = tstzrange(lower(sys_period), v_now, '[)')
  WHERE fact_id = p_fact_id;
  INSERT INTO fact_corrections(fact_id, action, old_object, actor, reason)
  VALUES (p_fact_id, 'reject', v_old, btrim(p_actor), btrim(p_reason));
  RETURN p_fact_id;
END $$;


--
-- Name: remember(text, text, text, bigint, timestamp with time zone, real, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.remember(p_subject text, p_predicate text, p_object text, p_source bigint, p_valid_from timestamp with time zone DEFAULT public.memory_now(), p_confidence real DEFAULT 1.0, p_subject_type text DEFAULT 'person'::text, p_object_type text DEFAULT 'thing'::text) RETURNS bigint
    LANGUAGE plpgsql
    AS $$
DECLARE
  v_pred predicates%ROWTYPE; v_subj bigint; v_oe bigint; v_ot text; v_id bigint;
BEGIN
  SELECT * INTO v_pred FROM predicates WHERE name = lower(p_predicate);
  IF NOT FOUND THEN RAISE EXCEPTION 'unknown predicate: %', p_predicate; END IF;
  v_subj := ensure_entity(p_subject, p_subject_type);
  IF v_pred.value_type = 'entity' THEN v_oe := ensure_entity(p_object, p_object_type);
  ELSE v_ot := btrim(p_object); END IF;

  IF v_pred.is_single_valued THEN
    RETURN supersede_fact(v_subj, v_pred.predicate_id, v_oe, v_ot, p_source, p_valid_from, p_confidence);
  END IF;

  SELECT fact_id INTO v_id FROM facts       -- multi-valued: skip exact duplicates
  WHERE subject_id = v_subj AND predicate_id = v_pred.predicate_id AND upper_inf(sys_period)
    AND object_entity_id IS NOT DISTINCT FROM v_oe AND object_text IS NOT DISTINCT FROM v_ot
    AND valid_period @> p_valid_from;
  IF FOUND THEN RETURN v_id; END IF;

  INSERT INTO facts (subject_id, predicate_id, object_entity_id, object_text, valid_period, confidence, source_id)
  VALUES (v_subj, v_pred.predicate_id, v_oe, v_ot, tstzrange(p_valid_from, NULL, '[)'), p_confidence, p_source)
  RETURNING fact_id INTO v_id;
  RETURN v_id;
END $$;


--
-- Name: replace_fact(bigint, text, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.replace_fact(p_fact_id bigint, p_new_object text, p_actor text, p_reason text) RETURNS bigint
    LANGUAGE plpgsql
    AS $$
DECLARE r facts%ROWTYPE; v_new_entity bigint; v_new_text text;
  v_pred predicates%ROWTYPE; v_now timestamptz := memory_now(); v_id bigint;
  v_old text;
BEGIN
  SELECT * INTO r FROM facts
  WHERE fact_id = p_fact_id AND upper_inf(sys_period);
  IF NOT FOUND THEN RAISE EXCEPTION 'fact % is not currently active', p_fact_id; END IF;
  SELECT * INTO v_pred FROM predicates WHERE predicate_id = r.predicate_id;
  SELECT COALESCE(o.canonical_name, r.object_text)
  INTO v_old
  FROM facts f
  LEFT JOIN entities o ON o.entity_id = f.object_entity_id
  WHERE f.fact_id = p_fact_id;

  IF v_pred.value_type = 'entity' THEN
    v_new_entity := ensure_entity(btrim(p_new_object), 'thing');
  ELSE
    v_new_text := btrim(p_new_object);
  END IF;
  IF v_pred.value_type = 'entity' AND v_new_entity IS NULL
     OR v_pred.value_type <> 'entity' AND v_new_text IS NULL THEN
    RAISE EXCEPTION 'replacement object must not be empty';
  END IF;

  UPDATE facts SET sys_period = tstzrange(lower(sys_period), v_now, '[)')
  WHERE fact_id = p_fact_id;

  INSERT INTO facts(subject_id, predicate_id, object_entity_id, object_text,
                    valid_period, confidence, source_id)
  VALUES (r.subject_id, r.predicate_id, v_new_entity, v_new_text,
          r.valid_period, r.confidence, r.source_id)
  RETURNING fact_id INTO v_id;

  INSERT INTO fact_corrections(fact_id, action, old_object, new_object, actor, reason)
  VALUES (p_fact_id, 'replace', v_old, btrim(p_new_object), btrim(p_actor), btrim(p_reason));
  RETURN v_id;
END $$;


--
-- Name: restore_fact(bigint, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.restore_fact(p_fact_id bigint, p_actor text, p_reason text) RETURNS bigint
    LANGUAGE plpgsql
    AS $$
DECLARE r facts%ROWTYPE; v_id bigint; v_old text;
  v_pred predicates%ROWTYPE; v_now timestamptz := memory_now();
BEGIN
  SELECT * INTO r FROM facts WHERE fact_id = p_fact_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'unknown fact: %', p_fact_id; END IF;
  IF upper_inf(r.sys_period) THEN
    RAISE EXCEPTION 'fact % is already active; restore is only for closed historical facts', p_fact_id;
  END IF;
  SELECT * INTO v_pred FROM predicates WHERE predicate_id = r.predicate_id;
  SELECT COALESCE(o.canonical_name, r.object_text)
  INTO v_old
  FROM facts f
  LEFT JOIN entities o ON o.entity_id = f.object_entity_id
  WHERE f.fact_id = p_fact_id;

  IF v_pred.is_single_valued THEN
    UPDATE facts
    SET sys_period = tstzrange(lower(sys_period), v_now, '[)')
    WHERE subject_id = r.subject_id
      AND predicate_id = r.predicate_id
      AND single_valued
      AND upper_inf(sys_period)
      AND valid_period && r.valid_period;
  END IF;

  INSERT INTO facts(subject_id, predicate_id, object_entity_id, object_text,
                    valid_period, confidence, source_id)
  SELECT r.subject_id, r.predicate_id, r.object_entity_id, r.object_text,
         r.valid_period, r.confidence, r.source_id
  RETURNING fact_id INTO v_id;

  INSERT INTO fact_corrections(fact_id, action, old_object, new_object, actor, reason)
  VALUES (p_fact_id, 'restore', v_old, v_old, btrim(p_actor), btrim(p_reason));
  RETURN v_id;
END $$;


--
-- Name: supersede_fact(bigint, integer, bigint, text, bigint, timestamp with time zone, real); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.supersede_fact(p_subject bigint, p_predicate integer, p_obj_entity bigint, p_obj_text text, p_source bigint, p_valid_from timestamp with time zone, p_confidence real DEFAULT 1.0) RETURNS bigint
    LANGUAGE plpgsql
    AS $$
DECLARE
  r       facts%ROWTYPE;
  v_now   timestamptz := memory_now();
  v_new   tstzrange   := tstzrange(p_valid_from, NULL, '[)');
  v_id    bigint;
BEGIN
  -- Already believed and already covers p_valid_from -> nothing to do (idempotent)
  SELECT fact_id INTO v_id FROM facts
  WHERE subject_id = p_subject AND predicate_id = p_predicate AND upper_inf(sys_period)
    AND object_entity_id IS NOT DISTINCT FROM p_obj_entity
    AND object_text      IS NOT DISTINCT FROM p_obj_text
    AND upper_inf(valid_period) AND lower(valid_period) <= p_valid_from;
  IF FOUND THEN RETURN v_id; END IF;

  FOR r IN
    SELECT * FROM facts
    WHERE subject_id = p_subject AND predicate_id = p_predicate AND single_valued
      AND upper_inf(sys_period) AND valid_period && v_new
    ORDER BY valid_period FOR UPDATE
  LOOP
    UPDATE facts SET sys_period = tstzrange(lower(sys_period), v_now, '[)') WHERE fact_id = r.fact_id;
    IF lower(r.valid_period) < p_valid_from THEN       -- the earlier part of the old fact survives
      INSERT INTO facts (subject_id, predicate_id, object_entity_id, object_text, valid_period, confidence, source_id)
      VALUES (r.subject_id, r.predicate_id, r.object_entity_id, r.object_text,
              tstzrange(lower(r.valid_period), p_valid_from, '[)'), r.confidence, r.source_id);
    END IF;
  END LOOP;

  INSERT INTO facts (subject_id, predicate_id, object_entity_id, object_text, valid_period, confidence, source_id)
  VALUES (p_subject, p_predicate, p_obj_entity, p_obj_text, v_new, p_confidence, p_source)
  RETURNING fact_id INTO v_id;
  RETURN v_id;
END $$;


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: entities; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.entities (
    entity_id bigint NOT NULL,
    canonical_name text NOT NULL,
    entity_type text DEFAULT 'thing'::text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT entities_entity_type_check CHECK ((entity_type = ANY (ARRAY['person'::text, 'org'::text, 'place'::text, 'thing'::text])))
);


--
-- Name: facts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.facts (
    fact_id bigint NOT NULL,
    subject_id bigint NOT NULL,
    predicate_id integer NOT NULL,
    object_entity_id bigint,
    object_text text,
    valid_period tstzrange NOT NULL,
    sys_period tstzrange DEFAULT tstzrange(now(), NULL::timestamp with time zone) NOT NULL,
    confidence real DEFAULT 1.0 NOT NULL,
    source_id bigint NOT NULL,
    single_valued boolean DEFAULT false NOT NULL,
    CONSTRAINT exactly_one_object CHECK ((num_nonnulls(object_entity_id, object_text) = 1)),
    CONSTRAINT facts_confidence_check CHECK (((confidence >= (0)::double precision) AND (confidence <= (1)::double precision))),
    CONSTRAINT valid_period_wellformed CHECK (((NOT isempty(valid_period)) AND (NOT lower_inf(valid_period)) AND lower_inc(valid_period) AND (NOT upper_inc(valid_period))))
);


--
-- Name: predicates; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.predicates (
    predicate_id integer NOT NULL,
    name text NOT NULL,
    is_single_valued boolean NOT NULL,
    value_type text NOT NULL,
    description text,
    CONSTRAINT predicates_name_check CHECK ((name = lower(name))),
    CONSTRAINT predicates_value_type_check CHECK ((value_type = ANY (ARRAY['entity'::text, 'text'::text])))
);


--
-- Name: current_facts; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.current_facts AS
 SELECT f.fact_id,
    s.canonical_name AS subject,
    p.name AS predicate,
    COALESCE(o.canonical_name, f.object_text) AS object,
    f.valid_period,
    f.confidence,
    f.source_id
   FROM (((public.facts f
     JOIN public.entities s ON ((s.entity_id = f.subject_id)))
     JOIN public.predicates p ON ((p.predicate_id = f.predicate_id)))
     LEFT JOIN public.entities o ON ((o.entity_id = f.object_entity_id)))
  WHERE ((f.valid_period @> public.memory_now()) AND (f.sys_period @> public.memory_now()));


--
-- Name: entities_entity_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.entities_entity_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: entities_entity_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.entities_entity_id_seq OWNED BY public.entities.entity_id;


--
-- Name: entity_aliases; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.entity_aliases (
    alias text NOT NULL,
    entity_id bigint NOT NULL,
    CONSTRAINT entity_aliases_alias_check CHECK ((alias = lower(btrim(alias))))
);


--
-- Name: erasure_audit; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.erasure_audit (
    audit_id bigint NOT NULL,
    erased_at timestamp with time zone DEFAULT now() NOT NULL,
    facts_deleted integer NOT NULL,
    sources_deleted integer NOT NULL,
    CONSTRAINT erasure_audit_facts_deleted_check CHECK ((facts_deleted >= 0)),
    CONSTRAINT erasure_audit_sources_deleted_check CHECK ((sources_deleted >= 0))
);


--
-- Name: erasure_audit_audit_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.erasure_audit_audit_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: erasure_audit_audit_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.erasure_audit_audit_id_seq OWNED BY public.erasure_audit.audit_id;


--
-- Name: fact_corrections; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.fact_corrections (
    correction_id bigint NOT NULL,
    fact_id bigint NOT NULL,
    action text NOT NULL,
    old_object text,
    new_object text,
    actor text NOT NULL,
    reason text NOT NULL,
    corrected_at timestamp with time zone DEFAULT public.memory_now() NOT NULL,
    CONSTRAINT fact_corrections_action_check CHECK ((action = ANY (ARRAY['replace'::text, 'reject'::text, 'restore'::text]))),
    CONSTRAINT fact_corrections_reason_check CHECK ((btrim(reason) <> ''::text))
);


--
-- Name: fact_corrections_correction_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.fact_corrections_correction_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: fact_corrections_correction_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.fact_corrections_correction_id_seq OWNED BY public.fact_corrections.correction_id;


--
-- Name: facts_fact_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.facts_fact_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: facts_fact_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.facts_fact_id_seq OWNED BY public.facts.fact_id;


--
-- Name: predicates_predicate_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.predicates_predicate_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: predicates_predicate_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.predicates_predicate_id_seq OWNED BY public.predicates.predicate_id;


--
-- Name: sources; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.sources (
    source_id bigint NOT NULL,
    conversation_id text NOT NULL,
    turn_no integer NOT NULL,
    speaker text DEFAULT 'user'::text NOT NULL,
    content text NOT NULL,
    occurred_at timestamp with time zone NOT NULL
);


--
-- Name: sources_source_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.sources_source_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: sources_source_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.sources_source_id_seq OWNED BY public.sources.source_id;


--
-- Name: entities entity_id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.entities ALTER COLUMN entity_id SET DEFAULT nextval('public.entities_entity_id_seq'::regclass);


--
-- Name: erasure_audit audit_id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.erasure_audit ALTER COLUMN audit_id SET DEFAULT nextval('public.erasure_audit_audit_id_seq'::regclass);


--
-- Name: fact_corrections correction_id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.fact_corrections ALTER COLUMN correction_id SET DEFAULT nextval('public.fact_corrections_correction_id_seq'::regclass);


--
-- Name: facts fact_id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.facts ALTER COLUMN fact_id SET DEFAULT nextval('public.facts_fact_id_seq'::regclass);


--
-- Name: predicates predicate_id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.predicates ALTER COLUMN predicate_id SET DEFAULT nextval('public.predicates_predicate_id_seq'::regclass);


--
-- Name: sources source_id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sources ALTER COLUMN source_id SET DEFAULT nextval('public.sources_source_id_seq'::regclass);


--
-- Data for Name: entities; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.entities (entity_id, canonical_name, entity_type, created_at) FROM stdin;
1	Priya	person	2026-11-22 12:11:51.950308+05:30
2	Infosys	org	2026-11-22 12:11:51.950308+05:30
3	Bengaluru	place	2026-11-22 12:11:51.950308+05:30
4	Kannada	thing	2026-11-22 12:11:51.950308+05:30
5	English	thing	2026-11-22 12:11:51.950308+05:30
6	Zeta Labs	org	2026-11-22 12:11:51.950308+05:30
7	Pune	place	2026-11-22 12:11:51.950308+05:30
8	Rohan	person	2026-11-22 12:11:51.950308+05:30
9	Mysuru	place	2026-11-22 12:11:51.950308+05:30
10	TCS	org	2026-11-22 12:11:51.950308+05:30
11	Ilina	person	2026-11-22 12:11:51.979558+05:30
12	Kochi	place	2026-11-22 12:11:51.979558+05:30
13	Malayalam	thing	2026-11-22 12:11:51.979558+05:30
14	French	thing	2026-11-22 12:11:51.979558+05:30
15	Coral Reef Institute	org	2026-11-22 12:11:51.979558+05:30
16	Port Blair	place	2026-11-22 12:11:51.979558+05:30
17	Rehaan	person	2026-11-22 12:11:51.979558+05:30
18	Jaipur	place	2026-11-22 12:11:51.979558+05:30
19	Hindi	thing	2026-11-22 12:11:51.979558+05:30
20	Marwari	thing	2026-11-22 12:11:51.979558+05:30
21	Marigold Kitchen	org	2026-11-22 12:11:51.979558+05:30
22	Mahika	person	2026-11-22 12:11:51.979558+05:30
23	Lucknow	place	2026-11-22 12:11:51.979558+05:30
24	Lakeview Hospital	org	2026-11-22 12:11:51.979558+05:30
25	Riverside Clinic	org	2026-11-22 12:11:51.979558+05:30
26	Bhopal	place	2026-11-22 12:11:51.979558+05:30
27	Darsh	person	2026-11-22 12:11:51.979558+05:30
28	Shillong	place	2026-11-22 12:11:51.979558+05:30
29	Hillside Conservatory	org	2026-11-22 12:11:51.979558+05:30
\.


--
-- Data for Name: entity_aliases; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.entity_aliases (alias, entity_id) FROM stdin;
priya	1
infosys	2
bengaluru	3
kannada	4
english	5
zeta labs	6
pune	7
rohan	8
mysuru	9
tcs	10
ilina	11
kochi	12
malayalam	13
french	14
coral reef institute	15
port blair	16
rehaan	17
jaipur	18
hindi	19
marwari	20
marigold kitchen	21
mahika	22
lucknow	23
lakeview hospital	24
riverside clinic	25
bhopal	26
darsh	27
shillong	28
hillside conservatory	29
cochin	12
cri	15
marigold	21
\.


--
-- Data for Name: erasure_audit; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.erasure_audit (audit_id, erased_at, facts_deleted, sources_deleted) FROM stdin;
\.


--
-- Data for Name: fact_corrections; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.fact_corrections (correction_id, fact_id, action, old_object, new_object, actor, reason, corrected_at) FROM stdin;
1	33	replace	sci-fi	science fiction	curator-01	Spell out the abbreviation extracted from turn 2	2026-10-09 10:00:00+05:30
2	30	reject	French	\N	curator-01	User said their French is only basic, asked to remove it	2026-10-13 16:40:00+05:30
3	30	restore	French	French	curator-02	User confirmed conversational French still counts	2026-10-21 09:05:00+05:30
\.


--
-- Data for Name: facts; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.facts (fact_id, subject_id, predicate_id, object_entity_id, object_text, valid_period, sys_period, confidence, source_id, single_valued) FROM stdin;
4	1	5	\N	filter coffee	["2026-03-10 10:05:00+05:30",)	["2026-03-10 10:05:00+05:30",)	1	2	f
5	1	5	\N	badminton	["2026-03-10 10:05:00+05:30",)	["2026-03-10 10:05:00+05:30",)	1	2	f
6	1	6	4	\N	["2026-03-10 10:05:00+05:30",)	["2026-03-10 10:05:00+05:30",)	1	2	f
7	1	6	5	\N	["2026-03-10 10:05:00+05:30",)	["2026-03-10 10:05:00+05:30",)	1	2	f
8	1	7	\N	Python	["2026-04-02 18:00:00+05:30",)	["2026-04-02 18:00:00+05:30",)	1	3	f
9	1	7	\N	SQL	["2026-04-02 18:00:00+05:30",)	["2026-04-02 18:00:00+05:30",)	1	3	f
2	1	3	\N	Software Engineer	["2025-06-01 00:00:00+05:30",)	["2026-03-10 10:00:00+05:30","2026-05-18 09:30:00+05:30")	0.95	1	t
10	1	3	\N	Software Engineer	["2025-06-01 00:00:00+05:30","2026-05-11 00:00:00+05:30")	["2026-05-18 09:30:00+05:30",)	0.95	1	t
1	1	1	2	\N	["2025-06-01 00:00:00+05:30",)	["2026-03-10 10:00:00+05:30","2026-08-20 10:00:00+05:30")	0.95	1	t
11	1	3	\N	Senior Engineer	["2026-05-11 00:00:00+05:30",)	["2026-05-18 09:30:00+05:30","2026-08-20 10:00:00+05:30")	1	4	t
14	1	3	\N	Senior Engineer	["2026-05-11 00:00:00+05:30","2026-08-15 00:00:00+05:30")	["2026-08-20 10:00:00+05:30",)	1	4	t
15	1	3	\N	Founding Engineer	["2026-08-15 00:00:00+05:30",)	["2026-08-20 10:00:00+05:30",)	0.9	5	t
3	1	2	3	\N	["2023-01-01 00:00:00+05:30",)	["2026-03-10 10:00:00+05:30","2026-08-20 10:30:00+05:30")	0.9	1	t
16	1	2	3	\N	["2023-01-01 00:00:00+05:30","2026-08-18 00:00:00+05:30")	["2026-08-20 10:30:00+05:30",)	0.9	1	t
17	1	2	7	\N	["2026-08-18 00:00:00+05:30",)	["2026-08-20 10:30:00+05:30",)	0.9	6	t
12	1	1	2	\N	["2025-06-01 00:00:00+05:30","2026-08-15 00:00:00+05:30")	["2026-08-20 10:00:00+05:30","2026-09-05 12:00:00+05:30")	0.95	1	t
18	1	1	2	\N	["2025-06-01 00:00:00+05:30","2026-08-01 00:00:00+05:30")	["2026-09-05 12:00:00+05:30",)	0.95	1	t
13	1	1	6	\N	["2026-08-15 00:00:00+05:30",)	["2026-08-20 10:00:00+05:30","2026-09-05 12:00:00+05:30")	0.9	5	t
19	1	1	6	\N	["2026-08-01 00:00:00+05:30",)	["2026-09-05 12:00:00+05:30",)	0.95	7	t
20	8	2	9	\N	["2020-01-01 00:00:00+05:30",)	["2026-02-14 20:00:00+05:30",)	0.9	8	t
21	8	1	10	\N	["2024-07-01 00:00:00+05:30",)	["2026-02-14 20:00:00+05:30",)	0.95	8	t
23	8	5	\N	cricket	["2026-02-14 20:00:00+05:30",)	["2026-02-14 20:00:00+05:30",)	1	8	f
22	8	4	\N	Dosa	["2026-02-14 20:00:00+05:30",)	["2026-02-14 20:00:00+05:30","2026-07-02 19:00:00+05:30")	1	8	t
24	8	4	\N	Dosa	["2026-02-14 20:00:00+05:30","2026-07-02 19:00:00+05:30")	["2026-07-02 19:00:00+05:30",)	1	8	t
25	8	4	\N	Biryani	["2026-07-02 19:00:00+05:30",)	["2026-07-02 19:00:00+05:30",)	1	9	t
28	11	6	13	\N	["2026-01-14 19:10:00+05:30",)	["2026-01-14 19:10:00+05:30",)	0.95	10	f
29	11	6	5	\N	["2026-01-14 19:10:00+05:30",)	["2026-01-14 19:10:00+05:30",)	0.95	10	f
31	11	5	\N	scuba diving	["2026-02-05 21:30:00+05:30",)	["2026-02-05 21:30:00+05:30",)	1	11	f
32	11	5	\N	birdwatching	["2026-02-05 21:30:00+05:30",)	["2026-02-05 21:30:00+05:30",)	1	11	f
35	11	7	\N	Coral taxonomy	["2026-02-22 18:05:00+05:30",)	["2026-02-22 18:05:00+05:30",)	1	12	f
36	11	7	\N	GIS mapping	["2026-02-22 18:05:00+05:30",)	["2026-02-22 18:05:00+05:30",)	1	12	f
37	11	7	\N	R	["2026-02-22 18:05:00+05:30",)	["2026-02-22 18:05:00+05:30",)	0.8	12	f
27	11	3	\N	Research Assistant	["2023-09-01 00:00:00+05:30",)	["2026-01-14 19:10:00+05:30","2026-04-16 18:45:00+05:30")	0.95	10	t
26	11	2	12	\N	["2022-06-01 00:00:00+05:30",)	["2026-01-14 19:10:00+05:30","2026-06-04 09:20:00+05:30")	0.95	10	t
41	11	2	12	\N	["2022-06-01 00:00:00+05:30","2026-05-30 00:00:00+05:30")	["2026-06-04 09:20:00+05:30",)	0.95	10	t
38	11	1	15	\N	["2026-06-01 00:00:00+05:30",)	["2026-04-16 18:45:00+05:30","2026-06-21 20:00:00+05:30")	0.9	13	t
43	11	1	15	\N	["2026-05-25 00:00:00+05:30",)	["2026-06-21 20:00:00+05:30",)	0.95	15	t
39	11	3	\N	Research Assistant	["2023-09-01 00:00:00+05:30","2026-06-01 00:00:00+05:30")	["2026-04-16 18:45:00+05:30","2026-06-21 20:00:00+05:30")	0.95	10	t
44	11	3	\N	Research Assistant	["2023-09-01 00:00:00+05:30","2026-05-25 00:00:00+05:30")	["2026-06-21 20:00:00+05:30",)	0.95	10	t
40	11	3	\N	Field Fellow	["2026-06-01 00:00:00+05:30",)	["2026-04-16 18:45:00+05:30","2026-06-21 20:00:00+05:30")	0.9	13	t
46	11	7	\N	Scientific diving	["2026-07-29 22:10:00+05:30",)	["2026-07-29 22:10:00+05:30",)	1	16	f
47	11	7	\N	Drone surveying	["2026-07-29 22:10:00+05:30",)	["2026-07-29 22:10:00+05:30",)	0.85	16	f
48	11	5	\N	kayaking	["2026-07-29 22:10:00+05:30",)	["2026-07-29 22:10:00+05:30",)	1	16	f
45	11	3	\N	Field Fellow	["2026-05-25 00:00:00+05:30",)	["2026-06-21 20:00:00+05:30","2026-08-04 11:00:00+05:30")	0.95	15	t
49	11	3	\N	Field Fellow	["2026-05-25 00:00:00+05:30","2026-08-01 00:00:00+05:30")	["2026-08-04 11:00:00+05:30",)	0.95	15	t
50	11	3	\N	Remote Data Curator	["2026-08-01 00:00:00+05:30",)	["2026-08-04 11:00:00+05:30",)	0.9	17	t
42	11	2	16	\N	["2026-05-30 00:00:00+05:30",)	["2026-06-04 09:20:00+05:30","2026-08-04 11:00:00+05:30")	0.9	14	t
51	11	2	16	\N	["2026-05-30 00:00:00+05:30","2026-08-01 00:00:00+05:30")	["2026-08-04 11:00:00+05:30",)	0.9	14	t
52	11	2	12	\N	["2026-08-01 00:00:00+05:30",)	["2026-08-04 11:00:00+05:30",)	0.95	17	t
34	11	4	\N	Appam with Stew	["2026-02-05 21:30:00+05:30",)	["2026-02-05 21:30:00+05:30","2026-09-11 13:30:00+05:30")	0.9	11	t
53	11	4	\N	Appam with Stew	["2026-02-05 21:30:00+05:30","2026-09-11 13:30:00+05:30")	["2026-09-11 13:30:00+05:30",)	0.9	11	t
54	11	4	\N	Fish Moilee	["2026-09-11 13:30:00+05:30",)	["2026-09-11 13:30:00+05:30",)	0.9	18	t
55	11	7	\N	Bioacoustics	["2026-10-06 17:15:00+05:30",)	["2026-10-06 17:15:00+05:30",)	1	19	f
33	11	5	\N	sci-fi	["2026-02-05 21:30:00+05:30",)	["2026-02-05 21:30:00+05:30","2026-10-09 10:00:00+05:30")	0.85	11	f
56	11	5	\N	science fiction	["2026-02-05 21:30:00+05:30",)	["2026-10-09 10:00:00+05:30",)	0.85	11	f
30	11	6	14	\N	["2026-01-14 19:10:00+05:30",)	["2026-01-14 19:10:00+05:30","2026-10-13 16:40:00+05:30")	0.8	10	f
57	11	6	14	\N	["2026-01-14 19:10:00+05:30",)	["2026-10-21 09:05:00+05:30",)	0.8	10	f
58	17	2	18	\N	["1998-03-14 00:00:00+05:30",)	["2026-01-27 18:00:00+05:30",)	0.9	20	t
59	17	6	19	\N	["2026-01-27 18:00:00+05:30",)	["2026-01-27 18:00:00+05:30",)	1	20	f
60	17	6	20	\N	["2026-01-27 18:00:00+05:30",)	["2026-01-27 18:00:00+05:30",)	1	20	f
61	17	4	\N	Dal Baati	["2026-01-27 18:00:00+05:30",)	["2026-01-27 18:00:00+05:30",)	1	20	t
62	17	1	21	\N	["2024-03-01 00:00:00+05:30",)	["2026-03-03 20:30:00+05:30",)	0.95	21	t
64	17	7	\N	Pastry	["2026-03-03 20:30:00+05:30",)	["2026-03-03 20:30:00+05:30",)	1	21	f
65	17	7	\N	Fermentation	["2026-03-03 20:30:00+05:30",)	["2026-03-03 20:30:00+05:30",)	1	21	f
66	17	5	\N	vintage motorcycles	["2026-03-03 20:30:00+05:30",)	["2026-03-03 20:30:00+05:30",)	1	21	f
63	17	3	\N	Sous Chef	["2024-03-01 00:00:00+05:30",)	["2026-03-03 20:30:00+05:30","2026-07-15 09:00:00+05:30")	0.95	21	t
67	17	3	\N	Sous Chef	["2024-03-01 00:00:00+05:30","2026-07-01 00:00:00+05:30")	["2026-07-15 09:00:00+05:30",)	0.95	21	t
68	17	3	\N	Head Chef	["2026-07-01 00:00:00+05:30",)	["2026-07-15 09:00:00+05:30",)	0.95	22	t
72	22	4	\N	Poha	["2026-02-11 21:00:00+05:30",)	["2026-02-11 21:00:00+05:30",)	1	23	t
73	22	7	\N	Critical care	["2026-04-05 19:45:00+05:30",)	["2026-04-05 19:45:00+05:30",)	1	24	f
74	22	5	\N	pottery	["2026-04-05 19:45:00+05:30",)	["2026-04-05 19:45:00+05:30",)	1	24	f
70	22	1	24	\N	["2023-08-01 00:00:00+05:30",)	["2026-02-11 21:00:00+05:30","2026-08-26 14:00:00+05:30")	0.95	23	t
75	22	1	24	\N	["2023-08-01 00:00:00+05:30","2026-08-18 00:00:00+05:30")	["2026-08-26 14:00:00+05:30",)	0.95	23	t
76	22	1	25	\N	["2026-08-18 00:00:00+05:30",)	["2026-08-26 14:00:00+05:30",)	0.9	25	t
71	22	3	\N	Staff Nurse	["2023-08-01 00:00:00+05:30",)	["2026-02-11 21:00:00+05:30","2026-08-26 14:00:00+05:30")	0.95	23	t
77	22	3	\N	Staff Nurse	["2023-08-01 00:00:00+05:30","2026-08-18 00:00:00+05:30")	["2026-08-26 14:00:00+05:30",)	0.95	23	t
78	22	3	\N	ICU Nurse	["2026-08-18 00:00:00+05:30",)	["2026-08-26 14:00:00+05:30",)	0.9	25	t
69	22	2	23	\N	["2000-01-01 00:00:00+05:30",)	["2026-02-11 21:00:00+05:30","2026-08-26 14:00:00+05:30")	0.9	23	t
79	22	2	23	\N	["2000-01-01 00:00:00+05:30","2026-08-16 00:00:00+05:30")	["2026-08-26 14:00:00+05:30",)	0.9	23	t
80	22	2	26	\N	["2026-08-16 00:00:00+05:30",)	["2026-08-26 14:00:00+05:30",)	0.85	25	t
81	27	2	28	\N	["2019-06-01 00:00:00+05:30",)	["2026-03-19 16:20:00+05:30",)	0.9	26	t
82	27	1	29	\N	["2025-01-06 00:00:00+05:30",)	["2026-03-19 16:20:00+05:30",)	0.95	26	t
84	27	4	\N	Momos	["2026-03-19 16:20:00+05:30",)	["2026-03-19 16:20:00+05:30",)	1	26	t
85	27	5	\N	trekking	["2026-03-19 16:20:00+05:30",)	["2026-03-19 16:20:00+05:30",)	1	26	f
86	27	7	\N	Violin	["2026-03-19 16:20:00+05:30",)	["2026-03-19 16:20:00+05:30",)	1	26	f
83	27	3	\N	Violin Teacher	["2025-01-06 00:00:00+05:30",)	["2026-03-19 16:20:00+05:30","2026-09-02 10:15:00+05:30")	0.95	26	t
87	27	3	\N	Violin Teacher	["2025-01-06 00:00:00+05:30","2026-09-02 00:00:00+05:30")	["2026-09-02 10:15:00+05:30",)	0.95	26	t
88	27	3	\N	Head of Strings	["2026-09-02 00:00:00+05:30",)	["2026-09-02 10:15:00+05:30",)	0.95	27	t
89	27	7	\N	Music theory	["2026-09-02 10:15:00+05:30",)	["2026-09-02 10:15:00+05:30",)	1	27	f
\.


--
-- Data for Name: predicates; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.predicates (predicate_id, name, is_single_valued, value_type, description) FROM stdin;
1	works_at	t	entity	current employer
2	lives_in	t	entity	city of residence
3	has_role	t	text	job title
4	favourite_food	t	text	favourite food
5	likes	f	text	things the person likes
6	speaks	f	entity	languages spoken
7	skilled_in	f	text	skills
\.


--
-- Data for Name: sources; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.sources (source_id, conversation_id, turn_no, speaker, content, occurred_at) FROM stdin;
1	c1	1	user	I work at Infosys, joined in June last year, as a software engineer. Been in Bengaluru since 2023.	2026-03-10 10:00:00+05:30
2	c1	2	user	I love filter coffee and badminton. I speak Kannada and English.	2026-03-10 10:05:00+05:30
3	c1	3	user	I mostly code in Python and SQL.	2026-04-02 18:00:00+05:30
4	c1	4	user	Got promoted to Senior Engineer last week!	2026-05-18 09:30:00+05:30
5	c1	5	user	I just joined a startup, Zeta Labs, last week, as a founding engineer.	2026-08-20 10:00:00+05:30
6	c1	6	user	Moved to Pune on Tuesday for the new job.	2026-08-20 10:30:00+05:30
7	c1	7	user	Sorry, I actually started at Zeta Labs on 1 August, not mid-August.	2026-09-05 12:00:00+05:30
8	c2	1	user	I live in Mysuru, work at TCS since July 2024. My favourite food is dosa. I like cricket.	2026-02-14 20:00:00+05:30
9	c2	2	user	These days my favourite food is biryani, honestly.	2026-07-02 19:00:00+05:30
10	ilina-profile	1	user	Hi, I'm Ilina. I'm a research assistant in marine biology and I've lived in Kochi since June 2022. I speak Malayalam, English and French.	2026-01-14 19:10:00+05:30
11	ilina-profile	2	user	I love scuba diving, birdwatching and sci-fi novels. My favourite food is appam with stew.	2026-02-05 21:30:00+05:30
12	ilina-profile	3	user	At work I mostly do coral taxonomy and GIS mapping, and I analyse survey data in R.	2026-02-22 18:05:00+05:30
13	ilina-fieldwork	1	user	Great news: I accepted a field fellowship at the Coral Reef Institute as a Field Fellow, starting 1 June.	2026-04-16 18:45:00+05:30
14	ilina-fieldwork	2	user	Moved to Port Blair on 30 May for the fellowship. The station is right by the jetty.	2026-06-04 09:20:00+05:30
15	ilina-fieldwork	3	user	Small correction: the fellowship actually started on 25 May, not 1 June. The dive season opened early.	2026-06-21 20:00:00+05:30
16	ilina-fieldwork	4	user	Two months in, I'm now certified in scientific diving and drone surveying. Also got hooked on kayaking.	2026-07-29 22:10:00+05:30
17	ilina-fieldwork	5	user	The field season ended on 31 July and the institute kept me on as a remote data curator. Back in Kochi since 1 August.	2026-08-04 11:00:00+05:30
18	ilina-home	1	user	Honestly my favourite food these days is fish moilee. The island canteen made it every Friday.	2026-09-11 13:30:00+05:30
19	ilina-home	2	user	I've started recording reef sounds for a new project, so add bioacoustics to my skills.	2026-10-06 17:15:00+05:30
20	rehaan	1	user	I'm from Jaipur, lived here all my life. I speak Hindi and Marwari, and dal baati is my favourite food.	2026-01-27 18:00:00+05:30
21	rehaan	2	user	I've been a sous chef at Marigold Kitchen since March 2024. Pastry and fermentation are my thing, and I restore vintage motorcycles on Sundays.	2026-03-03 20:30:00+05:30
22	rehaan	3	user	Promoted to Head Chef on 1 July!	2026-07-15 09:00:00+05:30
23	mahika	1	user	I live in Lucknow and I've been a staff nurse at Lakeview Hospital since August 2023. Poha is my comfort food.	2026-02-11 21:00:00+05:30
24	mahika	2	user	I'm trained in critical care and I unwind with pottery classes.	2026-04-05 19:45:00+05:30
25	mahika	3	user	New job: I joined Riverside Clinic as an ICU Nurse on 18 August and moved to Bhopal.	2026-08-26 14:00:00+05:30
26	darsh	1	user	I live in Shillong and teach violin at Hillside Conservatory since January 2025. Momos forever.	2026-03-19 16:20:00+05:30
27	darsh	2	user	I became Head of Strings at the conservatory from today, and I'm also teaching music theory now.	2026-09-02 10:15:00+05:30
\.


--
-- Name: entities_entity_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.entities_entity_id_seq', 29, true);


--
-- Name: erasure_audit_audit_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.erasure_audit_audit_id_seq', 1, false);


--
-- Name: fact_corrections_correction_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.fact_corrections_correction_id_seq', 3, true);


--
-- Name: facts_fact_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.facts_fact_id_seq', 89, true);


--
-- Name: predicates_predicate_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.predicates_predicate_id_seq', 7, true);


--
-- Name: sources_source_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.sources_source_id_seq', 27, true);


--
-- Name: entities entities_canonical_name_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.entities
    ADD CONSTRAINT entities_canonical_name_key UNIQUE (canonical_name);


--
-- Name: entities entities_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.entities
    ADD CONSTRAINT entities_pkey PRIMARY KEY (entity_id);


--
-- Name: entity_aliases entity_aliases_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.entity_aliases
    ADD CONSTRAINT entity_aliases_pkey PRIMARY KEY (alias);


--
-- Name: erasure_audit erasure_audit_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.erasure_audit
    ADD CONSTRAINT erasure_audit_pkey PRIMARY KEY (audit_id);


--
-- Name: fact_corrections fact_corrections_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.fact_corrections
    ADD CONSTRAINT fact_corrections_pkey PRIMARY KEY (correction_id);


--
-- Name: facts facts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.facts
    ADD CONSTRAINT facts_pkey PRIMARY KEY (fact_id);


--
-- Name: facts no_contradictory_beliefs; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.facts
    ADD CONSTRAINT no_contradictory_beliefs EXCLUDE USING gist (subject_id WITH =, predicate_id WITH =, valid_period WITH &&, sys_period WITH &&) WHERE (single_valued);


--
-- Name: predicates predicates_name_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.predicates
    ADD CONSTRAINT predicates_name_key UNIQUE (name);


--
-- Name: predicates predicates_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.predicates
    ADD CONSTRAINT predicates_pkey PRIMARY KEY (predicate_id);


--
-- Name: sources sources_conversation_id_turn_no_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sources
    ADD CONSTRAINT sources_conversation_id_turn_no_key UNIQUE (conversation_id, turn_no);


--
-- Name: sources sources_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sources
    ADD CONSTRAINT sources_pkey PRIMARY KEY (source_id);


--
-- Name: aliases_trgm; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX aliases_trgm ON public.entity_aliases USING gin (alias public.gin_trgm_ops);


--
-- Name: entities_name_trgm; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX entities_name_trgm ON public.entities USING gin (canonical_name public.gin_trgm_ops);


--
-- Name: fact_corrections_actor_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX fact_corrections_actor_idx ON public.fact_corrections USING btree (actor);


--
-- Name: fact_corrections_fact_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX fact_corrections_fact_idx ON public.fact_corrections USING btree (fact_id);


--
-- Name: facts_current_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX facts_current_idx ON public.facts USING btree (subject_id, predicate_id) WHERE upper_inf(sys_period);


--
-- Name: facts_subject_pred_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX facts_subject_pred_idx ON public.facts USING btree (subject_id, predicate_id);


--
-- Name: facts_sys_gist; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX facts_sys_gist ON public.facts USING gist (sys_period);


--
-- Name: facts_valid_gist; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX facts_valid_gist ON public.facts USING gist (valid_period);


--
-- Name: facts trg_facts_before_insert; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_facts_before_insert BEFORE INSERT ON public.facts FOR EACH ROW EXECUTE FUNCTION public.facts_before_insert();


--
-- Name: facts trg_facts_before_update; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_facts_before_update BEFORE UPDATE ON public.facts FOR EACH ROW EXECUTE FUNCTION public.facts_before_update();


--
-- Name: facts trg_facts_block_delete; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_facts_block_delete BEFORE DELETE ON public.facts FOR EACH ROW EXECUTE FUNCTION public.facts_block_delete();


--
-- Name: facts trg_facts_block_truncate; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_facts_block_truncate BEFORE TRUNCATE ON public.facts FOR EACH STATEMENT EXECUTE FUNCTION public.facts_block_delete();


--
-- Name: predicates trg_predicates_freeze; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_predicates_freeze BEFORE UPDATE ON public.predicates FOR EACH ROW EXECUTE FUNCTION public.predicates_freeze_flag();


--
-- Name: entity_aliases entity_aliases_entity_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.entity_aliases
    ADD CONSTRAINT entity_aliases_entity_id_fkey FOREIGN KEY (entity_id) REFERENCES public.entities(entity_id) ON DELETE CASCADE;


--
-- Name: fact_corrections fact_corrections_fact_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.fact_corrections
    ADD CONSTRAINT fact_corrections_fact_id_fkey FOREIGN KEY (fact_id) REFERENCES public.facts(fact_id) ON DELETE CASCADE;


--
-- Name: facts facts_object_entity_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.facts
    ADD CONSTRAINT facts_object_entity_id_fkey FOREIGN KEY (object_entity_id) REFERENCES public.entities(entity_id);


--
-- Name: facts facts_predicate_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.facts
    ADD CONSTRAINT facts_predicate_id_fkey FOREIGN KEY (predicate_id) REFERENCES public.predicates(predicate_id);


--
-- Name: facts facts_source_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.facts
    ADD CONSTRAINT facts_source_id_fkey FOREIGN KEY (source_id) REFERENCES public.sources(source_id);


--
-- Name: facts facts_subject_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.facts
    ADD CONSTRAINT facts_subject_id_fkey FOREIGN KEY (subject_id) REFERENCES public.entities(entity_id);


--
-- PostgreSQL database dump complete
--

\unrestrict p8zBF12QJWwCFRrM6su3bQSqNA32RqgB8napHvuXGYW3fwDsg2FPgyrIsVYDwBB

