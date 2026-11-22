from __future__ import annotations

import calendar
import re
from datetime import datetime, timedelta
from typing import Optional

from .models import ResolvedTime

_MONTHS = {name.lower(): number for number, name in enumerate(calendar.month_name) if name}
_MONTHS.update({name.lower(): number for number, name in enumerate(calendar.month_abbr) if name})


class TimeResolutionError(ValueError):
    """Raised when a time expression cannot be resolved safely."""


def _month_start(year: int, month: int) -> datetime:
    return datetime(year, month, 1)


def _next_month(value: datetime) -> datetime:
    if value.month == 12:
        return datetime(value.year + 1, 1, 1)
    return datetime(value.year, value.month + 1, 1)


def _parse_date(value: str, reference_time: datetime) -> Optional[ResolvedTime]:
    relative_month_match = re.fullmatch(r"([A-Za-z]+)\s+last year", value)
    if relative_month_match:
        month = _MONTHS.get(relative_month_match.group(1).lower())
        if month is not None:
            start = datetime(reference_time.year - 1, month, 1)
            return ResolvedTime(start, _next_month(start), "month")

    iso_match = re.fullmatch(r"\d{4}-\d{2}-\d{2}", value)
    if iso_match:
        return ResolvedTime(datetime.fromisoformat(value), None, "day")

    month_match = re.fullmatch(
        r"(?:(\d{1,2})\s+)?([A-Za-z]+)(?:\s+(\d{4}))?", value
    )
    if not month_match:
        return None
    day_text, month_text, year_text = month_match.groups()
    month = _MONTHS.get(month_text.lower())
    if month is None:
        return None
    year = int(year_text) if year_text else reference_time.year
    if not year_text and month > reference_time.month:
        year -= 1
    day = int(day_text) if day_text else 1
    start = datetime(year, month, day)
    return ResolvedTime(start, _next_month(start) if not day_text else None, "month" if not day_text else "day")


def resolve_time_expression(expression: str, reference_time: datetime) -> ResolvedTime:
    """Resolve a bounded set of expressions relative to the conversation time.

    Unknown expressions raise instead of silently using the current date. This keeps
    extraction errors visible and prevents the LLM from changing temporal semantics.
    """
    value = " ".join(expression.strip().lower().split())
    if not value:
        return ResolvedTime(reference_time, None, "conversation_time")

    parsed = _parse_date(value, reference_time)
    if parsed:
        return parsed

    if value in {"today", "now", "currently"}:
        return ResolvedTime(reference_time, None, "day")
    if value == "yesterday":
        start = reference_time.replace(hour=0, minute=0, second=0, microsecond=0) - timedelta(days=1)
        return ResolvedTime(start, start + timedelta(days=1), "day")

    if value in {"last week", "previous week"}:
        this_monday = (reference_time - timedelta(days=reference_time.weekday())).replace(
            hour=0, minute=0, second=0, microsecond=0
        )
        return ResolvedTime(this_monday - timedelta(days=7), this_monday, "week")
    if value in {"last month", "previous month"}:
        this_month = _month_start(reference_time.year, reference_time.month)
        previous_month = datetime(
            this_month.year - 1 if this_month.month == 1 else this_month.year,
            12 if this_month.month == 1 else this_month.month - 1,
            1,
        )
        return ResolvedTime(previous_month, this_month, "month")
    if value in {"last year", "previous year"}:
        return ResolvedTime(datetime(reference_time.year - 1, 1, 1), datetime(reference_time.year, 1, 1), "year")

    since_match = re.fullmatch(r"(?:since|from)\s+(.+)", value)
    if since_match:
        parsed = _parse_date(since_match.group(1), reference_time)
        if parsed:
            return ResolvedTime(parsed.start, None, parsed.precision)

    relative_match = re.fullmatch(r"(\d+)\s+(day|week|month|year)s?\s+ago", value)
    if relative_match:
        amount, unit = int(relative_match.group(1)), relative_match.group(2)
        if unit == "day":
            start = reference_time - timedelta(days=amount)
        elif unit == "week":
            start = reference_time - timedelta(weeks=amount)
        elif unit == "month":
            month_index = reference_time.year * 12 + reference_time.month - 1 - amount
            start = datetime(month_index // 12, month_index % 12 + 1, 1)
        else:
            start = reference_time.replace(year=reference_time.year - amount)
        return ResolvedTime(start, None, unit)

    raise TimeResolutionError(f"unsupported time expression: {expression!r}")
