from __future__ import annotations

import json
import os
import re
from datetime import datetime
from typing import Any, Mapping
from urllib import request

from phase2.ambiguity import AMBIGUITY_PROMPT
from phase2.extraction import EXTRACTION_PROMPT


class LLMConfigurationError(RuntimeError):
    """Raised when the configured LLM cannot be called."""


class OpenAICompatibleClient:
    def __init__(self) -> None:
        self.base_url = os.getenv("LLM_BASE_URL", "https://api.openai.com/v1").rstrip("/")
        self.api_key = os.getenv("LLM_API_KEY", "")
        self.model = os.getenv("LLM_MODEL", "gpt-4o-mini")

    @property
    def enabled(self) -> bool:
        return bool(self.api_key)

    def _complete(self, system: str, user: str) -> Any:
        if not self.enabled:
            raise LLMConfigurationError("LLM_API_KEY is not configured")
        payload = json.dumps({
            "model": self.model,
            "temperature": 0,
            "messages": [
                {"role": "system", "content": system},
                {"role": "user", "content": user},
            ],
            "response_format": {"type": "json_object"},
        }).encode()
        http_request = request.Request(
            f"{self.base_url}/chat/completions",
            data=payload,
            headers={
                "Authorization": f"Bearer {self.api_key}",
                "Content-Type": "application/json",
            },
            method="POST",
        )
        try:
            with request.urlopen(http_request, timeout=45) as response:
                body = json.loads(response.read())
        except Exception as exc:
            raise LLMConfigurationError(f"LLM request failed: {exc}") from exc
        try:
            return json.loads(body["choices"][0]["message"]["content"])
        except (KeyError, IndexError, TypeError, json.JSONDecodeError) as exc:
            raise LLMConfigurationError("LLM response did not contain valid JSON content") from exc

    def extract(self, conversation: str, predicates: list[str], subject: str) -> Any:
        system = EXTRACTION_PROMPT.format(predicates=", ".join(predicates))
        return self._complete(system, f"The speaker is {subject}.\n{conversation}")

    def resolve_ambiguity(self, context: Mapping[str, Any]) -> Any:
        return self._complete(AMBIGUITY_PROMPT, json.dumps(dict(context), default=str))


def demo_extract(conversation: str, subject: str, reference_time: datetime) -> dict[str, list[dict[str, Any]]]:
    """Small deterministic fallback so the UI is usable without an LLM key."""
    facts: list[dict[str, Any]] = []
    patterns = [
        (
            r"\b(?:work(?:s|ing)?|joined)\b(?:\s+(?:at|for|with))?\s+"
            r"([A-Za-z0-9][A-Za-z0-9 .&'-]*?)"
            r"(?=(?:\s+(?:last|this|previous|next|since)\b)|[.,]|$)",
            "works_at",
        ),
        (
            r"\b(?:live|lives|living|based|reside(?:s|d)?|stay(?:s|ed)?|based)\b"
            r"(?:\s+in|\s+at)?\s+([A-Za-z][A-Za-z .'-]*?)"
            r"(?=[.,]|$)",
            "lives_in",
        ),
        (
            r"\b(?:my\s+)?(?:favorite|favourite)\s+food\s+(?:is|was)\s+"
            r"([A-Za-z][A-Za-z .'-]*?)"
            r"(?=[.,]|$)",
            "favourite_food",
        ),
        (
            r"\b(?:i\s+)?like(?:s)?\s+([A-Za-z][A-Za-z .'-]*?)"
            r"(?=[.,]|$)",
            "likes",
        ),
        (
            r"\b(?:role\s+(?:is|was)|as\s+a|am\s+a)\s+"
            r"([A-Za-z][A-Za-z .'-]*?)"
            r"(?=[.,]|$)",
            "has_role",
        ),
    ]
    for pattern, predicate in patterns:
        for match in re.finditer(pattern, conversation, re.IGNORECASE):
            object_value = match.group(1).strip(" ,.")
            if not object_value:
                continue
            time_expression = ""
            if predicate == "works_at":
                since_match = re.search(
                    r"\bsince\s+(?P<expression>(?:\d{1,2}\s+)?[A-Za-z]+\s+\d{4}|"
                    r"[A-Za-z]+\s+\d{4}|\d{4}-\d{2}-\d{2}|\d{4})",
                    conversation,
                    re.IGNORECASE,
                )
                if since_match:
                    time_expression = "since " + since_match.group("expression")
                else:
                    relative_match = re.search(
                        r"\b(last\s+(?:week|month|year)|yesterday|today)\b",
                        object_value,
                    )
                    if relative_match:
                        time_expression = relative_match.group(1)
                    elif re.search(r"\blast\s+(?:week|month|year)\b", conversation, re.IGNORECASE):
                        time_expression = re.search(
                            r"\b(last\s+(?:week|month|year))\b",
                            conversation,
                            re.IGNORECASE,
                        ).group(1)
            facts.append({
                "subject": subject,
                "predicate": predicate,
                "object": object_value,
                "confidence": 0.75,
                "time_expression": time_expression,
            })
    return {"facts": facts}
