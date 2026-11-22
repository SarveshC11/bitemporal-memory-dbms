# Entity relationship diagram

```mermaid
erDiagram
    ENTITIES {
        bigint entity_id PK
        text canonical_name UK
        text entity_type
        timestamptz created_at
    }

    ENTITY_ALIASES {
        text alias PK
        bigint entity_id FK
    }

    PREDICATES {
        int predicate_id PK
        text name UK
        boolean is_single_valued
        text value_type
        text description
    }

    SOURCES {
        bigint source_id PK
        text conversation_id
        int turn_no
        text speaker
        text content
        timestamptz occurred_at
    }

    FACTS {
        bigint fact_id PK
        bigint subject_id FK
        int predicate_id FK
        bigint object_entity_id FK
        text object_text
        tstzrange valid_period
        tstzrange sys_period
        real confidence
        bigint source_id FK
        boolean single_valued
    }

    ERASURE_AUDIT {
        bigint audit_id PK
        timestamptz erased_at
        int facts_deleted
        int sources_deleted
    }

    ENTITIES ||--o{ ENTITY_ALIASES : "has aliases"
    ENTITIES ||--o{ FACTS : "is subject of"
    ENTITIES ||--o{ FACTS : "is entity object of"
    PREDICATES ||--o{ FACTS : "classifies"
    SOURCES ||--o{ FACTS : "supports"
```

## Relationship notes

- `facts.subject_id` identifies the entity making or having the statement.
- `facts.object_entity_id` is used when the object is another entity, such as
  an employer or city.
- `facts.object_text` is used for text values, such as a favorite food or job
  title.
- A fact has exactly one object representation: entity or text.
- `sources` preserve the original conversation evidence.
- `erasure_audit` is intentionally not connected to a user or entity, so it
  contains only aggregate deletion counts.
