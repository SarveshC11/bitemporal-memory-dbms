-- =====================================================================
-- 006_features.sql -- corrections, restoration, and conversation features
-- =====================================================================

CREATE TABLE fact_corrections (
  correction_id BIGSERIAL PRIMARY KEY,
  fact_id       BIGINT NOT NULL REFERENCES facts(fact_id) ON DELETE CASCADE,
  action        TEXT NOT NULL CHECK (action IN ('replace', 'reject', 'restore')),
  old_object    TEXT,
  new_object    TEXT,
  actor         TEXT NOT NULL,
  reason        TEXT NOT NULL CHECK (btrim(reason) <> ''),
  corrected_at  TIMESTAMPTZ NOT NULL DEFAULT memory_now()
);

CREATE INDEX fact_corrections_fact_idx ON fact_corrections(fact_id);
CREATE INDEX fact_corrections_actor_idx ON fact_corrections(actor);

CREATE FUNCTION reject_fact(p_fact_id bigint, p_actor text, p_reason text)
RETURNS bigint LANGUAGE plpgsql AS $$
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

CREATE FUNCTION restore_fact(p_fact_id bigint, p_actor text, p_reason text)
RETURNS bigint LANGUAGE plpgsql AS $$
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

CREATE FUNCTION replace_fact(p_fact_id bigint, p_new_object text,
                             p_actor text, p_reason text)
RETURNS bigint LANGUAGE plpgsql AS $$
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
