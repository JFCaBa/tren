import json
import sys
import tempfile
import unittest
from datetime import date
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import build_feed  # noqa: E402
from build_feed import attach_platforms, load_platforms, usual  # noqa: E402

TODAY = date(2026, 11, 16)


def trip(trip_id, line, dest, stops):
    return {"id": trip_id, "line": line, "dest": dest, "dates": ["2026-11-16"],
            "times": [[s, 3600 * (i + 6)] for i, s in enumerate(stops)]}


def feeds_with(*trips):
    return {"30": {"version": 2, "nucleo": "30", "trips": list(trips)}}


def state(obs):
    return {"version": 1, "updated": "2026-11-16T08:00:00Z", "obs": obs}


TWO_DAYS = [["6", "2026-11-14"], ["6", "2026-11-15"]]


class UsualTest(unittest.TestCase):
    def test_usual_threshold(self):
        self.assertEqual(usual([["2", "d1"], ["2", "d2"], ["3", "d3"]]), "2")
        self.assertIsNone(usual([["2", "d1"]]))
        self.assertIsNone(usual([["2", "d1"], ["2", "d1"]]))  # one day only
        self.assertIsNone(usual([["2", "d1"], ["3", "d2"]]))
        self.assertIsNone(usual([["2", "d1"], ["2", "d2"], ["3", "d3"], ["3", "d4"]]))
        self.assertIsNone(usual([]))


class AttachTest(unittest.TestCase):
    def test_attach_by_train(self):
        feeds = feeds_with(trip("3019L23525C1", "C1", "Utrera", ["51200", "51003"]))
        attach_platforms(feeds, state({"51200|23525": TWO_DAYS}))
        self.assertEqual(feeds["30"]["platforms"], {"51200": {"23525": "6"}})
        self.assertEqual(feeds["30"]["version"], 2)

    def test_attach_fallback_line_dest(self):
        feeds = feeds_with(
            trip("3019L23525C1", "C1", "Utrera", ["51200", "51003"]),
            trip("3019L23527C1", "C1", "Utrera", ["51200", "51003"]),
            trip("3019L23529C1", "C1", "Utrera", ["51200", "51003"]),
        )
        attach_platforms(feeds, state({"51200|23525": TWO_DAYS, "51200|23529": TWO_DAYS}))
        self.assertEqual(feeds["30"]["platforms"]["51200"]["23527"], "6")

    def test_attach_ignores_other_stations_and_feeds(self):
        feeds = feeds_with(trip("3019L23525C1", "C1", "Utrera", ["51200", "51003"]))
        attach_platforms(feeds, state({"99999|23525": TWO_DAYS, "51200|11111": TWO_DAYS}))
        self.assertEqual(feeds["30"].get("platforms", {}), {})

    def test_attach_none_state(self):
        feeds = feeds_with(trip("3019L23525C1", "C1", "Utrera", ["51200", "51003"]))
        attach_platforms(feeds, None)
        self.assertNotIn("platforms", feeds["30"])
        self.assertEqual(feeds["30"]["version"], 2)

    def test_fallback_skips_ambiguous_train(self):
        feeds = feeds_with(
            trip("3019L23525C1", "C1", "Utrera", ["51200", "51003"]),
            trip("3019L23529C1", "C1", "Utrera", ["51200", "51003"]),
            trip("3019L23527C1", "C1", "Utrera", ["51200", "51003"]),
            trip("4019L23527C1", "C1", "Lora del Río", ["51200", "51100"]),  # same number, other route
        )
        attach_platforms(feeds, state({"51200|23525": TWO_DAYS, "51200|23529": TWO_DAYS}))
        self.assertNotIn("23527", feeds["30"]["platforms"]["51200"])


class LoadTest(unittest.TestCase):
    def write(self, text):
        p = Path(tempfile.mkdtemp()) / "platforms.json"
        p.write_text(text)
        return str(p)

    def test_load_platforms_invalid(self):
        for text in ["{", '{"obs": []}', '{"version":1,"obs":{"k":null}}']:
            self.assertIsNone(load_platforms(self.write(text), TODAY), text)
        self.assertIsNone(load_platforms(None, TODAY))
        self.assertIsNone(load_platforms("/nonexistent/platforms.json", TODAY))

    def test_load_platforms_expires(self):
        s = load_platforms(self.write(json.dumps(state({"a|1": [["2", "2026-10-01"]],
                                                         "b|1": [["2", "2026-11-10"]]}))), TODAY)
        self.assertEqual(set(s["obs"]), {"b|1"})

    def test_load_platforms_expires_items_inside_live_key(self):
        old = [["2", f"2026-09-{d:02d}"] for d in range(1, 10)]
        s = load_platforms(self.write(json.dumps(state({"a|1": old + [["6", "2026-11-15"]]}))), TODAY)
        self.assertEqual(s["obs"]["a|1"], [["6", "2026-11-15"]])


class MainTest(unittest.TestCase):
    def test_main_survives_attach_error(self):
        import zipfile

        tmp = Path(tempfile.mkdtemp())
        with zipfile.ZipFile(tmp / "gtfs.zip", "w") as z:
            for f in (Path(__file__).parent / "fixtures" / "multi").iterdir():
                z.write(f, f.name)
        (tmp / "noprev").mkdir()
        plat = tmp / "platforms.json"
        plat.write_text(json.dumps(state({"x|12345": TWO_DAYS})))
        with mock.patch.object(build_feed, "attach_platforms", side_effect=RuntimeError("boom")):
            code = build_feed.main(["--out", str(tmp / "out"), "--zip", str(tmp / "gtfs.zip"),
                                    "--date", "2026-11-15", "--previous-base", (tmp / "noprev").as_uri(),
                                    "--platforms", str(plat)])
        self.assertEqual(code, 0)
        feed = json.loads((tmp / "out" / "feeds" / "10.json").read_text())
        self.assertNotIn("platforms", feed)


if __name__ == "__main__":
    unittest.main()
