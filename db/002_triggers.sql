-- =====================================================================
-- 002_triggers.sql  --  transaction time, immutability, append-only
-- =====================================================================

-- "Transaction time now". Normally just now(). For replaying historical data
-- (seed / evaluation) set:  SELECT set_config('memory.txn_time', '2026-03-10 10:00+05:30', false);
CREATE FUNCTION memory_now() RETURNS timestamptz
LANGUAGE sql STABLE AS $$
  SELECT COALESCE(NULLIF(current_setting('memory.txn_time', true), '')::timestamptz, now())
$$;

-- BEFORE INSERT: system fills transaction time and the single_valued copy.
-- Callers cannot fake either one.
CREATE FUNCTION facts_before_insert() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  SELECT is_single_valued INTO NEW.single_valued
  FROM predicates WHERE predicate_id = NEW.predicate_id;
  NEW.sys_period := tstzrange(memory_now(), NULL, '[)');
  RETURN NEW;
END $$;
CREATE TRIGGER trg_facts_before_insert BEFORE INSERT ON facts
  FOR EACH ROW EXECUTE FUNCTION facts_before_insert();

-- BEFORE UPDATE: the ONLY allowed change is closing sys_period of an open row.
CREATE FUNCTION facts_before_update() RETURNS trigger LANGUAGE plpgsql AS $$
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
CREATE TRIGGER trg_facts_before_update BEFORE UPDATE ON facts
  FOR EACH ROW EXECUTE FUNCTION facts_before_update();

-- BEFORE DELETE / TRUNCATE: append-only, except the right-to-be-forgotten path
-- (Phase 3 wraps this in a proper erase function):  SET LOCAL memory.allow_erasure = 'on';
CREATE FUNCTION facts_block_delete() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF COALESCE(current_setting('memory.allow_erasure', true), 'off') <> 'on' THEN
    RAISE EXCEPTION 'facts are append-only; erasure requires memory.allow_erasure = on'
      USING ERRCODE = 'integrity_constraint_violation';
  END IF;
  RETURN OLD;
END $$;
CREATE TRIGGER trg_facts_block_delete BEFORE DELETE ON facts
  FOR EACH ROW EXECUTE FUNCTION facts_block_delete();
CREATE TRIGGER trg_facts_block_truncate BEFORE TRUNCATE ON facts
  FOR EACH STATEMENT EXECUTE FUNCTION facts_block_delete();

-- A predicate's single-valued flag is copied into facts, so freeze it once facts exist.
CREATE FUNCTION predicates_freeze_flag() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.is_single_valued IS DISTINCT FROM OLD.is_single_valued
     AND EXISTS (SELECT 1 FROM facts WHERE predicate_id = OLD.predicate_id) THEN
    RAISE EXCEPTION 'cannot change is_single_valued of "%": facts already exist', OLD.name;
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_predicates_freeze BEFORE UPDATE ON predicates
  FOR EACH ROW EXECUTE FUNCTION predicates_freeze_flag();
