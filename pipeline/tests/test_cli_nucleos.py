import json
import subprocess
import sys
import tempfile
import unittest
import zipfile
from datetime import date
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from build_feed import build_nucleos, validate_nucleo  # noqa: E402

FIX = Path(__file__).parent / "fixtures"
SCRIPT = Path(__file__).resolve().parent.parent / "build_feed.py"
TODAY = date(2026, 11, 15)


def zip_fixture(name, dest):
    with zipfile.ZipFile(dest, "w") as z:
        for f in (FIX / name).iterdir():
            z.write(f, f.name)


def run(tmp, fixture, *extra, date_="2026-11-15", prev=None, base=None):
    tmp = Path(tmp)
    zip_fixture(fixture, tmp / "gtfs.zip")
    prev = prev or (tmp / "noprev")
    prev.mkdir(exist_ok=True)
    out = tmp / "out"
    proc = subprocess.run(
        [sys.executable, str(SCRIPT), "--out", str(out), "--zip", str(tmp / "gtfs.zip"), "--date", date_,
         "--previous-base", base or prev.as_uri(), *extra],
        capture_output=True, text=True)
    return proc, out


def prev_feed(nucleo, n_stops, marker="PREV"):
    return {"version": 2, "nucleo": nucleo, "name": "X", "generated_at": marker, "valid_from": "2026-11-14",
            "valid_to": "2026-11-22", "lines": {"C1": "9E9E9E"},
            "stops": [{"id": f"P{i}", "name": f"P{i}", "lat": 40.0, "lon": -3.0} for i in range(n_stops)],
            "trips": []}


class ValidateNucleoTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.feeds = build_nucleos(FIX / "multi", TODAY)

    def test_validate_nucleo_ok(self):
        self.assertEqual([], validate_nucleo(self.feeds["10"], TODAY, None))

    def test_validate_nucleo_too_few_stops_vs_previous(self):
        errors = validate_nucleo(self.feeds["10"], TODAY, prev_feed("10", 10))
        self.assertTrue(any("stops" in e for e in errors), errors)

    def test_validate_nucleo_too_few_trips_vs_previous(self):
        prev = prev_feed("10", 2)
        prev["trips"] = [{"id": str(i)} for i in range(10)]
        errors = validate_nucleo(self.feeds["10"], TODAY, prev)
        self.assertTrue(any("trips" in e for e in errors), errors)

    def test_validate_nucleo_needs_today_and_tomorrow(self):
        errors = validate_nucleo(self.feeds["10"], date(2030, 1, 1), None)
        self.assertTrue(any("2030-01-01" in e for e in errors), errors)


class CliNucleosTest(unittest.TestCase):
    def test_publishes_index_and_feeds(self):
        with tempfile.TemporaryDirectory() as tmp:
            proc, out = run(tmp, "multi")
            self.assertEqual(0, proc.returncode, proc.stderr)
            index = json.loads((out / "index.json").read_text(encoding="utf-8"))
            self.assertEqual(["10", "47", "60"], [n["id"] for n in index["nucleos"]])
            self.assertEqual(2, json.loads((out / "feeds" / "10.json").read_text(encoding="utf-8"))["version"])

    def test_failed_nucleo_republishes_previous(self):
        with tempfile.TemporaryDirectory() as tmp:
            prev = Path(tmp) / "prev"
            (prev / "feeds").mkdir(parents=True)
            raw = json.dumps(prev_feed("47", 10)).encode()
            (prev / "feeds" / "47.json").write_bytes(raw)
            (prev / "index.json").write_text(json.dumps({"nucleos": [{"id": "47"}]}))
            proc, out = run(tmp, "multi", prev=prev)
            self.assertEqual(0, proc.returncode, proc.stderr)
            self.assertEqual(raw, (out / "feeds" / "47.json").read_bytes())
            self.assertIn("kept previous", proc.stderr)
            self.assertNotEqual("PREV", json.loads((out / "feeds" / "10.json").read_text())["generated_at"])
            index = json.loads((out / "index.json").read_text(encoding="utf-8"))
            self.assertIn("47", [n["id"] for n in index["nucleos"]])
            self.assertIn("P0", [s["id"] for s in index["stops"]])

    def test_incompatible_previous_is_ignored(self):
        with tempfile.TemporaryDirectory() as tmp:
            prev = Path(tmp) / "prev"
            (prev / "feeds").mkdir(parents=True)
            (prev / "feeds" / "47.json").write_text("[1, 2, 3]")
            (prev / "feeds" / "62.json").write_text(json.dumps({"version": 2, "stops": []}))  # no name/trips
            (prev / "index.json").write_text(json.dumps({"nucleos": [{"id": "47"}, {"id": "62"}]}))
            proc, out = run(tmp, "multi", prev=prev)
            self.assertEqual(0, proc.returncode, proc.stderr)
            index = json.loads((out / "index.json").read_text(encoding="utf-8"))
            self.assertEqual(["10", "47", "60"], [n["id"] for n in index["nucleos"]])

    def test_expired_previous_is_not_republished(self):
        with tempfile.TemporaryDirectory() as tmp:
            prev = Path(tmp) / "prev"
            (prev / "feeds").mkdir(parents=True)
            old = prev_feed("62", 3)
            old["valid_to"] = "2026-11-14"  # before today
            (prev / "feeds" / "62.json").write_text(json.dumps(old))
            (prev / "index.json").write_text(json.dumps({"nucleos": [{"id": "62"}]}))
            proc, out = run(tmp, "multi", prev=prev)
            self.assertEqual(0, proc.returncode, proc.stderr)
            self.assertFalse((out / "feeds" / "62.json").exists())

    def test_fails_when_no_new_nucleo_valid_even_with_previous(self):
        with tempfile.TemporaryDirectory() as tmp:
            prev = Path(tmp) / "prev"
            (prev / "feeds").mkdir(parents=True)
            p47 = prev_feed("47", 3)
            p47["valid_to"] = "2030-01-05"
            (prev / "feeds" / "47.json").write_text(json.dumps(p47))
            (prev / "index.json").write_text(json.dumps({"nucleos": [{"id": "47"}]}))
            proc, out = run(tmp, "multi", date_="2030-01-01", prev=prev)
            self.assertEqual(1, proc.returncode, proc.stderr)
            self.assertFalse(out.exists() and any(out.iterdir()))

    def test_previous_unreachable_fails_run(self):
        # Connection refused != "no previous": publishing could drop a whole city from the index.
        with tempfile.TemporaryDirectory() as tmp:
            proc, out = run(tmp, "multi", base="http://127.0.0.1:9")
            self.assertEqual(1, proc.returncode, proc.stderr)
            self.assertIn("previous publication unreachable", proc.stderr)
            self.assertFalse(out.exists() and any(out.iterdir()))

    def test_corrupt_previous_index_fails_run(self):
        with tempfile.TemporaryDirectory() as tmp:
            prev = Path(tmp) / "prev"
            prev.mkdir()
            (prev / "index.json").write_text('{"nucleos": [')
            proc, out = run(tmp, "multi", prev=prev)
            self.assertEqual(1, proc.returncode, proc.stderr)
            self.assertFalse(out.exists() and any(out.iterdir()))

    def test_invalid_base_fails_run(self):
        with tempfile.TemporaryDirectory() as tmp:
            proc, out = run(tmp, "multi", base="notaurl")
            self.assertEqual(1, proc.returncode, proc.stderr)
            self.assertIn("previous publication unreachable", proc.stderr)

    def test_vanished_nucleo_republishes_previous(self):
        with tempfile.TemporaryDirectory() as tmp:
            prev = Path(tmp) / "prev"
            (prev / "feeds").mkdir(parents=True)
            raw = json.dumps(prev_feed("62", 3)).encode()
            (prev / "feeds" / "62.json").write_bytes(raw)
            (prev / "index.json").write_text(json.dumps({"nucleos": [{"id": "62"}]}))
            proc, out = run(tmp, "multi", prev=prev)
            self.assertEqual(0, proc.returncode, proc.stderr)
            self.assertEqual(raw, (out / "feeds" / "62.json").read_bytes())
            index = json.loads((out / "index.json").read_text(encoding="utf-8"))
            self.assertIn("62", [n["id"] for n in index["nucleos"]])

    def test_invalid_v1_without_previous_is_not_fatal(self):
        with tempfile.TemporaryDirectory() as tmp:
            proc, out = run(tmp, "multi")
            self.assertEqual(0, proc.returncode, proc.stderr)
            self.assertFalse((out / "feed.json").exists())
            self.assertIn("feed.json", proc.stderr)

    def test_cli_still_writes_v1_feed(self):
        with tempfile.TemporaryDirectory() as tmp:
            proc, out = run(tmp, "mini", "--min-stops", "3")
            self.assertEqual(0, proc.returncode, proc.stderr)
            self.assertEqual(1, json.loads((out / "feed.json").read_text(encoding="utf-8"))["version"])

    def test_cli_fails_when_no_nucleo_valid(self):
        with tempfile.TemporaryDirectory() as tmp:
            proc, out = run(tmp, "multi", date_="2030-01-01")
            self.assertEqual(1, proc.returncode, proc.stderr)
            self.assertFalse(out.exists() and any(out.iterdir()))


if __name__ == "__main__":
    unittest.main()
