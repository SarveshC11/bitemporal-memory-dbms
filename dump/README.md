# PostgreSQL dump

`bitemporal_memory.sql` is a plain-SQL `pg_dump` (PostgreSQL 16) of the full
database: schema, triggers, functions, views, the original Priya/Rohan seed,
and the fictional demo dataset from `db/007_demo_data.sql` (Ilina, Rehaan,
Mahika, Darsh: all people and organisations are made up).

Contents: 89 fact rows, 27 source turns, 8 conversations, 3 audited corrections.

## Restore with Docker

```bash
docker compose up -d db
docker compose exec -T db createdb -U memory memory_restore
docker compose exec -T db psql -U memory -d memory_restore < dump/bitemporal_memory.sql
docker compose exec -T db psql -U memory -d memory_restore -f /tests/005_tests.sql
```

## Restore without Docker

```bash
createdb memory_restore
psql -d memory_restore -f dump/bitemporal_memory.sql
```

A fresh `docker compose up` builds the same data from `db/*.sql` on its own,
so the dump is only needed to load the data into another server.
