import copy
import json
import subprocess
import sys
import tempfile
import unittest
import zipfile
from datetime import date, timedelta
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from build_feed import build_feed, validate_feed  # noqa: E402

MINI = Path(__file__).parent / "fixtures" / "mini"
TODAY = date(2026, 11, 15)
TOMORROW = (TODAY + timedelta(days=1)).isoformat()
SCRIPT = Path(__file__).resolve().parent.parent / "build_feed.py"


class ValidateFeedTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.feed = build_feed(MINI, TODAY)

    def test_validate_ok(self):
        self.assertEqual([], validate_feed(self.feed, TODAY, min_stops=3))

    def test_validate_missing_line(self):
        feed = copy.deepcopy(self.feed)
        feed["trips"] = [t for t in feed["trips"] if t["line"] != "C2"]
        errors = validate_feed(feed, TODAY, min_stops=3)
        self.assertTrue(any("C2" in e for e in errors), errors)

    def test_validate_not_covering_tomorrow(self):
        feed = copy.deepcopy(self.feed)
        for t in feed["trips"]:
            t["dates"] = [d for d in t["dates"] if d != TOMORROW]
        errors = validate_feed(feed, TODAY, min_stops=3)
        self.assertTrue(any(TOMORROW in e for e in errors), errors)

    def test_validate_line_without_service_today(self):
        feed = copy.deepcopy(self.feed)
        for t in feed["trips"]:
            if t["line"] == "C2":
                t["dates"] = ["2026-11-14"]
        errors = validate_feed(feed, TODAY, min_stops=3)
        self.assertTrue(any("C2" in e and TODAY.isoformat() in e for e in errors), errors)

    def test_validate_too_few_stops(self):
        errors = validate_feed(self.feed, TODAY, min_stops=20)
        self.assertTrue(any("stops" in e for e in errors), errors)

    def _run_cli(self, tmp, *extra):
        zpath = Path(tmp) / "gtfs.zip"
        with zipfile.ZipFile(zpath, "w") as z:
            for f in MINI.iterdir():
                z.write(f, f.name)
        out = Path(tmp) / "out"
        proc = subprocess.run([sys.executable, str(SCRIPT), "--out", str(out), "--zip", str(zpath),
                               "--date", TODAY.isoformat(), *extra], capture_output=True, text=True)
        return proc, out

    def test_cli_does_not_write_on_invalid(self):
        with tempfile.TemporaryDirectory() as tmp:
            proc, out = self._run_cli(tmp)  # default min_stops=20 > 4 fixture stops
            self.assertEqual(1, proc.returncode, proc.stderr)
            self.assertFalse((out / "feed.json").exists())

    def test_cli_writes_valid_feed_atomically(self):
        with tempfile.TemporaryDirectory() as tmp:
            proc, out = self._run_cli(tmp, "--min-stops", "3")
            self.assertEqual(0, proc.returncode, proc.stderr)
            feed = json.loads((out / "feed.json").read_text(encoding="utf-8"))
            self.assertEqual("2026-11-14", feed["valid_from"])
            self.assertEqual(["feed.json"], [p.name for p in out.iterdir()])


if __name__ == "__main__":
    unittest.main()
