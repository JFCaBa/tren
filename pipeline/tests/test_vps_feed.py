"""pipeline/vps/feed.sh: nightly feed build on the VPS, published as an atomic generation swap."""
import fcntl
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
SCRIPT = HERE.parent / "vps" / "feed.sh"
BUILD_FEED = HERE.parent / "build_feed.py"
sys.path.insert(0, str(HERE))
from test_cli_nucleos import zip_fixture  # noqa: E402

FAKE_BUILD = r'''
import json, os, shutil, sys
args = sys.argv[1:]
with open(os.environ["FAKE_ARGS"], "a") as f:
    f.write(json.dumps(args) + "\n")
if os.environ.get("FAKE_EXIT"):
    sys.exit(int(os.environ["FAKE_EXIT"]))
out = args[args.index("--out") + 1]
shutil.copytree(os.environ["FAKE_SRC"], out, dirs_exist_ok=True)
'''


@unittest.skipUnless(shutil.which("flock"), "flock(1) missing (macOS); runs on the VPS and in CI")
class FeedShTest(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = Path(self._tmp.name)
        self.out = self.tmp / "data"
        self.out.mkdir()
        self.src = self.tmp / "src"
        (self.tmp / "fake_build.py").write_text(FAKE_BUILD)
        self.args_log = self.tmp / "args.log"

    def tearDown(self):
        self._tmp.cleanup()

    def files(self, files):
        if self.src.exists():
            subprocess.run(["rm", "-rf", str(self.src)], check=True)
        for rel, content in files.items():
            p = self.src / rel
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_text(content)

    def run_sh(self, build=None, fail=False, seed="https://seed.invalid/tren", **extra):
        env = dict(os.environ, **extra, ANDEN_DATA_DIR=str(self.out), ANDEN_PLATFORMS=str(self.tmp / "platforms.json"),
                   ANDEN_SEED=seed, FAKE_ARGS=str(self.args_log), FAKE_SRC=str(self.src),
                   ANDEN_BUILD=build or f"{sys.executable} {self.tmp / 'fake_build.py'}")
        if fail:
            env["FAKE_EXIT"] = "1"
        return subprocess.run(["bash", str(SCRIPT)], env=env, capture_output=True, text=True)

    def last_previous_base(self):
        args = json.loads(self.args_log.read_text().splitlines()[-1])
        return args[args.index("--previous-base") + 1]

    def current(self):
        return self.out / "current"

    def gens(self):
        return sorted(p.name for p in self.out.glob("gen.*"))

    def log(self):
        return (self.out / "feed.log").read_text()

    def test_builds_website_pages_after_publishing(self):
        stops = [{"id": f"{i:05d}", "name": f"S{i}", "lat": 40.0 + i / 100, "lon": -3.0, "nucleos": ["10"]} for i in range(3)]
        self.files({"index.json": json.dumps({"generated_at": "2026-11-26T02:30:00Z", "stops": stops,
                                              "nucleos": [{"id": "10", "name": "Madrid", "feed": "feeds/10.json"}]}),
                    "feeds/10.json": "{}"})
        pages = self.tmp / "pages"
        pages.mkdir()
        repo = HERE.parents[1]
        # min-count 800 refuses 3 stations: the feed still publishes and says the pages failed
        r = self.run_sh(ANDEN_PAGES_DIR=str(pages), ANDEN_WEB_REPO=str(repo))
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertTrue((self.current() / "index.json").exists())
        log = (self.out / "feed.log").read_text()
        self.assertIn("pages failed", log)
        self.assertFalse((pages / "current").exists())

    def test_no_pages_dir_no_pages(self):
        self.files({"index.json": "{}"})
        r = self.run_sh(ANDEN_PAGES_DIR=str(self.tmp / "nope"))
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertNotIn("pages", (self.out / "feed.log").read_text())

    def test_first_run_seeds_from_pages(self):
        self.files({"index.json": "{}", "feeds/10.json": "a"})
        proc = self.run_sh()
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(self.last_previous_base(), "https://seed.invalid/tren")
        self.assertEqual((self.current() / "index.json").read_text(), "{}")
        self.assertIn("ok", self.log())

    def test_second_run_uses_current(self):
        self.files({"index.json": "{}"})
        self.run_sh()
        self.run_sh()
        self.assertEqual(self.last_previous_base(), f"file://{self.out}/current")

    def test_build_failure_keeps_current(self):
        self.files({"index.json": "{}"})
        self.run_sh()
        target = os.readlink(self.current())
        proc = self.run_sh(fail=True)
        self.assertNotEqual(proc.returncode, 0)
        self.assertEqual(os.readlink(self.current()), target)
        self.assertIn("error", self.log())
        self.assertEqual(self.gens(), [Path(target).name])

    def test_empty_output_not_published(self):
        self.files({"feeds/10.json": "a"})  # no index.json
        self.assertNotEqual(self.run_sh().returncode, 0)
        self.assertFalse(self.current().exists())
        self.assertEqual(self.gens(), [])

    def test_removed_nucleo_absent(self):
        self.files({"index.json": "{}", "feeds/10.json": "a", "feeds/20.json": "b"})
        self.run_sh()
        self.files({"index.json": "{}", "feeds/10.json": "a"})
        self.run_sh()
        self.assertFalse((self.current() / "feeds/20.json").exists())

    def test_keeps_two_generations(self):
        for n in range(3):
            self.files({"index.json": str(n)})
            self.assertEqual(self.run_sh().returncode, 0)
        gens = self.gens()
        self.assertEqual(len(gens), 2)
        self.assertIn(Path(os.readlink(self.current())).name, gens)
        self.assertEqual((self.current() / "index.json").read_text(), "2")

    def test_published_files_world_readable(self):
        self.files({"index.json": "{}", "feeds/10.json": "a"})
        self.run_sh()
        for p in (self.current().resolve(), self.current() / "feeds", self.current() / "feeds/10.json"):
            self.assertTrue(p.stat().st_mode & 0o004, p)

    def test_locked_logs_skip(self):
        self.files({"index.json": "{}"})
        with open(self.out / "lock", "w") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            proc = self.run_sh()
        self.assertEqual(proc.returncode, 0)
        self.assertIn("skipped", self.log())
        self.assertFalse(self.args_log.exists())

    def test_real_build_file_previous(self):
        zip_fixture("multi", self.tmp / "gtfs.zip")
        build = f"{sys.executable} {BUILD_FEED} --zip {self.tmp / 'gtfs.zip'} --date 2026-11-15"
        seed = (self.tmp / "noprev").as_uri()  # first run: no previous publication anywhere
        first = self.run_sh(build=build, seed=seed)
        self.assertEqual(first.returncode, 0, first.stderr + self.log())
        second = self.run_sh(build=build, seed=seed)
        self.assertEqual(second.returncode, 0, second.stderr + self.log())
        index = json.loads((self.current() / "index.json").read_text())
        self.assertTrue(index["nucleos"])
        for n in index["nucleos"]:
            self.assertTrue((self.current() / n["feed"]).exists(), n)


if __name__ == "__main__":
    unittest.main()
