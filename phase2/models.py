from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime
from typing import Optional


@dataclass(frozen=True)
class ResolvedTime:
    start: datetime
    end: Optional[datetime]
    precision: str


@dataclass(frozen=True)
class ExtractedFact:
    subject: str
    predicate: str
    object: str
    confidence: float
    valid_from: datetime
    valid_until: Optional[datetime]
    time_precision: str

