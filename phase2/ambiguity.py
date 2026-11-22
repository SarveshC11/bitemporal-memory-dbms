from __future__ import annotations

import json
from dataclasses import dataclass
from typing import Any, Mapping

AMBIGUITY_PROMPT = """Resolve only this ambiguous memory decision.
Return JSON exactly as:
{"decision":"replace|add|reject","predicate":"controlled_predicate_or_empty",
"reason":"short explanation"}
Use "replace" when the new statement supersedes the current single-valued
fact, "add" only when both values can be true simultaneously, and "reject"
when the statement is not a fact. Do not invent facts."""


class AmbiguityResolutionError(ValueError):
    """Raised when an ambiguity resolver returns an unsafe decision."""


@dataclass(frozen=True)
class AmbiguityDecision:
    decision: str
    reason: str
    predicate: str | None = None


def parse_ambiguity_decision(value: Any) -> AmbiguityDecision:
    if isinstance(value, str):
        try:
            value = json.loads(value)
        except json.JSONDecodeError as exc:
            raise AmbiguityResolutionError("ambiguity resolver returned invalid JSON") from exc
    if not isinstance(value, Mapping):
        raise AmbiguityResolutionError("ambiguity resolver must return an object")
    decision = value.get("decision")
    reason = value.get("reason")
    predicate = value.get("predicate")
    if decision not in {"replace", "add", "reject"} or not isinstance(reason, str) or not reason.strip():
        raise AmbiguityResolutionError("ambiguity decision must contain a valid decision and reason")
    if predicate is not None and not isinstance(predicate, str):
        raise AmbiguityResolutionError("ambiguity predicate must be a string")
    return AmbiguityDecision(decision, reason.strip(), predicate)
