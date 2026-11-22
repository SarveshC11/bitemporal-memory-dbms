\set ON_ERROR_STOP on
BEGIN;

DO $$
DECLARE result record;
BEGIN
  SELECT * INTO result
  FROM facts_changed_between('Priya', 'works_at', '2026-08-10', '2026-09-10', '2026-08-25');
  IF NOT result.changed OR result.before_objects <> ARRAY['Infosys']
     OR result.after_objects <> ARRAY['Zeta Labs'] THEN
    RAISE EXCEPTION 'FAIL P3-1: unexpected temporal diff: %', result;
  END IF;
  RAISE NOTICE 'PASS P3-1: temporal diff identifies the corrected employer';
END $$;

DO $$
DECLARE result record; remaining integer;
BEGIN
  SELECT * INTO result FROM forget_subject('Rohan');
  IF result.facts_deleted <> 6 THEN
    RAISE EXCEPTION 'FAIL P3-2: expected 6 Rohan facts, got %', result.facts_deleted;
  END IF;
  SELECT count(*) INTO remaining FROM facts f
    JOIN entities e ON e.entity_id = f.subject_id
    WHERE e.canonical_name = 'Rohan';
  IF remaining <> 0 THEN
    RAISE EXCEPTION 'FAIL P3-2: Rohan facts remain';
  END IF;
  RAISE NOTICE 'PASS P3-2: subject erasure removes all Rohan facts';
END $$;

ROLLBACK;
