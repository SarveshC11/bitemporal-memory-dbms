# Bitemporal Memory Store — Phase 1 and Phase 2

## Run it

```bash
docker compose up -d
docker compose exec -T db psql -U memory -d memory -f /tests/005_tests.sql
docker compose exec db psql -U memory -d memory
# start over from scratch: docker compose down -v && docker compose up -d
```

The database is available at `localhost:5433/memory` with user and password
`memory`.

## Try these in psql

```sql
SELECT * FROM current_facts WHERE subject = 'Priya';
SELECT * FROM fact_history('Priya', 'works_at');
SELECT object FROM facts_as_of('2026-08-10', '2026-08-25')
  WHERE subject = 'Priya' AND predicate = 'works_at';
SELECT object FROM facts_as_of('2026-08-10', '2026-09-10')
  WHERE subject = 'Priya' AND predicate = 'works_at';
```

## Phase 2 extraction pipeline

The Phase 2 Python package validates structured extractor output and normalizes it
before anything is written to PostgreSQL:

```powershell
python -m unittest discover -s tests -p "test_*.py"
```

The pipeline takes an extractor callable instead of embedding an API key in the
repository. An LLM adapter can return JSON text or a Python mapping shaped like:

```json
{"facts":[{"subject":"Priya","predicate":"employer","object":"Zeta Labs",
"confidence":0.9,"time_expression":"last week"}]}
```

It resolves dates relative to the conversation timestamp, maps predicate
synonyms to the controlled vocabulary, resolves aliases such as `Blr` to
`Bengaluru`, and rejects unknown or malformed output. The
`phase2.store.remember_facts` helper writes normalized facts through the Phase 1
`log_source` and `remember` functions. Install its database driver with:

```powershell
python -m pip install -r requirements.txt
```

## LLM ambiguity fallback

Phase 3 exposes `AMBIGUITY_PROMPT` and accepts an injected
`ambiguity_resolver` callable. It is called only when deterministic processing
cannot decide, and its response must be JSON with `decision` (`replace`,
`add`, or `reject`) and a non-empty `reason`. Unknown predicate wording must
also return a controlled `predicate`. Invalid responses fail loudly.

For persistence, pass the resolver to `remember_facts`. It receives the
current object, new object, predicate, and source text only when a current
single-valued fact conflicts. `replace` continues through the safe
`remember()` supersession path; `reject` skips the fact; `add` is rejected for
a conflicting single-valued predicate because that would violate the database
invariant. The application can count resolver calls externally for evaluation.

## Files

| File | What it does |
|---|---|
| db/001_schema.sql | Tables, range columns, exclusion constraint, and indexes |
| db/002_triggers.sql | Transaction time, immutability, and append-only enforcement |
| db/003_functions_views.sql | Fact insertion, supersession, and timeline queries |
| db/004_seed.sql | Seven predicates and two hand-written conversations |
| tests/005_tests.sql | Twelve Phase 1 database checks |
| phase2/ | Structured extraction, time resolution, normalization, and persistence |
| tests/test_phase2.py | Phase 2 unit tests |
| db/005_phase3.sql | Temporal diff and right-to-erasure database functions |
| phase2/query.py | Deterministic current/as-of query router |
| tests/006_phase3_tests.sql | Phase 3 database checks |
| tests/test_phase3.py | Phase 3 query-routing tests |
| docs/database-schema.md | Implemented PostgreSQL schema reference |
| docs/er-diagram.md | Mermaid entity relationship diagram |

## Design decisions

- **Supersession = close + truncated copy + insert.** The old row's system
  period is closed, the still-true part is copied with a shortened valid period,
  and the new fact is added.
- **Transaction time is system-controlled.** `memory.txn_time` replays historical
  inserts for seeding and evaluation; unset means `now()`.
- **`single_valued` is copied from `predicates` by trigger**, so callers cannot
  bypass the exclusion constraint.
- **Append-only:** only closing `sys_period` is allowed; deletion requires the
  explicit erasure switch.

## Phase 3

Run the Phase 3 database checks after the database has been initialized:

```powershell
docker compose exec -T db psql -U memory -d memory -f /tests/006_phase3_tests.sql
python -m unittest discover -s tests -p "test_*.py"
```

The database now supports `facts_changed_between(subject, predicate, from, to,
believed_at)`, which compares two valid-time snapshots at a chosen belief time.
`forget_subject(subject)` removes the subject's facts and unreferenced source
content, while keeping only anonymized counts in `erasure_audit`.

The Python router sends current questions to `current_facts` and explicit
date/belief questions to `facts_as_of()`. Dates are parameterized; unsupported
past-belief wording fails instead of silently choosing a date.

## FastAPI application

Start the database and web application:

```powershell
docker compose up -d --build
```

Open <http://localhost:8000>. Enter a subject, conversation ID, turn number,
and prompt. The dashboard displays the extracted facts, current facts, all
stored fact rows (including both timelines), and the original source text.

Without an LLM key, the app uses a small deterministic demo extractor so the
complete storage flow can be tested locally. To use an OpenAI-compatible
structured-output endpoint, set these before starting Docker:

```powershell
$env:LLM_API_KEY = "your-key"
$env:LLM_BASE_URL = "https://api.openai.com/v1"
$env:LLM_MODEL = "gpt-4o-mini"
docker compose up -d --build
```

The key is passed to the container through the environment and is not stored
in the repository. The app API also exposes `POST /api/turn` and `GET
/api/state`; Swagger documentation is available at
<http://localhost:8000/docs>.

## Temporal memory features

The dashboard and API now include:

- Natural-language temporal routes through `POST /api/natural-query`
- Conversation listing, turn history, fact provenance, and replay
- Temporal timelines with optional valid-time and belief-time selectors
- Replace, reject, and restore actions for stored facts
- Correction actor and reason audit records in `fact_corrections`

Correction operations preserve append-only fact history:

- Replacement closes the old fact's system period and inserts a corrected row.
- Rejection closes the fact's system period.
- Restoration inserts a new active copy of an earlier fact.

For a new database, Docker initializes `db/006_features.sql` automatically.
For an existing Docker volume, recreate it before restarting:

```powershell
docker compose down -v
docker compose up -d --build
```
