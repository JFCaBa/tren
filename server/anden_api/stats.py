"""Usage stats of Andén's board, aggregates only (port of What Platform's api/platform_api/stats.py).

Each GET /live/<stop> is counted here. Its client IP (sent by nginx only on that route) and
app version (from the User-Agent) are combined, for an instant, with a random key that lives only in memory and is
replaced when a Madrid day ends: `HMAC(key, ip + ua)` goes into that day's set, and into the set
of that station, so a person is counted once a day (and once per station). When the day ends
the key and the sets are dropped and only the counts remain. The IP, the User-Agent and the
hashes never reach disk or a log.
"""
from __future__ import annotations

import dataclasses
import hmac
import re
import secrets
import threading
from collections import Counter
from datetime import datetime, timezone
from zoneinfo import ZoneInfo

MADRID = ZoneInfo("Europe/Madrid")
# Only the app's numeric version ("Anden/1.4"): a made-up User-Agent is neither a person nor a
# version row, so it cannot inflate the counts or flood /admin.
VERSION_RE = re.compile(r"^Anden/([0-9]{1,3}(?:\.[0-9]{1,3}){0,2})(?:\s|$)")
OTHER = "otro"
# The website (andenapp.com, GET /board): a browser counts as a person with version «web», like
# What Platform's stats; bots, crawlers, link previews and headless tools do not.
WEB = "web"
NOT_A_PERSON_RE = re.compile(r"bot|crawl|spider|preview|headless", re.IGNORECASE)


@dataclasses.dataclass
class Delta:
    day: str
    visitors: int  # size of that day's set so far (grows; not reset by drain)
    closed: bool  # the day is over: its key and sets are gone
    requests: int = 0
    follows: int = 0
    hours: dict[int, int] = dataclasses.field(default_factory=dict)
    stations: dict[str, tuple[int, int]] = dataclasses.field(default_factory=dict)  # stop → (people so far, requests since last drain)
    versions: dict[str, int] = dataclasses.field(default_factory=dict)
    channels: dict[str, int] = dataclasses.field(default_factory=dict)  # «app»/«web» → people so far that day


def madrid_day(ts: float) -> str:
    return datetime.fromtimestamp(ts, timezone.utc).astimezone(MADRID).strftime("%Y-%m-%d")


def madrid_hour(ts: float) -> int:
    return datetime.fromtimestamp(ts, timezone.utc).astimezone(MADRID).hour


APP = "app"


def _channel(version: str) -> str:
    return WEB if version == WEB else APP


def _version(ua: str) -> str:
    m = VERSION_RE.match(ua)
    if m:
        return m.group(1)
    return WEB if ua.startswith("Mozilla/") and not NOT_A_PERSON_RE.search(ua) else OTHER


class _Day:
    def __init__(self) -> None:
        self.requests = 0
        self.follows = 0
        self.hours: Counter[int] = Counter()
        self.stations: Counter[str] = Counter()
        self.versions: Counter[str] = Counter()

    def empty(self) -> bool:
        return not (self.requests or self.follows)


class Tally:
    """In-memory counters of the current Madrid day (and of days closed since the last drain)."""

    def __init__(self, key_factory=lambda: secrets.token_bytes(32)) -> None:
        self._key_factory = key_factory
        self._lock = threading.Lock()
        self._day: str | None = None
        self._key = b""
        self._seen: set[bytes] = set()
        self._at: dict[str, set[bytes]] = {}  # stop → people seen there today
        self._by: dict[str, set[bytes]] = {}  # «app»/«web» → people seen through it today
        self._counts: dict[str, _Day] = {}
        self._closed: dict[str, tuple[int, dict[str, int], dict[str, int]]] = {}  # day → (people, by stop, by channel)

    def _roll(self, day: str) -> bool:
        """Make `day` current. False when `day` is before the current one (a late request)."""
        if self._day is not None and day < self._day:
            return False
        if self._day is not None and day > self._day:
            self._closed[self._day] = (len(self._seen), {s: len(p) for s, p in self._at.items()}, self._by_counts())
            self._seen, self._at, self._by, self._key, self._day = set(), {}, {}, b"", None
        if self._day is None:
            self._day = day
            self._key = self._key_factory()
        return True

    def _today(self) -> _Day:
        return self._counts.setdefault(self._day, _Day())

    def add_live(self, ts: float, stop: str, ip: str | None, ua: str) -> None:
        with self._lock:
            if not self._roll(madrid_day(ts)):
                return
            c = self._today()
            c.requests += 1
            c.hours[madrid_hour(ts)] += 1
            c.stations[stop] += 1
            version = _version(ua)
            c.versions[version] += 1
            people = self._at.setdefault(stop, set())
            if ip and version != OTHER:
                h = hmac.new(self._key, f"{ip}\n{version}".encode(), "sha256").digest()[:16]
                self._seen.add(h)
                people.add(h)
                self._by.setdefault(_channel(version), set()).add(h)

    def add_follow(self, ts: float) -> None:
        with self._lock:
            if self._roll(madrid_day(ts)):
                self._today().follows += 1

    def visitors_today(self, now: float | None = None) -> int:
        """People counted so far today; 0 when `now` is already a later day than the set's."""
        with self._lock:
            if now is not None and self._day is not None and madrid_day(now) != self._day:
                return 0
            return len(self._seen)

    def _by_counts(self) -> dict[str, int]:
        return {ch: len(p) for ch, p in self._by.items()}

    def channels_today(self, now: float | None = None) -> dict[str, int]:
        """People counted so far today by channel; empty when `now` is already a later day."""
        with self._lock:
            if now is not None and self._day is not None and madrid_day(now) != self._day:
                return {}
            return self._by_counts()

    def drain(self, now: float) -> list[Delta]:
        """Counters since the last drain, one Delta per day, oldest first; resets them."""
        with self._lock:
            self._roll(madrid_day(now))
            out = []
            for day in sorted(set(self._counts) | set(self._closed) | {self._day}):
                c = self._counts.get(day) or _Day()
                closed = day in self._closed
                if closed:
                    visitors, people, channels = self._closed[day]
                else:
                    visitors, people, channels = len(self._seen), {s: len(p) for s, p in self._at.items()}, self._by_counts()
                if not closed and c.empty() and not visitors:
                    continue
                stops = set(people) | set(c.stations)
                out.append(Delta(day, visitors, closed, c.requests, c.follows, dict(c.hours),
                                 {s: (people.get(s, 0), c.stations.get(s, 0)) for s in stops},
                                 dict(c.versions), channels))
            self._counts = {}
            self._closed = {}
            return out
