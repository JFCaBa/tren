"""SQLite store of the usage aggregates (stats.py): per day, hour, station and app version.
Only counts: no IP, User-Agent, hash or device identifier is ever written here.
(Port of What Platform's api/platform_api/stats_db.py, with people per station.)"""
from __future__ import annotations

import sqlite3
import threading
from pathlib import Path

from .stats import Delta

SCHEMA = """
CREATE TABLE IF NOT EXISTS days (day TEXT PRIMARY KEY, visitors INTEGER NOT NULL DEFAULT 0,
    requests INTEGER NOT NULL DEFAULT 0, follows INTEGER NOT NULL DEFAULT 0);
CREATE TABLE IF NOT EXISTS hours (day TEXT NOT NULL, hour INTEGER NOT NULL,
    requests INTEGER NOT NULL, PRIMARY KEY (day, hour));
CREATE TABLE IF NOT EXISTS stations (day TEXT NOT NULL, stop TEXT NOT NULL,
    people INTEGER NOT NULL DEFAULT 0, requests INTEGER NOT NULL DEFAULT 0, PRIMARY KEY (day, stop));
CREATE TABLE IF NOT EXISTS versions (day TEXT NOT NULL, version TEXT NOT NULL,
    requests INTEGER NOT NULL, PRIMARY KEY (day, version));
CREATE TABLE IF NOT EXISTS channels (day TEXT NOT NULL, channel TEXT NOT NULL,
    people INTEGER NOT NULL DEFAULT 0, PRIMARY KEY (day, channel));
"""


class StatsDB:
    def __init__(self, path: str | Path) -> None:
        self._lock = threading.Lock()
        self._conn = sqlite3.connect(str(path), check_same_thread=False, timeout=10)
        self._conn.execute("PRAGMA journal_mode=WAL")
        self._conn.executescript(SCHEMA)
        self._base: dict[str, int] = {}  # day → visitors stored before this process saw it
        self._station_base: dict[tuple[str, str], int] = {}  # (day, stop) → people, likewise
        self._channel_base: dict[str, dict[str, int]] = {}  # day → {«app»/«web»: people}, likewise

    def close(self) -> None:
        with self._lock:
            self._conn.close()

    def _base_for(self, day: str) -> int:
        """Visitors already stored for `day` the first time this store sees it (a restart's
        earlier count); frozen, so base + the live set never counts a flush twice."""
        if day not in self._base:
            row = self._conn.execute("SELECT visitors FROM days WHERE day = ?", (day,)).fetchone()
            self._base[day] = row[0] if row else 0
        return self._base[day]

    def _station_base_for(self, day: str, stop: str) -> int:
        key = (day, stop)
        if key not in self._station_base:
            row = self._conn.execute("SELECT people FROM stations WHERE day = ? AND stop = ?", key).fetchone()
            self._station_base[key] = row[0] if row else 0
        return self._station_base[key]

    def _channel_base_for(self, day: str) -> dict[str, int]:
        if day not in self._channel_base:
            self._channel_base[day] = dict(self._conn.execute(
                "SELECT channel, people FROM channels WHERE day = ?", (day,)))
        return self._channel_base[day]

    def channels_base(self, day: str) -> dict[str, int]:
        with self._lock:
            return dict(self._channel_base_for(day))

    def visitors_base(self, day: str) -> int:
        with self._lock:
            return self._base_for(day)

    def apply(self, deltas: list[Delta]) -> None:
        """One transaction: a failure leaves nothing of the batch, so it can be retried as a whole."""
        with self._lock:
            base, station_base, channel_base = dict(self._base), dict(self._station_base), dict(self._channel_base)
            try:
                with self._conn:
                    c = self._conn
                    for d in deltas:
                        c.execute("INSERT INTO days (day, visitors, requests, follows) VALUES (?, ?, ?, ?) "
                                  "ON CONFLICT(day) DO UPDATE SET visitors = excluded.visitors, "
                                  "requests = requests + excluded.requests, follows = follows + excluded.follows",
                                  (d.day, self._base_for(d.day) + d.visitors, d.requests, d.follows))
                        c.executemany("INSERT INTO stations (day, stop, people, requests) VALUES (?, ?, ?, ?) "
                                      "ON CONFLICT(day, stop) DO UPDATE SET people = excluded.people, "
                                      "requests = requests + excluded.requests",
                                      [(d.day, s, self._station_base_for(d.day, s) + p, n)
                                       for s, (p, n) in d.stations.items()])
                        cb = self._channel_base_for(d.day)
                        c.executemany("INSERT INTO channels (day, channel, people) VALUES (?, ?, ?) "
                                      "ON CONFLICT(day, channel) DO UPDATE SET people = excluded.people",
                                      [(d.day, ch, cb.get(ch, 0) + p) for ch, p in d.channels.items()])
                        for table, col, counts in (("hours", "hour", d.hours), ("versions", "version", d.versions)):
                            c.executemany(f"INSERT INTO {table} (day, {col}, requests) VALUES (?, ?, ?) "
                                          f"ON CONFLICT(day, {col}) DO UPDATE SET requests = requests + excluded.requests",
                                          [(d.day, k, n) for k, n in counts.items()])
            except Exception:
                self._base, self._station_base, self._channel_base = base, station_base, channel_base  # bases read inside the rolled-back batch
                raise
            for d in deltas:  # a closed day gets no more writes: its bases are no longer needed
                if d.closed:
                    self._base.pop(d.day, None)
                    self._channel_base.pop(d.day, None)
                    for k in [k for k in self._station_base if k[0] == d.day]:
                        del self._station_base[k]

    def _since(self, since: str | None) -> tuple[str, tuple]:
        return ("WHERE day >= ?", (since,)) if since else ("", ())

    def days(self, since: str | None) -> list[dict]:
        where, args = self._since(since)
        with self._lock:
            rows = self._conn.execute(f"SELECT day, visitors, requests, follows FROM days {where} ORDER BY day",
                                      args).fetchall()
        return [{"day": r[0], "visitors": r[1], "requests": r[2], "follows": r[3]} for r in rows]

    def top_stations(self, since: str | None, limit: int = 20) -> list[tuple[str, int]]:
        """Stations by people (each day's distinct people, added up over the days)."""
        where, args = self._since(since)
        with self._lock:
            return [tuple(r) for r in self._conn.execute(
                f"SELECT stop, SUM(people) AS n FROM stations {where} GROUP BY stop ORDER BY n DESC, stop LIMIT ?",
                args + (limit,))]

    def station_requests(self, day: str) -> dict[str, int]:
        with self._lock:
            return dict(self._conn.execute("SELECT stop, requests FROM stations WHERE day = ?", (day,)))

    def hours(self, since: str | None) -> dict[int, int]:
        where, args = self._since(since)
        with self._lock:
            return dict(self._conn.execute(f"SELECT hour, SUM(requests) FROM hours {where} GROUP BY hour", args))

    def versions(self, since: str | None) -> dict[str, int]:
        where, args = self._since(since)
        with self._lock:
            return dict(self._conn.execute(f"SELECT version, SUM(requests) FROM versions {where} GROUP BY version",
                                           args))

    def channels(self, since: str | None, before: str | None = None) -> dict[str, int]:
        """People by channel («app»/«web»), each day's distinct people added up over the days
        from `since` and, with `before`, only the days before it."""
        where, args = self._since(since)
        if before:
            where, args = (f"{where} AND day < ?" if where else "WHERE day < ?"), args + (before,)
        with self._lock:
            return dict(self._conn.execute(f"SELECT channel, SUM(people) FROM channels {where} GROUP BY channel",
                                           args))

    def stations_count(self, day: str) -> int:
        with self._lock:
            return self._conn.execute("SELECT COUNT(*) FROM stations WHERE day = ?", (day,)).fetchone()[0]

    def backup(self, dest_dir: Path, day: str, keep: int = 7) -> None:
        dest_dir = Path(dest_dir)
        dest_dir.mkdir(parents=True, exist_ok=True)
        target = sqlite3.connect(str(dest_dir / f"stats-{day}.db"))
        try:
            with self._lock:
                self._conn.backup(target)
        finally:
            target.close()
        for old in sorted(dest_dir.glob("stats-*.db"))[:-keep]:
            old.unlink()
