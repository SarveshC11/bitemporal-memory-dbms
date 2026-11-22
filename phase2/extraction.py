from __future__ import annotations

import json
from datetime import datetime
from typing import Any, Callable, Iterable, Mapping, Optional

from .models import ExtractedFact
from .ambiguity import AmbiguityDecision, parse_ambiguity_decision
from .normalization import EntityResolver, normalize_predicate
from .time_resolution import resolve_time_expression

EXTRACTION_PROMPT = """Extract only facts explicitly stated in the conversation.
Return JSON matching this shape exactly:
{"facts":[{"subject":"string","predicate":"string","object":"string",
"confidence":0.0,"time_expression":"string"}]}
Use only these predicates: {predicates}.
Use the conversation timestamp as the reference for relative time expressions.
Do not infer unstated facts. Use an empty time_expression when the fact starts at
the conversation timestamp."""


class ExtractionError(ValueError):
    """Raised when structured extraction output is invalid."""


def _payload(value: Any) -> Mapping[str, Any]:
    if isinstance(value, str):
        try:
            value = json.loads(value)
        except json.JSONDecodeError as exc:
            raise ExtractionError("extractor did not return valid JSON") from exc
    if not isinstance(value, Mapping) or not isinstance(value.get("facts"), list):
        raise ExtractionError("extractor output must be an object with a facts array")
    return value


class ExtractionPipeline:
    def __init__(
        self,
        allowed_predicates: Iterable[str],
        extractor: Callable[[str], Any],
        entity_resolver: Optional[EntityResolver] = None,
        ambiguity_resolver: Optional[Callable[[Mapping[str, Any]], Any]] = None,
    ) -> None:
        self._allowed = set(allowed_predicates)
        self._extractor = extractor
        self._entities = entity_resolver or EntityResolver()
        self._ambiguity_resolver = ambiguity_resolver

    def extract(self, conversation: str, reference_time: datetime) -> list[ExtractedFact]:
        data = _payload(self._extractor(conversation))
        facts: list[ExtractedFact] = []
        for index, raw in enumerate(data["facts"]):
            if not isinstance(raw, Mapping):
                raise ExtractionError(f"fact {index} must be an object")
            required = {"subject", "predicate", "object", "confidence", "time_expression"}
            missing = required - raw.keys()
            if missing:
                raise ExtractionError(f"fact {index} missing fields: {sorted(missing)}")
            confidence = raw["confidence"]
            if not isinstance(confidence, (int, float)) or not 0 <= confidence <= 1:
                raise ExtractionError(f"fact {index} confidence must be between 0 and 1")
            try:
                predicate = normalize_predicate(str(raw["predicate"]), self._allowed)
            except ValueError:
                if self._ambiguity_resolver is None:
                    raise
                decision = parse_ambiguity_decision(self._ambiguity_resolver({
                    "conversation": conversation,
                    "fact": dict(raw),
                    "allowed_predicates": sorted(self._allowed),
                }))
                if decision.decision == "reject":
                    continue
                if not decision.predicate:
                    raise ValueError("ambiguity resolver must provide a predicate")
                predicate = normalize_predicate(decision.predicate, self._allowed)
            resolved_time = resolve_time_expression(str(raw["time_expression"]), reference_time)
            facts.append(
                ExtractedFact(
                    subject=self._entities.resolve(str(raw["subject"])),
                    predicate=predicate,
                    object=str(raw["object"]).strip(),
                    confidence=float(confidence),
                    valid_from=resolved_time.start,
                    valid_until=resolved_time.end,
                    time_precision=resolved_time.precision,
                )
            )
        return facts
