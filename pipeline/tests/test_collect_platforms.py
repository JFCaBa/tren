import json
import sys
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from collect_platforms import MAX_OBS, merge, observations, parse_label, train_number, valid_state  # noqa: E402

FIXTURES = Path(__file__).parent / "fixtures"
VP = json.loads((FIXTURES / "vehicle_positions.json").read_text())
VP_TIME = datetime.fromtimestamp(int(VP["header"]["timestamp"]), timezone.utc)


def empty():
    return {"version": 1, "updated": "", "obs": {}}


class ParseTest(unittest.TestCase):
    def test_parse_label(self):
        self.assertEqual(parse_label("C1-23525-PLATF.(6)"), ("C1", "23525", "6"))
        self.assertEqual(parse_label("C4-23615"), ("C4", "23615", None))
        self.assertEqual(parse_label("C2-35905-PLATF.(2AM)")[2], "2AM")
        self.assertIsNone(parse_label("C1-23525-PLATF.()")[2])
        self.assertIsNone(parse_label("C1-23525-PLATF.(  )")[2])
        self.assertIsNone(parse_label(""))
        self.assertIsNone(parse_label("garbage"))
        self.assertIsNone(parse_label("C1-23525-PLATF.(6"))

    def test_train_number(self):
        self.assertEqual(train_number("3019L23525C1"), "23525")
        self.assertIsNone(train_number("SPECIAL_10_91217C3"))
        self.assertIsNone(train_number("weird"))


class ObservationsTest(unittest.TestCase):
    def test_observations_filters_status_and_stop(self):
        self.assertEqual(
            observations(VP, VP_TIME),
            [("51200|23525", "6"), ("18000|35905", "2AM")],
        )

    def test_observations_rejects_stale_header(self):
        self.assertEqual(observations(VP, VP_TIME + timedelta(minutes=20)), [])

    def test_observations_skips_stale_vehicle(self):
        vp = json.loads(json.dumps(VP))
        vp["entity"][0]["vehicle"]["timestamp"] = str(int(VP["header"]["timestamp"]) - 3600)
        self.assertEqual(observations(vp, VP_TIME), [("18000|35905", "2AM")])

    def test_observations_accepts_naive_utc_now(self):
        self.assertEqual(len(observations(VP, VP_TIME.replace(tzinfo=None))), 2)

    def test_observations_tolerates_missing_fields(self):
        vp = {"header": VP["header"], "entity": [{}, {"vehicle": {}}, {"vehicle": {"trip": {}, "vehicle": {}}}]}
        self.assertEqual(observations(vp, VP_TIME), [])
        self.assertEqual(observations({}, VP_TIME), [])


class MergeTest(unittest.TestCase):
    def test_merge_dedups_same_day(self):
        s = merge(empty(), [("a|1", "2")], "2026-11-16")
        s = merge(s, [("a|1", "2")], "2026-11-16")
        self.assertEqual(s["obs"]["a|1"], [["2", "2026-11-16"]])
        s = merge(s, [("a|1", "3")], "2026-11-16")
        self.assertEqual(s["obs"]["a|1"], [["3", "2026-11-16"]])

    def test_merge_keeps_last_10(self):
        s = empty()
        start = datetime(2026, 11, 1)
        for i in range(12):
            s = merge(s, [("a|1", str(i))], (start + timedelta(days=i)).date().isoformat())
        self.assertEqual(len(s["obs"]["a|1"]), MAX_OBS)
        self.assertEqual(s["obs"]["a|1"][0], ["2", "2026-11-03"])
        self.assertEqual(s["obs"]["a|1"][-1], ["11", "2026-11-12"])

    def test_merge_prunes_45_days(self):
        s = {"version": 1, "updated": "", "obs": {
            "old|1": [["2", "2026-10-01"]],   # 46 days before 2026-11-16
            "ok|1": [["2", "2026-10-03"]],    # 44 days
        }}
        s = merge(s, [], "2026-11-16")
        self.assertNotIn("old|1", s["obs"])
        self.assertIn("ok|1", s["obs"])
        self.assertRegex(s["updated"], r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$")

    def test_merge_drops_old_items_in_live_key(self):
        s = {"version": 1, "updated": "", "obs": {"a|1": [["2", "2026-11-10"], ["9", "2026-08-01"]]}}
        s = merge(s, [("a|1", "2")], "2026-11-16")
        self.assertEqual(s["obs"]["a|1"], [["2", "2026-11-10"], ["2", "2026-11-16"]])

    def test_valid_state(self):
        self.assertFalse(valid_state({"version": 1, "obs": {"k": None}}))
        self.assertFalse(valid_state({"version": 1, "obs": {"k": [["2"]]}}))
        self.assertFalse(valid_state({"obs": []}))
        self.assertFalse(valid_state({"version": 1, "obs": {"k": [["2", "16-11-2026"]]}}))
        self.assertFalse(valid_state("x"))
        self.assertTrue(valid_state({"version": 1, "updated": "x", "obs": {"k": [["2", "2026-11-16"]]}}))


if __name__ == "__main__":
    unittest.main()
