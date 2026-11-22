import unittest
from datetime import datetime

from app.llm import demo_extract

from phase2.ambiguity import AmbiguityResolutionError
from phase2.extraction import ExtractionError, ExtractionPipeline
from phase2.normalization import EntityResolver, NormalizationError, normalize_predicate
from phase2.time_resolution import resolve_time_expression


class TimeResolutionTests(unittest.TestCase):
    reference = datetime(2026, 3, 10, 10, 0)

    def test_relative_month_uses_reference_time(self):
        result = resolve_time_expression("last month", self.reference)
        self.assertEqual(result.start, datetime(2026, 2, 1))
        self.assertEqual(result.end, datetime(2026, 3, 1))

    def test_month_without_year_uses_previous_occurrence(self):
        result = resolve_time_expression("August", self.reference)
        self.assertEqual(result.start, datetime(2025, 8, 1))

    def test_month_last_year_is_resolved(self):
        result = resolve_time_expression("June last year", self.reference)
        self.assertEqual(result.start, datetime(2025, 6, 1))

    def test_unknown_expression_is_not_silently_guessed(self):
        with self.assertRaises(ValueError):
            resolve_time_expression("sometime before college", self.reference)


class NormalizationTests(unittest.TestCase):
    def test_predicate_alias(self):
        self.assertEqual(normalize_predicate("based in", {"lives_in"}), "lives_in")

    def test_unknown_predicate_is_rejected(self):
        with self.assertRaises(NormalizationError):
            normalize_predicate("is married to", {"works_at"})

    def test_entity_alias_and_fuzzy_match(self):
        resolver = EntityResolver({"Blr": "Bengaluru"})
        self.assertEqual(resolver.resolve("blr"), "Bengaluru")
        self.assertEqual(resolver.resolve("Bengaluru"), "Bengaluru")


class ExtractionTests(unittest.TestCase):
    def test_demo_extract_handles_joined_company_without_at(self):
        result = demo_extract(
            "I joined xyz company last week.",
            "Priya",
            datetime(2026, 11, 21),
        )
        facts = {fact["predicate"]: fact for fact in result["facts"]}
        self.assertEqual(facts["works_at"]["object"], "xyz company")
        self.assertEqual(facts["works_at"]["time_expression"], "last week")

    def test_demo_extract_handles_multiple_supported_statements(self):
        result = demo_extract(
            "I live in Mysuru. I work at TCS since July 2024. "
            "My favourite food is dosa. I like cricket.",
            "Priya",
            datetime(2026, 11, 21),
        )
        facts = {fact["predicate"]: fact for fact in result["facts"]}
        self.assertEqual(facts["lives_in"]["object"], "Mysuru")
        self.assertEqual(facts["works_at"]["object"], "TCS")
        self.assertEqual(facts["works_at"]["time_expression"], "since July 2024")
        self.assertEqual(facts["favourite_food"]["object"], "dosa")
        self.assertEqual(facts["likes"]["object"], "cricket")

    def test_structured_extraction_is_normalized(self):
        response = {
            "facts": [
                {
                    "subject": "Priya",
                    "predicate": "employer",
                    "object": "Zeta Labs",
                    "confidence": 0.9,
                    "time_expression": "last week",
                }
            ]
        }
        pipeline = ExtractionPipeline({"works_at"}, lambda _: response)
        facts = pipeline.extract("I joined Zeta Labs last week.", datetime(2026, 8, 20))
        self.assertEqual(facts[0].predicate, "works_at")
        self.assertEqual(facts[0].valid_from, datetime(2026, 8, 10))

    def test_invalid_json_fails_loudly(self):
        pipeline = ExtractionPipeline({"works_at"}, lambda _: "not json")
        with self.assertRaises(ExtractionError):
            pipeline.extract("broken", datetime(2026, 8, 20))

    def test_ambiguity_resolver_can_reject_unknown_fact(self):
        response = {"facts": [{
            "subject": "Priya", "predicate": "works somewhere", "object": "X",
            "confidence": 0.5, "time_expression": "",
        }]}
        pipeline = ExtractionPipeline({"works_at"}, lambda _: response,
                                      ambiguity_resolver=lambda _: {
                                          "decision": "reject", "predicate": "",
                                          "reason": "not explicit"
                                      })
        self.assertEqual(pipeline.extract("unclear", datetime(2026, 8, 20)), [])

    def test_invalid_ambiguity_decision_fails_loudly(self):
        response = {"facts": [{
            "subject": "Priya", "predicate": "works somewhere", "object": "X",
            "confidence": 0.5, "time_expression": "",
        }]}
        pipeline = ExtractionPipeline({"works_at"}, lambda _: response,
                                      ambiguity_resolver=lambda _: {
                                          "decision": "maybe", "predicate": "works_at",
                                          "reason": "invalid"
                                      })
        with self.assertRaises(AmbiguityResolutionError):
            pipeline.extract("unclear", datetime(2026, 8, 20))


if __name__ == "__main__":
    unittest.main()
