import sqlite3

import pytest

from anden_api.stats import Delta
from anden_api.stats_db import StatsDB


def delta(day="2026-11-23", visitors=0, closed=False, requests=0, follows=0, hours=None, stations=None, versions=None):
    return Delta(day, visitors, closed, requests, follows, hours or {}, stations or {}, versions or {})


@pytest.fixture
def db(tmp_path):
    d = StatsDB(tmp_path / "stats.db")
    yield d
    d.close()


def test_apply_sums(db):
    db.apply([delta(requests=3, hours={8: 3}, stations={"18000": (1, 3)}, versions={"1.5": 3})])
    db.apply([delta(requests=2, hours={8: 1, 9: 1}, stations={"18000": (2, 1), "69110": (1, 1)},
                    versions={"1.5": 2}, follows=1)])
    [d] = db.days(None)
    assert (d["requests"], d["follows"]) == (5, 1)
    assert db.hours(None) == {8: 4, 9: 1}
    assert db.top_stations(None) == [("18000", 2), ("69110", 1)]  # people: absolute, not summed
    assert db.station_requests("2026-11-23") == {"18000": 4, "69110": 1}
    assert db.versions(None) == {"1.5": 5}


def test_people_summed_across_days(db):
    db.apply([delta(day="2026-11-22", stations={"18000": (3, 9)}), delta(stations={"18000": (2, 4)})])
    assert db.top_stations(None) == [("18000", 5)]
    assert db.top_stations("2026-11-23") == [("18000", 2)]


def test_visitors_not_summed(db):
    db.apply([delta(visitors=4)])
    db.apply([delta(visitors=6)])
    assert db.days(None)[0]["visitors"] == 6


def test_restart_base_visitors_and_station_people(tmp_path):
    db = StatsDB(tmp_path / "s.db")
    db.apply([delta(visitors=10, stations={"18000": (7, 20)})])
    db.close()
    db = StatsDB(tmp_path / "s.db")  # the new process's sets start empty
    db.apply([delta(visitors=3, stations={"18000": (2, 5)})])
    db.apply([delta(visitors=4, stations={"18000": (3, 1)})])
    assert db.days(None)[0]["visitors"] == 14  # monotonic: base 10 + 4 (a returning person counts again)
    assert db.top_stations(None) == [("18000", 10)]
    assert db.station_requests("2026-11-23") == {"18000": 26}
    assert db.visitors_base("2026-11-23") == 10
    db.close()


def test_stations_count(db):
    db.apply([delta(stations={"18000": (1, 2), "69110": (1, 1)}), delta(day="2026-11-22", stations={"65000": (1, 1)})])
    assert db.stations_count("2026-11-23") == 2


def test_queries_since(db):
    for day, n in (("2026-11-21", 1), ("2026-11-22", 2), ("2026-11-23", 3)):
        db.apply([delta(day=day, requests=n, stations={"18000": (n, n), "A": (1, 1), f"B{n}": (5, 5)})])
    assert [d["day"] for d in db.days("2026-11-22")] == ["2026-11-22", "2026-11-23"]
    # 18000: 2 + 3 people; ties ordered by stop id
    assert db.top_stations("2026-11-22", limit=3) == [("18000", 5), ("B2", 5), ("B3", 5)]
    assert ("B1", 5) not in db.top_stations("2026-11-22")


def test_apply_failure_rolls_back(db):
    db.apply([delta(requests=1, stations={"18000": (1, 1)})])
    bad = [delta(requests=5), delta(stations={"x": (None, 1)})]  # people NOT NULL: fails mid-batch
    with pytest.raises(Exception):
        db.apply(bad)
    assert db.days(None)[0]["requests"] == 1  # nothing of the failed batch
    db.apply([delta(requests=5)])  # the retry counts once
    assert db.days(None)[0]["requests"] == 6


def test_backup_keeps_7(db, tmp_path):
    dest = tmp_path / "backups" / "nested"
    db.apply([delta(requests=1)])
    for i in range(1, 10):
        db.backup(dest, f"2026-11-{i:02d}")
    files = sorted(p.name for p in dest.iterdir())
    assert files == [f"stats-2026-11-{i:02d}.db" for i in range(3, 10)]
    with sqlite3.connect(dest / files[-1]) as c:
        assert c.execute("SELECT requests FROM days").fetchone() == (1,)


def test_no_sensitive_columns(tmp_path):
    StatsDB(tmp_path / "x.db").close()
    allowed = {"day", "visitors", "people", "requests", "follows", "hour", "stop", "version"}
    with sqlite3.connect(tmp_path / "x.db") as c:
        for (t,) in c.execute("SELECT name FROM sqlite_master WHERE type='table'"):
            cols = {r[1] for r in c.execute(f"PRAGMA table_info({t})")}
            assert cols <= allowed, (t, cols)


def test_bases_of_closed_days_dropped(db):
    db.apply([delta(day="2026-11-22", visitors=3, stations={"18000": (2, 2)})])
    db.apply([delta(day="2026-11-22", visitors=3, closed=True, stations={"18000": (2, 0)}),
              delta(visitors=1, stations={"18000": (1, 1)})])
    assert all(k[0] != "2026-11-22" for k in db._station_base) and "2026-11-22" not in db._base
    assert db.days("2026-11-22")[0]["visitors"] == 3
