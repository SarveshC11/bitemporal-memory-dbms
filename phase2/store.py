from __future__ import annotations

from datetime import datetime
from typing import Iterable

from .models import ExtractedFact
from .normalization import EntityResolver
from typing import Callable

from .ambiguity import AmbiguityDecision, AmbiguityResolutionError, parse_ambiguity_decision


def resolve_conflict(
    connection: object,
    subject: str,
    predicate: str,
    object_value: str,
    context: str,
    resolver: Callable[[dict[str, str]], object],
) -> AmbiguityDecision:
    """Ask the LLM only when a new single-valued fact may conflict."""
    with connection.cursor() as cursor:
        cursor.execute(
            """
            SELECT p.is_single_valued, COALESCE(o.canonical_name, f.object_text)
            FROM facts f
            JOIN entities s ON s.entity_id = f.subject_id
            JOIN predicates p ON p.predicate_id = f.predicate_id
            LEFT JOIN entities o ON o.entity_id = f.object_entity_id
            WHERE lower(s.canonical_name) = lower(%s)
              AND p.name = lower(%s)
              AND f.valid_period @> memory_now()
              AND f.sys_period @> memory_now()
            ORDER BY f.fact_id DESC
            LIMIT 1
            """,
            (subject, predicate),
        )
        current = cursor.fetchone()
    if not current or not current[0] or current[1] == object_value:
        return AmbiguityDecision("replace", "no conflicting single-valued fact exists")
    return parse_ambiguity_decision(resolver({
        "subject": subject,
        "predicate": predicate,
        "current_object": current[1],
        "new_object": object_value,
        "context": context,
    }))


def postgres_entity_resolver(connection: object) -> EntityResolver:
    """Create an entity resolver backed by the Phase 1 alias and trigram indexes."""

    def lookup(value: str) -> str | None:
        with connection.cursor() as cursor:
            cursor.execute(
                """
                SELECT e.canonical_name
                FROM entity_aliases a
                JOIN entities e ON e.entity_id = a.entity_id
                WHERE a.alias = lower(btrim(%s))
                """,
                (value,),
            )
            exact = cursor.fetchone()
            if exact:
                return exact[0]

            cursor.execute(
                """
                SELECT e.canonical_name,
                       similarity(lower(e.canonical_name), lower(btrim(%s))) AS score
                FROM entities e
                ORDER BY score DESC, e.entity_id
                LIMIT 2
                """,
                (value,),
            )
            matches = cursor.fetchall()
            if not matches or matches[0][1] < 0.88:
                return None
            if len(matches) > 1 and matches[0][1] - matches[1][1] < 0.03:
                return None
            return matches[0][0]

    return EntityResolver(fallback=lookup)


def remember_facts(
    connection: object,
    facts: Iterable[ExtractedFact],
    conversation_id: str,
    turn_no: int,
    content: str,
    occurred_at: datetime,
    ambiguity_resolver: Callable[[dict[str, str]], object] | None = None,
    commit: bool = True,
) -> None:
    """Persist normalized facts using the Phase 1 provenance and remember functions."""
    with connection.cursor() as cursor:
        cursor.execute(
            "SELECT log_source(%s, %s, %s, %s, %s)",
            (conversation_id, turn_no, "user", content, occurred_at),
        )
        source_id = cursor.fetchone()[0]
        for fact in facts:
            if ambiguity_resolver:
                decision = resolve_conflict(
                    connection, fact.subject, fact.predicate, fact.object,
                    content, ambiguity_resolver,
                )
                if decision.decision == "reject":
                    continue
                if decision.decision == "add":
                    cursor.execute(
                        """
                        SELECT is_single_valued FROM predicates
                        WHERE name = lower(%s)
                        """,
                        (fact.predicate,),
                    )
                    predicate_row = cursor.fetchone()
                    if predicate_row and predicate_row[0]:
                        raise AmbiguityResolutionError(
                            "resolver chose add for a conflicting single-valued fact"
                        )
            cursor.execute(
                """
                SELECT remember(
                    %s::text, %s::text, %s::text, %s::bigint,
                    %s::timestamptz, %s::real
                )
                """,
                (
                    fact.subject,
                    fact.predicate,
                    fact.object,
                    source_id,
                    fact.valid_from,
                    fact.confidence,
                ),
            )
    if commit:
        connection.commit()
