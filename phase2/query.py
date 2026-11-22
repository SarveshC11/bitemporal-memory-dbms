from __future__ import annotations

import re
from dataclasses import dataclass
import calendar
from datetime import datetime, timedelta
from typing import Any


@dataclass(frozen=True)
class QueryRoute:
    kind: str
    valid_at: datetime | None = None
    believed_at: datetime | None = None
    subject: str | None = None
    predicate: str | None = None


class QueryRoutingError(ValueError):
    """Raised when a temporal query contains an unsupported date."""


_DATE = re.compile(r"\b(\d{4}-\d{2}-\d{2})\b")
_YEAR = re.compile(r"\b(20\d{2}|19\d{2})\b")
_MONTH_NAMES = {name.lower(): number for number, name in enumerate(calendar.month_name) if number}
_MONTH_NAMES.update({name.lower(): number for number, name in enumerate(calendar.month_abbr) if number})


def _month_range(question: str, reference: datetime) -> tuple[datetime, datetime] | None:
    for name, number in _MONTH_NAMES.items():
        if re.search(rf"\b{re.escape(name)}\b", question.lower()):
            year_match = re.search(r"\b(20\d{2}|19\d{2})\b", question)
            year = int(year_match.group(1)) if year_match else reference.year
            if not year_match and number > reference.month:
                year -= 1
            start = datetime(year, number, 1)
            end = datetime(year + 1, 1, 1) if number == 12 else datetime(year, number + 1, 1)
            return start, end
    return None


def _extract_subject(question: str) -> str | None:
    match = re.search(
        r"\b(?:what\s+(?:does|did|is)|where\s+(?:does|did))\s+"
        r"([A-Z][A-Za-z'-]*|[a-z]+)"
        r"|\b(?:for|about|did)\s+([A-Z][A-Za-z][A-Za-z'-]*|[a-z]+)",
        question,
        re.IGNORECASE,
    )
    if match:
        value = match.group(1) or match.group(2)
        if value.lower() not in {"the", "system", "i", "you"}:
            return re.sub(r"'s$", "", value, flags=re.IGNORECASE)
    match = re.search(r"\b(?:did|does|where did|where does)\s+([A-Z][A-Za-z'-]*)", question)
    if not match:
        return None
    return re.sub(r"'s$", "", match.group(1), flags=re.IGNORECASE)


def _extract_predicate(question: str) -> str | None:
    lowered = question.lower()
    if re.search(r"\b(?:favorite|favourite)\s+food\b", lowered):
        return "favourite_food"
    if re.search(r"\b(?:like|likes|liked)\b", lowered):
        return "likes"
    if re.search(r"\bwhere\b.*\b(work|employ|job|works)\b|\b(work(ed|s|ing)?|employer|employment)\b", lowered):
        return "works_at"
    if re.search(r"\bwhere\b.*\b(live|lives|living|based|reside)\b", lowered):
        return "lives_in"
    if re.search(r"\b(role|job title|position)\b", lowered):
        return "has_role"
    if re.search(r"\bskill(ed|s)?\b", lowered):
        return "skilled_in"
    return None


def route_query(question: str, reference_time: datetime | None = None) -> QueryRoute:
    """Route explicit temporal questions without asking an LLM to choose SQL."""
    reference = reference_time or datetime.now()
    dates = [datetime.fromisoformat(value) for value in _DATE.findall(question)]
    lowered = question.lower()
    subject = _extract_subject(question)
    predicate = _extract_predicate(question)

    if re.search(r"\bwhen\b.*\b(change|changed|supersed|update|updated|correct|corrected)\b", lowered):
        if not subject or not predicate:
            raise QueryRoutingError("fact-change questions require an identifiable subject and predicate")
        return QueryRoute("history", subject=subject, predicate=predicate)

    if "what did" in lowered or "believed" in lowered or "think" in lowered:
        if len(dates) >= 2:
            about_match = re.search(r"\babout\s+(?:[A-Za-z'-]+\s+)?(\d{4}-\d{2}-\d{2})", lowered)
            on_match = re.search(r"\bon\s+(\d{4}-\d{2}-\d{2})", lowered)
            if about_match and on_match:
                valid_at = datetime.fromisoformat(about_match.group(1))
                believed_at = datetime.fromisoformat(on_match.group(1))
            else:
                valid_at, believed_at = dates[0], dates[1]
            return QueryRoute("as_of", valid_at, believed_at, subject, predicate)
        month_range = _month_range(question, reference)
        if month_range:
            return QueryRoute("as_of", month_range[0], month_range[1], subject, predicate)
        raise QueryRoutingError("past-belief questions require valid and belief dates or an explicit month/year")

    month_range = _month_range(question, reference)
    if month_range:
        return QueryRoute("as_of", month_range[0], month_range[1], subject, predicate)

    if dates:
        return QueryRoute("as_of", dates[0], dates[0], subject, predicate)

    year_match = _YEAR.search(question)
    if year_match:
        year = int(year_match.group(1))
        return QueryRoute("as_of", datetime(year, 1, 1), datetime(year, 1, 1), subject, predicate)
    return QueryRoute("current", subject=subject, predicate=predicate)


def execute_query(connection: Any, subject: str, predicate: str, route: QueryRoute) -> list[dict[str, Any]]:
    """Execute a routed query using parameterized SQL."""
    with connection.cursor() as cursor:
        if route.kind == "history":
            cursor.execute(
                """
                SELECT * FROM fact_history(%s, %s)
                """,
                (route.subject or subject, route.predicate or predicate),
            )
        elif route.kind == "current":
            cursor.execute(
                """
                SELECT subject, predicate, object, valid_period, confidence, source_id
                FROM current_facts
                WHERE lower(subject) = lower(%s) AND predicate = lower(%s)
                ORDER BY fact_id
                """,
                (subject, predicate),
            )
        elif route.kind == "as_of" and route.valid_at and route.believed_at:
            cursor.execute(
                """
                SELECT fact_id, subject, predicate, object, valid_period,
                       sys_period, confidence, source_id
                FROM facts_as_of(%s, %s)
                WHERE lower(subject) = lower(%s) AND predicate = lower(%s)
                ORDER BY fact_id
                """,
                (route.valid_at, route.believed_at, subject, predicate),
            )
        else:
            raise QueryRoutingError("invalid query route")
        columns = [column.name for column in cursor.description]
        rows: list[dict[str, Any]] = []
        for row in cursor.fetchall():
            converted: dict[str, Any] = {}
            for column, value in zip(columns, row):
                converted[column] = (
                    str(value)
                    if value is not None
                    and not isinstance(value, (str, int, float, bool, list, dict))
                    else value
                )
            rows.append(converted)
        return rows
