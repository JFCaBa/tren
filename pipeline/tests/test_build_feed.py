import sys
import unittest
from datetime import date
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from build_feed import build_feed  # noqa: E402

MINI = Path(__file__).parent / "fixtures" / "mini"
TODAY = date(2026, 11, 15)


def trips_by_id(feed):
    return {t["id"]: t for t in feed["trips"]}


class BuildFeedTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.feed = build_feed(MINI, TODAY, days=7)
        cls.trips = trips_by_id(cls.feed)

    def test_filters_only_valencia_c1_c2(self):
        self.assertNotIn("T_MAD", self.trips)
        self.assertNotIn("T_C3", self.trips)
        self.assertEqual({"T_OUT", "T_IN", "T_C2S", "T_NIGHT", "T_GAP"}, set(self.trips))

    def test_direction_and_dest(self):
        self.assertEqual("out", self.trips["T_OUT"]["dir"])
        self.assertEqual("Gandia", self.trips["T_OUT"]["dest"])
        self.assertEqual("in", self.trips["T_IN"]["dir"])
        self.assertEqual("Silla", self.trips["T_C2S"]["dest"])
        self.assertEqual("C2", self.trips["T_C2S"]["line"])

    def test_times_seconds_past_24h(self):
        self.assertEqual(["64200", 88200], self.trips["T_NIGHT"]["times"][1])
        self.assertEqual([["65000", 67200], ["64200", 68100], ["69110", 70800]],
                         self.trips["T_OUT"]["times"])

    def test_dates_within_window(self):
        self.assertEqual("2026-11-14", self.feed["valid_from"])
        self.assertEqual("2026-11-22", self.feed["valid_to"])
        self.assertEqual(["2026-11-15"], self.trips["T_OUT"]["dates"])
        week = self.trips["T_IN"]["dates"]
        self.assertEqual(9, len(week))
        self.assertEqual("2026-11-14", week[0])
        self.assertEqual("2026-11-22", week[-1])

    def test_fields_are_stripped(self):
        for t in self.feed["trips"]:
            self.assertEqual(t["id"], t["id"].strip())
            self.assertEqual(t["dest"], t["dest"].strip())
            for stop_id, _ in t["times"]:
                self.assertEqual(stop_id, stop_id.strip())
        for s in self.feed["stops"]:
            self.assertEqual(s["id"], s["id"].strip())
            self.assertEqual(s["name"], s["name"].strip())

    def test_drops_trips_beyond_48h(self):
        self.assertNotIn("T_48", self.trips)

    def test_skips_stops_without_time(self):
        self.assertEqual([["65000", 32400], ["69110", 34800]], self.trips["T_GAP"]["times"])

    def test_drops_trips_with_unknown_stop(self):
        self.assertNotIn("T_BADSTOP", self.trips)

    def test_stops_only_used_with_lines(self):
        stops = {s["id"]: s for s in self.feed["stops"]}
        self.assertEqual({"65000", "64200", "69110", "64203"}, set(stops))
        self.assertEqual(["C1", "C2"], stops["64200"]["lines"])
        self.assertEqual(["C1"], stops["65000"]["lines"])
        self.assertAlmostEqual(39.3619548, stops["64200"]["lat"])


if __name__ == "__main__":
    unittest.main()
