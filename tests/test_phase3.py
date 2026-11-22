import unittest
from datetime import datetime

from phase2.query import execute_query

from phase2.query import QueryRoutingError, route_query


class QueryRoutingTests(unittest.TestCase):
    def test_current_query_is_default(self):
        self.assertEqual(route_query("Where does Priya work?").kind, "current")

    def test_valid_date_routes_to_as_of(self):
        route = route_query("Where did Priya work on 2026-08-10?")
        self.assertEqual(route.kind, "as_of")
        self.assertEqual(route.valid_at, datetime(2026, 8, 10))
        self.assertEqual(route.believed_at, datetime(2026, 8, 10))

    def test_past_belief_requires_two_dates(self):
        route = route_query("What did the system believe on 2026-08-25 about 2026-08-10?")
        self.assertEqual(route.believed_at, datetime(2026, 8, 25))
        self.assertEqual(route.valid_at, datetime(2026, 8, 10))

    def test_ambiguous_past_belief_fails_loudly(self):
        with self.assertRaises(QueryRoutingError):
            route_query("What did the system believe about Priya?")

    def test_year_routes_to_valid_year_snapshot(self):
        route = route_query("Where did Priya work in 2025?")
        self.assertEqual(route.kind, "as_of")
        self.assertEqual(route.subject, "Priya")
        self.assertEqual(route.predicate, "works_at")
        self.assertEqual(route.valid_at, datetime(2025, 1, 1))

    def test_month_past_belief_routes_with_two_time_bounds(self):
        route = route_query("What did I believe in March?", datetime(2026, 8, 20))
        self.assertEqual(route.kind, "as_of")
        self.assertEqual(route.valid_at, datetime(2026, 3, 1))
        self.assertEqual(route.believed_at, datetime(2026, 4, 1))

    def test_fact_change_routes_to_history(self):
        route = route_query("When did Priya's employer change?")
        self.assertEqual(route.kind, "history")
        self.assertEqual(route.subject, "Priya")

    def test_basic_current_preference_query(self):
        route = route_query("What does Priya like?")
        self.assertEqual(route.kind, "current")
        self.assertEqual(route.subject, "Priya")
        self.assertEqual(route.predicate, "likes")

    def test_basic_current_food_query(self):
        route = route_query("What is Priya's favourite food?")
        self.assertEqual(route.kind, "current")
        self.assertEqual(route.subject, "Priya")
        self.assertEqual(route.predicate, "favourite_food")

    def test_basic_residence_and_employment_queries(self):
        residence = route_query("Where does Priya live?")
        employment = route_query("Where does Priya work?")
        self.assertEqual(residence.subject, "Priya")
        self.assertEqual(residence.predicate, "lives_in")
        self.assertEqual(employment.subject, "Priya")
        self.assertEqual(employment.predicate, "works_at")


if __name__ == "__main__":
    unittest.main()
