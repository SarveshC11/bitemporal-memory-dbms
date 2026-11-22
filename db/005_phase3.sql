-- =====================================================================
-- 005_phase3.sql -- temporal diffs, forgetting policy, and audit
-- =====================================================================

CREATE TABLE erasure_audit (
  audit_id       BIGSERIAL PRIMARY KEY,
  erased_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  facts_deleted  INTEGER NOT NULL CHECK (facts_deleted >= 0),
  sources_deleted INTEGER NOT NULL CHECK (sources_deleted >= 0)
);

-- Compare the facts believed at two valid dates using the current system belief.
CREATE FUNCTION facts_changed_between(
  p_subject text,
  p_predicate text,
  p_from timestamptz,
  p_to timestamptz,
  p_believed timestamptz DEFAULT memory_now()
)
RETURNS TABLE (
  subject text,
  predicate text,
  before_objects text[],
  after_objects text[],
  changed boolean
)
LANGUAGE sql STABLE AS $$
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

-- Permanently remove all facts for one subject while retaining only aggregate
-- audit information. Sources still used by another fact are preserved.
CREATE FUNCTION forget_subject(p_subject text)
RETURNS TABLE (facts_deleted integer, sources_deleted integer)
LANGUAGE plpgsql AS $$
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
