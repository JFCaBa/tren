import sys
import unittest
from datetime import date
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from build_feed import NUCLEO_NAMES, build_index, build_nucleos  # noqa: E402

MULTI = Path(__file__).parent / "fixtures" / "multi"
TODAY = date(2026, 11, 15)


class NucleosTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.feeds = build_nucleos(MULTI, TODAY)
        cls.index = build_index(cls.feeds)

    def test_names_cover_all_nucleos(self):
        self.assertEqual(15, len(NUCLEO_NAMES))
        self.assertEqual("Rodalies de Catalunya", NUCLEO_NAMES["51"])

    def test_one_feed_per_nucleo(self):
        self.assertEqual({"10", "47", "60"}, set(self.feeds))
        self.assertEqual(["M1"], [t["id"] for t in self.feeds["10"]["trips"]])
        self.assertEqual({"C4a": "0070C0"}, self.feeds["10"]["lines"])

    def test_trip_schema_v2(self):
        f = self.feeds["10"]
        self.assertEqual(2, f["version"])
        self.assertEqual("Madrid", f["name"])
        self.assertEqual("10", f["nucleo"])
        self.assertEqual("2026-11-14", f["valid_from"])
        self.assertEqual("2026-11-22", f["valid_to"])
        t = f["trips"][0]
        self.assertEqual("Parla", t["dest"])
        self.assertEqual("C4a", t["line"])
        self.assertNotIn("dir", t)
        self.assertEqual([["18000", 28800], ["18002", 30600]], t["times"])
        self.assertEqual(9, len(t["dates"]))

    def test_bus_route_type_excluded(self):
        self.assertNotIn("MBUS", [t["id"] for t in self.feeds["10"]["trips"]])
        self.assertNotIn("C9", self.feeds["10"]["lines"])

    def test_line_color_prefers_valid_variant(self):
        self.assertEqual({"C1": "E30613"}, self.feeds["60"]["lines"])
        self.assertEqual({"B1", "B2"}, {t["id"] for t in self.feeds["60"]["trips"]})

    def test_invalid_route_color_defaults_to_grey(self):
        self.assertEqual({"C1": "9E9E9E"}, self.feeds["47"]["lines"])

    def test_feed_stops_only_used(self):
        self.assertEqual({"18000", "18002"}, {s["id"] for s in self.feeds["10"]["stops"]})

    def test_shared_stop_lists_both_nucleos(self):
        cist = [s for s in self.index["stops"] if s["id"] == "05761"]
        self.assertEqual(1, len(cist))
        self.assertEqual(["47", "60"], cist[0]["nucleos"])

    def test_index_lists_nucleos_with_feed_paths(self):
        self.assertIn({"id": "10", "name": "Madrid", "feed": "feeds/10.json"}, self.index["nucleos"])
        self.assertEqual(2, self.index["version"])
        self.assertEqual(5, len(self.index["stops"]))


if __name__ == "__main__":
    unittest.main()
