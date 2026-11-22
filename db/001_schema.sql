-- =====================================================================
-- 001_schema.sql  --  Bitemporal Memory Store: tables, constraints, indexes
-- =====================================================================
CREATE EXTENSION IF NOT EXISTS btree_gist;   -- lets GiST handle "=" on ints next to "&&" on ranges
CREATE EXTENSION IF NOT EXISTS pg_trgm;      -- fuzzy entity matching (used in Phase 2)

DO $$ BEGIN
  EXECUTE format('ALTER DATABASE %I SET timezone TO %L', current_database(), 'Asia/Kolkata');
END $$;

-- ---------- entities & aliases ("Blr" and "Bengaluru" -> one row) ----------
CREATE TABLE entities (
  entity_id      BIGSERIAL PRIMARY KEY,
  canonical_name TEXT NOT NULL UNIQUE,
  entity_type    TEXT NOT NULL DEFAULT 'thing'
                 CHECK (entity_type IN ('person','org','place','thing')),
  created_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE entity_aliases (
  alias     TEXT PRIMARY KEY CHECK (alias = lower(btrim(alias))),
  entity_id BIGINT NOT NULL REFERENCES entities(entity_id) ON DELETE CASCADE
);

-- ---------- controlled predicate vocabulary ----------
CREATE TABLE predicates (
  predicate_id     SERIAL PRIMARY KEY,
  name             TEXT NOT NULL UNIQUE CHECK (name = lower(name)),
  is_single_valued BOOLEAN NOT NULL,                 -- one answer at a time? (lives_in = yes, likes = no)
  value_type       TEXT NOT NULL CHECK (value_type IN ('entity','text')),
  description      TEXT
);

-- ---------- provenance: the conversation turn a fact came from ----------
CREATE TABLE sources (
  source_id       BIGSERIAL PRIMARY KEY,
  conversation_id TEXT NOT NULL,
  turn_no         INT  NOT NULL,
  speaker         TEXT NOT NULL DEFAULT 'user',
  content         TEXT NOT NULL,
  occurred_at     TIMESTAMPTZ NOT NULL,
  UNIQUE (conversation_id, turn_no)
);

-- ---------- facts: the bitemporal core ----------
CREATE TABLE facts (
  fact_id          BIGSERIAL PRIMARY KEY,
  subject_id       BIGINT NOT NULL REFERENCES entities(entity_id),
  predicate_id     INT    NOT NULL REFERENCES predicates(predicate_id),
  object_entity_id BIGINT REFERENCES entities(entity_id),
  object_text      TEXT,
  valid_period     TSTZRANGE NOT NULL,                              -- when it was TRUE in the world
  sys_period       TSTZRANGE NOT NULL DEFAULT tstzrange(now(), NULL), -- when the system BELIEVED it (trigger-managed)
  confidence       REAL NOT NULL DEFAULT 1.0 CHECK (confidence BETWEEN 0 AND 1),
  source_id        BIGINT NOT NULL REFERENCES sources(source_id),
  single_valued    BOOLEAN NOT NULL DEFAULT false,                  -- copied from predicates by trigger

  CONSTRAINT exactly_one_object CHECK (num_nonnulls(object_entity_id, object_text) = 1),
  CONSTRAINT valid_period_wellformed CHECK (
    NOT isempty(valid_period) AND NOT lower_inf(valid_period)
    AND lower_inc(valid_period) AND NOT upper_inc(valid_period)),

  -- THE constraint: two different answers to the same question for the same
  -- moment of valid time AND the same moment of belief time cannot coexist.
  CONSTRAINT no_contradictory_beliefs EXCLUDE USING gist (
      subject_id   WITH =,
      predicate_id WITH =,
      valid_period WITH &&,
      sys_period   WITH &&
  ) WHERE (single_valued)
);

-- ---------- indexes (the EXCLUDE constraint already creates one GiST index) ----------
CREATE INDEX facts_subject_pred_idx ON facts (subject_id, predicate_id);
CREATE INDEX facts_current_idx      ON facts (subject_id, predicate_id) WHERE upper_inf(sys_period);
CREATE INDEX facts_valid_gist       ON facts USING gist (valid_period);
CREATE INDEX facts_sys_gist         ON facts USING gist (sys_period);
CREATE INDEX entities_name_trgm     ON entities USING gin (canonical_name gin_trgm_ops);
CREATE INDEX aliases_trgm           ON entity_aliases USING gin (alias gin_trgm_ops);
