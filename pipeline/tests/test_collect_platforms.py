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


class MainTest(unittest.TestCase):
    """main() against a local HTTP server serving the fixture with a fresh header."""

    @classmethod
    def setUpClass(cls):
        import http.server
        import threading
        import time

        body = json.loads(json.dumps(VP))
        now = int(time.time())
        body["header"]["timestamp"] = str(now)
        for e in body["entity"]:
            e["vehicle"]["timestamp"] = str(now)
        payload = json.dumps(body).encode()

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                self.send_response(200)
                self.end_headers()
                self.wfile.write(payload)

            def log_message(self, *a):
                pass

        cls.server = http.server.HTTPServer(("127.0.0.1", 0), Handler)
        threading.Thread(target=cls.server.serve_forever, daemon=True).start()
        cls.url = f"http://127.0.0.1:{cls.server.server_port}/vp.json"

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()

    def setUp(self):
        import tempfile

        self.tmp = Path(tempfile.mkdtemp())
        self.state = self.tmp / "platforms.json"

    def run_main(self, url=None, today="2026-11-16"):
        from collect_platforms import main

        return main(["--state", str(self.state), "--url", url or self.url, "--today", today])

    def test_main_writes_state(self):
        self.assertEqual(self.run_main(), 0)
        d = json.loads(self.state.read_text())
        self.assertTrue(valid_state(d))
        self.assertEqual(set(d["obs"]), {"51200|23525", "18000|35905"})

    def test_main_download_failure_keeps_state(self):
        self.state.write_text('{"version": 1, "updated": "x", "obs": {}}')
        self.assertEqual(self.run_main(url="http://127.0.0.1:9/none"), 0)
        self.assertEqual(self.state.read_text(), '{"version": 1, "updated": "x", "obs": {}}')

    def test_main_corrupt_state_aborts(self):
        self.state.write_text("{")
        self.assertEqual(self.run_main(), 1)
        self.assertEqual(self.state.read_text(), "{")

    def test_main_refuses_to_shrink_by_half(self):
        obs = {f"s{i}|1234{i}": [["1", "2026-11-15"]] for i in range(10)}
        # all of them older than 45 days -> pruned -> the result would lose them all
        old = {k: [["1", "2026-09-01"]] for k in obs}
        prev = json.dumps({"version": 1, "updated": "2026-11-15T10:00:00Z", "obs": old})
        self.state.write_text(prev)
        self.assertEqual(self.run_main(), 1)
        self.assertEqual(self.state.read_text(), prev)

    def test_main_shrink_allowed_after_long_stop(self):
        old = {f"s{i}|1234{i}": [["1", "2026-09-01"]] for i in range(10)}
        self.state.write_text(json.dumps({"version": 1, "updated": "2026-10-01T10:00:00Z", "obs": old}))
        self.assertEqual(self.run_main(), 0)
        self.assertEqual(set(json.loads(self.state.read_text())["obs"]), {"51200|23525", "18000|35905"})

    def test_main_no_write_without_changes(self):
        self.assertEqual(self.run_main(), 0)
        d = json.loads(self.state.read_text())
        d["updated"] = "2026-11-16T06:00:00Z"  # sentinel: a rewrite would replace it
        self.state.write_text(json.dumps(d))
        first = self.state.read_text()
        self.assertEqual(self.run_main(), 0)
        self.assertEqual(self.state.read_text(), first)

    def test_main_backup_uses_madrid_day(self):
        # 23:30 UTC on the 15th is 00:30 on the 16th in Madrid: same local day, no rotation.
        prev = json.dumps({"version": 1, "updated": "2026-11-15T23:30:00Z", "obs": {"a|1": [["2", "2026-11-16"]]}})
        self.state.write_text(prev)
        self.assertEqual(self.run_main(), 0)
        self.assertFalse((self.tmp / "platforms-prev.json").exists())

    def test_main_daily_backup(self):
        prev = json.dumps({"version": 1, "updated": "2026-11-15T20:50:00Z", "obs": {"a|1": [["2", "2026-11-15"]]}})
        self.state.write_text(prev)
        self.assertEqual(self.run_main(), 0)
        self.assertEqual((self.tmp / "platforms-prev.json").read_text(), prev)
        # a second run the same day keeps yesterday's backup
        self.assertEqual(self.run_main(), 0)
        self.assertEqual((self.tmp / "platforms-prev.json").read_text(), prev)


if __name__ == "__main__":
    unittest.main()
