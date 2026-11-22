-- =====================================================================
-- 003_functions_views.sql  --  helpers, supersession, views, as-of queries
-- =====================================================================

-- Find-or-create an entity by name (case-insensitive via the alias table).
CREATE FUNCTION ensure_entity(p_name text, p_type text DEFAULT 'thing') RETURNS bigint
LANGUAGE plpgsql AS $$
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

-- Store a conversation turn (provenance); returns source_id.
CREATE FUNCTION log_source(p_conversation text, p_turn int, p_speaker text,
                           p_content text, p_occurred_at timestamptz) RETURNS bigint
LANGUAGE sql AS $$
  INSERT INTO sources (conversation_id, turn_no, speaker, content, occurred_at)
  VALUES (p_conversation, p_turn, p_speaker, p_content, p_occurred_at)
  ON CONFLICT (conversation_id, turn_no) DO UPDATE SET content = EXCLUDED.content
  RETURNING source_id
$$;

-- Supersede a SINGLE-valued fact. One transaction, three kinds of write:
--   1. close the sys_period of every currently-believed row the new fact overlaps
--   2. re-insert the part of the old fact that stays true (valid time truncated)
--   3. insert the new fact (open-ended from p_valid_from)
-- Works for real-world change AND for corrections ("actually I started on 1 Aug").
CREATE FUNCTION supersede_fact(p_subject bigint, p_predicate int, p_obj_entity bigint, p_obj_text text,
                               p_source bigint, p_valid_from timestamptz, p_confidence real DEFAULT 1.0)
RETURNS bigint LANGUAGE plpgsql AS $$
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

-- Convenience entry point by NAMES (this is what the Phase 2 pipeline will call).
CREATE FUNCTION remember(p_subject text, p_predicate text, p_object text, p_source bigint,
                         p_valid_from timestamptz DEFAULT memory_now(), p_confidence real DEFAULT 1.0,
                         p_subject_type text DEFAULT 'person', p_object_type text DEFAULT 'thing')
RETURNS bigint LANGUAGE plpgsql AS $$
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

-- ---------- reading ----------
-- What is true now, according to what we believe now.
CREATE VIEW current_facts AS
SELECT f.fact_id, s.canonical_name AS subject, p.name AS predicate,
       COALESCE(o.canonical_name, f.object_text) AS object,
       f.valid_period, f.confidence, f.source_id
FROM facts f
JOIN entities   s ON s.entity_id    = f.subject_id
JOIN predicates p ON p.predicate_id = f.predicate_id
LEFT JOIN entities o ON o.entity_id = f.object_entity_id
WHERE f.valid_period @> memory_now() AND f.sys_period @> memory_now();

-- "What was true on date X, according to what the system knew on date Y?"
CREATE FUNCTION facts_as_of(p_valid timestamptz, p_believed timestamptz DEFAULT memory_now())
RETURNS TABLE (fact_id bigint, subject text, predicate text, object text,
               valid_period tstzrange, sys_period tstzrange, confidence real, source_id bigint)
LANGUAGE sql STABLE AS $$
  SELECT f.fact_id, s.canonical_name, p.name, COALESCE(o.canonical_name, f.object_text),
         f.valid_period, f.sys_period, f.confidence, f.source_id
  FROM facts f
  JOIN entities   s ON s.entity_id    = f.subject_id
  JOIN predicates p ON p.predicate_id = f.predicate_id
  LEFT JOIN entities o ON o.entity_id = f.object_entity_id
  WHERE f.valid_period @> p_valid AND f.sys_period @> p_believed
$$;

-- Every row ever stored for one subject+predicate (great for demos and screenshots).
CREATE FUNCTION fact_history(p_subject text, p_predicate text)
RETURNS TABLE (fact_id bigint, object text, valid_period tstzrange, sys_period tstzrange, source_id bigint)
LANGUAGE sql STABLE AS $$
  SELECT f.fact_id, COALESCE(o.canonical_name, f.object_text), f.valid_period, f.sys_period, f.source_id
  FROM facts f
  JOIN entities   s ON s.entity_id    = f.subject_id
  JOIN predicates p ON p.predicate_id = f.predicate_id
  LEFT JOIN entities o ON o.entity_id = f.object_entity_id
  WHERE lower(s.canonical_name) = lower(btrim(p_subject)) AND p.name = lower(p_predicate)
  ORDER BY lower(f.sys_period), lower(f.valid_period), f.fact_id
$$;
