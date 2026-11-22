from __future__ import annotations

from difflib import SequenceMatcher
from typing import Callable, Mapping, Optional

PREDICATE_ALIASES = {
    "based in": "lives_in",
    "city": "lives_in",
    "current city": "lives_in",
    "employer": "works_at",
    "job": "has_role",
    "job title": "has_role",
    "favourite food": "favourite_food",
    "favorite food": "favourite_food",
    "enjoys": "likes",
    "likes": "likes",
    "speaks": "speaks",
    "skills": "skilled_in",
    "skilled in": "skilled_in",
}


class NormalizationError(ValueError):
    """Raised when a value cannot be normalized unambiguously."""


def normalize_predicate(value: str, allowed: set[str]) -> str:
    key = " ".join(value.strip().lower().replace("-", " ").split())
    normalized = PREDICATE_ALIASES.get(key, key)
    if normalized not in allowed:
        raise NormalizationError(f"unknown predicate: {value!r}")
    return normalized


class EntityResolver:
    def __init__(
        self,
        aliases: Optional[Mapping[str, str]] = None,
        fallback: Optional[Callable[[str], Optional[str]]] = None,
        threshold: float = 0.88,
    ) -> None:
        self._aliases = {self._key(alias): canonical for alias, canonical in (aliases or {}).items()}
        self._fallback = fallback
        self._threshold = threshold

    @staticmethod
    def _key(value: str) -> str:
        return " ".join(value.strip().lower().split())

    def resolve(self, value: str) -> str:
        key = self._key(value)
        if not key:
            raise NormalizationError("entity name cannot be empty")
        if key in self._aliases:
            return self._aliases[key]

        candidates = [
            (SequenceMatcher(None, key, alias).ratio(), canonical)
            for alias, canonical in self._aliases.items()
        ]
        if candidates:
            best_score, best_name = max(candidates)
            tied = [name for score, name in candidates if score == best_score]
            if best_score >= self._threshold and len(set(tied)) == 1:
                return best_name

        if self._fallback:
            resolved = self._fallback(value)
            if resolved:
                return resolved
        return value.strip()

