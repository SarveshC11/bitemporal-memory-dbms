# Database schema

The database is PostgreSQL 16. The schema is installed in this order:

1. `db/001_schema.sql`
2. `db/002_triggers.sql`
3. `db/003_functions_views.sql`
4. `db/004_seed.sql`
5. `db/005_phase3.sql`

## Tables

### `entities`

Stores canonical real-world entities such as people, organizations, places,
and things.

| Column | Type | Constraints |
|---|---|---|
| `entity_id` | `BIGSERIAL` | Primary key |
| `canonical_name` | `TEXT` | Required, unique |
| `entity_type` | `TEXT` | `person`, `org`, `place`, or `thing` |
| `created_at` | `TIMESTAMPTZ` | Required, defaults to `now()` |

### `entity_aliases`

Maps alternate names to canonical entities, such as `blr` to `Bengaluru`.

| Column | Type | Constraints |
|---|---|---|
| `alias` | `TEXT` | Primary key, lowercase |
| `entity_id` | `BIGINT` | Foreign key to `entities.entity_id` |

### `predicates`

Defines the controlled fact vocabulary.

| Column | Type | Constraints |
|---|---|---|
| `predicate_id` | `SERIAL` | Primary key |
| `name` | `TEXT` | Required, unique, lowercase |
| `is_single_valued` | `BOOLEAN` | Whether only one value can be true at a time |
| `value_type` | `TEXT` | `entity` or `text` |
| `description` | `TEXT` | Optional |

### `sources`

Stores the original conversation turn from which facts were extracted.

| Column | Type | Constraints |
|---|---|---|
| `source_id` | `BIGSERIAL` | Primary key |
| `conversation_id` | `TEXT` | Required |
| `turn_no` | `INT` | Required |
| `speaker` | `TEXT` | Required |
| `content` | `TEXT` | Required |
| `occurred_at` | `TIMESTAMPTZ` | Required |

There is a unique constraint on `(conversation_id, turn_no)`.

### `facts`

The central bitemporal table.

| Column | Type | Constraints |
|---|---|---|
| `fact_id` | `BIGSERIAL` | Primary key |
| `subject_id` | `BIGINT` | Foreign key to `entities.entity_id` |
| `predicate_id` | `INT` | Foreign key to `predicates.predicate_id` |
| `object_entity_id` | `BIGINT` | Optional foreign key to `entities.entity_id` |
| `object_text` | `TEXT` | Optional text value |
| `valid_period` | `TSTZRANGE` | When the fact was true |
| `sys_period` | `TSTZRANGE` | When the system believed the fact |
| `confidence` | `REAL` | Between `0` and `1` |
| `source_id` | `BIGINT` | Foreign key to `sources.source_id` |
| `single_valued` | `BOOLEAN` | Copied from `predicates` by trigger |

Each fact must contain exactly one object value: either `object_entity_id` or
`object_text`.

The exclusion constraint prevents contradictory beliefs for single-valued
predicates when both `valid_period` and `sys_period` overlap:

```sql
EXCLUDE USING gist (
  subject_id WITH =,
  predicate_id WITH =,
  valid_period WITH &&,
  sys_period WITH &&
)
WHERE (single_valued)
```

### `erasure_audit`

Stores aggregate deletion information without retaining erased fact contents.

| Column | Type | Constraints |
|---|---|---|
| `audit_id` | `BIGSERIAL` | Primary key |
| `erased_at` | `TIMESTAMPTZ` | Required, defaults to `now()` |
| `facts_deleted` | `INTEGER` | Non-negative |
| `sources_deleted` | `INTEGER` | Non-negative |

## Views and functions

- `current_facts`: facts true now according to the current system belief.
- `facts_as_of(valid_time, believed_time)`: two-dimensional temporal lookup.
- `fact_history(subject, predicate)`: complete history for a subject/predicate.
- `remember(...)`: inserts or supersedes a fact.
- `facts_changed_between(...)`: compares two valid-time snapshots.
- `forget_subject(...)`: erases a subject and records aggregate counts.

## Temporal meaning

For a fact:

- `valid_period` answers: “When was this true in the real world?”
- `sys_period` answers: “When did the database believe this?”

This separation preserves corrections and past beliefs instead of overwriting
history.
