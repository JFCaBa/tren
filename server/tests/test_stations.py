import json
import os

from anden_api.stations import StationTrips


def feed(nucleo, trips):
    return {"version": 2, "nucleo": nucleo, "name": nucleo, "stops": [],
            "trips": [{"id": tid, "times": [[s, 0] for s in stops]} for tid, stops in trips.items()]}


def write_gen(root, name, feeds, broken=None):
    gen = root / name
    (gen / "feeds").mkdir(parents=True)
    for n, f in feeds.items():
        (gen / "feeds" / f"{n}.json").write_text(json.dumps(f))
    if broken:
        (gen / "feeds" / f"{broken}.json").write_text("{oops")
    names = list(feeds) + ([broken] if broken else [])
    (gen / "index.json").write_text(json.dumps({"nucleos": [{"id": n, "feed": f"feeds/{n}.json"} for n in names]}))
    return gen


def point(root, gen):
    tmp = root / "current.new"
    if tmp.is_symlink():
        tmp.unlink()
    tmp.symlink_to(gen)
    os.replace(tmp, root / "current")


def test_index_from_feeds(tmp_path):
    point(tmp_path, write_gen(tmp_path, "gen.a", {
        "10": feed("10", {"T1": ["S1", "S2"], "T2": ["S3", "S1"]}),
        "40": feed("40", {"M1": ["S9"]})}))
    st = StationTrips(tmp_path / "current")
    st.refresh()
    assert st.loaded
    assert st.get("S1") == {"T1", "T2"}
    assert st.get("S9") == {"M1"}
    assert st.get("NOPE") == frozenset() and not st.known("NOPE") and st.known("S2")


def test_not_loaded_returns_none(tmp_path):
    st = StationTrips(tmp_path / "current")
    st.refresh()  # nothing built yet
    assert st.get("S1") is None and not st.loaded
    point(tmp_path, write_gen(tmp_path, "gen.a", {"10": feed("10", {"T1": ["S1"]})}))
    st.refresh()
    assert st.get("S1") == {"T1"}


def test_reload_on_new_generation(tmp_path):
    point(tmp_path, write_gen(tmp_path, "gen.a", {"10": feed("10", {"T1": ["S1"]})}))
    st = StationTrips(tmp_path / "current")
    st.refresh()
    point(tmp_path, write_gen(tmp_path, "gen.b", {"10": feed("10", {"T7": ["S1"]})}))
    assert st.get("S1") == {"T1"}  # get never reads disk
    st.refresh()
    assert st.get("S1") == {"T7"}


def test_same_generation_not_reread(tmp_path):
    gen = write_gen(tmp_path, "gen.a", {"10": feed("10", {"T1": ["S1"]})})
    point(tmp_path, gen)
    st = StationTrips(tmp_path / "current")
    st.refresh()
    (gen / "feeds" / "10.json").write_text("{oops")  # would fail if read again
    st.refresh()
    assert st.get("S1") == {"T1"}


def test_broken_generation_keeps_previous(tmp_path):
    point(tmp_path, write_gen(tmp_path, "gen.a", {"10": feed("10", {"T1": ["S1"]})}))
    st = StationTrips(tmp_path / "current")
    st.refresh()
    point(tmp_path, write_gen(tmp_path, "gen.b", {"10": feed("10", {"T7": ["S1"]})}, broken="40"))
    st.refresh()
    assert st.get("S1") == {"T1"}


def test_reads_one_generation(tmp_path):
    """index.json and the feeds come from the generation resolved at the start, even if
    `current` moves while loading."""
    a = write_gen(tmp_path, "gen.a", {"10": feed("10", {"T1": ["S1"]})})
    b = write_gen(tmp_path, "gen.b", {"10": feed("10", {"T7": ["S1"]})})
    point(tmp_path, a)
    st = StationTrips(tmp_path / "current")
    real_load = st._load_feed

    def moving(path):
        point(tmp_path, b)
        return real_load(path)

    st._load_feed = moving
    st.refresh()
    assert st.get("S1") == {"T1"}


def test_failed_generation_not_retried_until_it_changes(tmp_path):
    point(tmp_path, write_gen(tmp_path, "gen.a", {"10": feed("10", {"T1": ["S1"]})}, broken="40"))
    st = StationTrips(tmp_path / "current")
    reads = []
    real = st._load_feed
    st._load_feed = lambda p: (reads.append(p), real(p))[1]
    assert st.refresh() is False
    n = len(reads)
    assert st.refresh() is False and len(reads) == n  # same broken generation: not parsed again
    point(tmp_path, write_gen(tmp_path, "gen.b", {"10": feed("10", {"T7": ["S1"]})}))
    assert st.refresh() is True and st.get("S1") == {"T7"}
