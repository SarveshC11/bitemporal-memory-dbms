-- =====================================================================
-- 005_tests.sql  --  Phase 1 checks. Runs inside a transaction and ROLLS BACK,
-- so it never changes your data.   Any failure stops the script with FAIL.
-- =====================================================================
\set ON_ERROR_STOP on
\set VERBOSITY terse
BEGIN;

-- T1: contradictory overlapping fact is rejected by the exclusion constraint
DO $$
DECLARE ok boolean := false; s bigint;
BEGIN
  PERFORM set_config('memory.txn_time', '2026-10-01 10:00+05:30', true);
  s := log_source('t', 1, 'user', 'test', now());
  BEGIN
    INSERT INTO facts (subject_id, predicate_id, object_entity_id, valid_period, source_id)
    VALUES (ensure_entity('Priya'), (SELECT predicate_id FROM predicates WHERE name='works_at'),
            ensure_entity('Wipro','org'), tstzrange('2026-09-01 00:00+05:30', NULL), s);
  EXCEPTION WHEN exclusion_violation THEN ok := true;
  END;
  IF NOT ok THEN RAISE EXCEPTION 'FAIL T1: overlapping contradictory fact was accepted'; END IF;
  RAISE NOTICE 'PASS T1: overlapping contradictory belief rejected (exclusion constraint)';
END $$;

-- T2: the caller cannot bypass the constraint by lying in single_valued
DO $$
DECLARE ok boolean := false; s bigint := (SELECT min(source_id) FROM sources);
BEGIN
  PERFORM set_config('memory.txn_time', '2026-10-01 10:00+05:30', true);
  BEGIN
    INSERT INTO facts (subject_id, predicate_id, object_entity_id, valid_period, source_id, single_valued)
    VALUES (ensure_entity('Priya'), (SELECT predicate_id FROM predicates WHERE name='works_at'),
            ensure_entity('Wipro','org'), tstzrange('2026-09-01 00:00+05:30', NULL), s, false);
  EXCEPTION WHEN exclusion_violation THEN ok := true;
  END;
  IF NOT ok THEN RAISE EXCEPTION 'FAIL T2: single_valued=false bypassed the constraint'; END IF;
  RAISE NOTICE 'PASS T2: single_valued flag is system-controlled';
END $$;

-- T3: a fact whose valid time does NOT overlap is allowed (an older job)
DO $$
DECLARE s bigint := (SELECT min(source_id) FROM sources);
BEGIN
  PERFORM set_config('memory.txn_time', '2026-10-01 10:00+05:30', true);
  INSERT INTO facts (subject_id, predicate_id, object_entity_id, valid_period, source_id)
  VALUES (ensure_entity('Priya'), (SELECT predicate_id FROM predicates WHERE name='works_at'),
          ensure_entity('Wipro','org'), tstzrange('2024-01-01 00:00+05:30', '2025-01-01 00:00+05:30'), s);
  RAISE NOTICE 'PASS T3: non-overlapping valid time accepted';
END $$;

-- T4: multi-valued predicates may hold several values at once
DO $$
DECLARE n int; s bigint := (SELECT min(source_id) FROM sources);
BEGIN
  PERFORM set_config('memory.txn_time', '2026-10-01 10:00+05:30', true);
  PERFORM remember('Priya', 'likes', 'chess', s);
  SELECT count(*) INTO n FROM current_facts WHERE subject='Priya' AND predicate='likes';
  IF n <> 3 THEN RAISE EXCEPTION 'FAIL T4: expected 3 current likes, got %', n; END IF;
  RAISE NOTICE 'PASS T4: multi-valued predicate holds 3 values at once';
END $$;

-- T5: facts cannot be edited in place
DO $$
DECLARE ok boolean := false;
BEGIN
  BEGIN UPDATE facts SET confidence = 0.1 WHERE fact_id = 1;
  EXCEPTION WHEN integrity_constraint_violation THEN ok := true; END;
  IF NOT ok THEN RAISE EXCEPTION 'FAIL T5: in-place update allowed'; END IF;
  RAISE NOTICE 'PASS T5: in-place edits rejected (only closing sys_period is allowed)';
END $$;

-- T6: delete blocked by default, allowed only with the erasure switch
--     (deletes only the throw-away Wipro row created in T3)
DO $$
DECLARE ok boolean := false; n int; w bigint := ensure_entity('Wipro','org');
BEGIN
  BEGIN DELETE FROM facts WHERE object_entity_id = w;
  EXCEPTION WHEN integrity_constraint_violation THEN ok := true; END;
  IF NOT ok THEN RAISE EXCEPTION 'FAIL T6a: delete allowed without switch'; END IF;
  PERFORM set_config('memory.allow_erasure', 'on', true);
  DELETE FROM facts WHERE object_entity_id = w;
  PERFORM set_config('memory.allow_erasure', 'off', true);
  SELECT count(*) INTO n FROM facts WHERE object_entity_id = w;
  IF n <> 0 THEN RAISE EXCEPTION 'FAIL T6b: erasure did not delete'; END IF;
  RAISE NOTICE 'PASS T6: append-only, erasure only via explicit switch';
END $$;

-- T7: provenance is mandatory
DO $$
DECLARE ok boolean := false;
BEGIN
  BEGIN
    INSERT INTO facts (subject_id, predicate_id, object_text, valid_period)
    VALUES (ensure_entity('Priya'), (SELECT predicate_id FROM predicates WHERE name='has_role'),
            'X', tstzrange('2030-01-01 00:00+05:30', NULL));
  EXCEPTION WHEN not_null_violation THEN ok := true; END;
  IF NOT ok THEN RAISE EXCEPTION 'FAIL T7: fact without a source accepted'; END IF;
  RAISE NOTICE 'PASS T7: every fact must have a source';
END $$;

-- T8: unknown predicate is refused (controlled vocabulary)
DO $$
DECLARE ok boolean := false;
BEGIN
  BEGIN PERFORM remember('Priya', 'is_married_to', 'X', (SELECT min(source_id) FROM sources));
  EXCEPTION WHEN raise_exception THEN ok := true; END;
  IF NOT ok THEN RAISE EXCEPTION 'FAIL T8: unknown predicate accepted'; END IF;
  RAISE NOTICE 'PASS T8: unknown predicate rejected';
END $$;

-- T9: the Priya story, queried on BOTH timelines
DO $$
DECLARE v text;
BEGIN
  PERFORM set_config('memory.txn_time', '2026-10-01 10:00+05:30', true);

  SELECT object INTO v FROM current_facts WHERE subject='Priya' AND predicate='works_at';
  IF v IS DISTINCT FROM 'Zeta Labs' THEN RAISE EXCEPTION 'FAIL T9a: current employer = %', v; END IF;

  SELECT object INTO v FROM facts_as_of('2026-03-01 00:00+05:30') WHERE subject='Priya' AND predicate='works_at';
  IF v IS DISTINCT FROM 'Infosys' THEN RAISE EXCEPTION 'FAIL T9b: employer in March = %', v; END IF;

  -- 10 Aug: on 25 Aug we believed Infosys; after the 5 Sep correction we believe Zeta Labs
  SELECT object INTO v FROM facts_as_of('2026-08-10 00:00+05:30', '2026-08-25 00:00+05:30')
   WHERE subject='Priya' AND predicate='works_at';
  IF v IS DISTINCT FROM 'Infosys' THEN RAISE EXCEPTION 'FAIL T9c: belief on 25 Aug about 10 Aug = %', v; END IF;

  SELECT object INTO v FROM facts_as_of('2026-08-10 00:00+05:30', '2026-09-10 00:00+05:30')
   WHERE subject='Priya' AND predicate='works_at';
  IF v IS DISTINCT FROM 'Zeta Labs' THEN RAISE EXCEPTION 'FAIL T9d: belief on 10 Sep about 10 Aug = %', v; END IF;

  SELECT object INTO v FROM current_facts WHERE subject='Priya' AND predicate='lives_in';
  IF v IS DISTINCT FROM 'Pune' THEN RAISE EXCEPTION 'FAIL T9e: current city = %', v; END IF;

  SELECT object INTO v FROM facts_as_of('2026-06-01 00:00+05:30') WHERE subject='Priya' AND predicate='has_role';
  IF v IS DISTINCT FROM 'Senior Engineer' THEN RAISE EXCEPTION 'FAIL T9f: role in June = %', v; END IF;

  SELECT object INTO v FROM facts_as_of('2026-03-01 00:00+05:30') WHERE subject='Rohan' AND predicate='favourite_food';
  IF v IS DISTINCT FROM 'Dosa' THEN RAISE EXCEPTION 'FAIL T9g: Rohan food in March = %', v; END IF;
  SELECT object INTO v FROM current_facts WHERE subject='Rohan' AND predicate='favourite_food';
  IF v IS DISTINCT FROM 'Biryani' THEN RAISE EXCEPTION 'FAIL T9h: Rohan food now = %', v; END IF;

  RAISE NOTICE 'PASS T9: current / past-date / past-belief answers all correct';
END $$;

-- T10: history is complete - nothing was lost, exactly 2 rows still believed
DO $$
DECLARE total int; open_rows int;
BEGIN
  SELECT count(*), count(*) FILTER (WHERE upper_inf(sys_period)) INTO total, open_rows
  FROM facts f JOIN entities e ON e.entity_id=f.subject_id
  WHERE e.canonical_name='Priya' AND f.predicate_id=(SELECT predicate_id FROM predicates WHERE name='works_at')
    AND f.object_entity_id <> ensure_entity('Wipro','org');
  IF total <> 5 OR open_rows <> 2 THEN
    RAISE EXCEPTION 'FAIL T10: works_at rows=% (want 5), open=% (want 2)', total, open_rows;
  END IF;
  RAISE NOTICE 'PASS T10: 5 historical rows kept, 2 currently believed';
END $$;

-- T11: re-asserting a known fact is idempotent
DO $$
DECLARE a bigint; b bigint; before int; after int; s bigint := (SELECT min(source_id) FROM sources);
BEGIN
  PERFORM set_config('memory.txn_time', '2026-10-02 10:00+05:30', true);
  SELECT count(*) INTO before FROM facts;
  a := remember('Priya', 'works_at', 'Zeta Labs', s, '2026-08-01 00:00+05:30', 1.0, p_object_type => 'org');
  b := remember('Priya', 'works_at', 'Zeta Labs', s, '2026-08-01 00:00+05:30', 1.0, p_object_type => 'org');
  SELECT count(*) INTO after FROM facts;
  IF a <> b OR before <> after THEN RAISE EXCEPTION 'FAIL T11: duplicate assertion created rows'; END IF;
  RAISE NOTICE 'PASS T11: repeated assertion is a no-op';
END $$;

-- T12: seed size
DO $$
DECLARE n int;
BEGIN
  SELECT count(*) INTO n FROM facts;
  IF n < 20 THEN RAISE EXCEPTION 'FAIL T12: only % fact rows', n; END IF;
  RAISE NOTICE 'PASS T12: % fact rows in the store', n;
END $$;

ROLLBACK;
