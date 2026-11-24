"""Renfe's open GTFS-RT feeds (JSON): trip updates (delay, cancellation) and vehicle positions
(where each train is and, while it arrives or stands at a stop, its platform)."""
from __future__ import annotations

import json
import threading
import re
import urllib.error
import urllib.request
from dataclasses import dataclass

TRIPS_URL = "https://gtfsrt.renfe.com/trip_updates.json"
POSITIONS_URL = "https://gtfsrt.renfe.com/vehicle_positions.json"
STATUSES = {"STOPPED_AT", "INCOMING_AT", "IN_TRANSIT_TO"}
_LABEL = re.compile(r"^([A-Za-z0-9]+)-(\d+)(?:-PLATF\.\(([^)]*)\))?$")
MAX_AGE = 300  # a feed older than this is frozen, not news
MAX_BYTES = 8 << 20  # Renfe's feeds are ~130 KB


@dataclass(frozen=True)
class Trip:
    delay: int | None  # seconds, negative = early; None if Renfe gives none
    cancelled: bool


@dataclass(frozen=True)
class Sighting:
    stop_id: str
    status: str  # STOPPED_AT | INCOMING_AT | IN_TRANSIT_TO
    platform: str | None  # only while INCOMING_AT / STOPPED_AT that stop
    at: int | None = None  # the vehicle's own timestamp


def _int(v) -> int | None:
    if isinstance(v, bool):
        return None
    if isinstance(v, (int, float)):
        return int(v)
    if isinstance(v, str):
        try:
            return int(v)
        except ValueError:
            return None
    return None


def _obj(x) -> dict:
    return x if isinstance(x, dict) else {}


def feed_time(j: dict) -> int | None:
    return _int(_obj(_obj(j).get("header")).get("timestamp"))


def parse_trips(j: dict) -> dict[str, Trip]:
    out: dict[str, Trip] = {}
    for e in _obj(j).get("entity") or []:
        tu = _obj(_obj(e).get("tripUpdate"))
        trip = _obj(tu.get("trip"))
        tid = trip.get("tripId")
        if not isinstance(tid, str):
            continue
        out[tid] = Trip(_int(tu.get("delay")), trip.get("scheduleRelationship") == "CANCELED")
    return out


def parse_positions(j: dict) -> dict[str, Sighting]:
    out: dict[str, Sighting] = {}
    for e in _obj(j).get("entity") or []:
        v = _obj(_obj(e).get("vehicle"))
        tid = _obj(v.get("trip")).get("tripId")
        stop, status = v.get("stopId"), v.get("currentStatus")
        if not (isinstance(tid, str) and isinstance(stop, str) and stop and stop != "00000"
                and status in STATUSES):
            continue
        platform = None
        label = _obj(v.get("vehicle")).get("label")
        if status in ("STOPPED_AT", "INCOMING_AT") and isinstance(label, str):
            m = _LABEL.match(label.strip())
            p = (m.group(3) or "").strip() if m else ""
            platform = p or None
        out[tid] = Sighting(stop, status, platform, _int(v.get("timestamp")))
    return out


class Feed:
    """One Renfe JSON feed with a conditional GET; keeps the last good answer. Thread-safe: the
    poller, the refresher and GET /train share it; a read within `min_interval` of the last one
    reuses it. Downloads are serialised by their own lock; `cached()` never waits for one."""

    def __init__(self, url: str, parse, timeout: float = 10.0, opener=urllib.request.urlopen,
                 min_interval: float = 20.0) -> None:
        self._lock = threading.Lock()  # held during a download
        self._min_interval = min_interval
        self._read_at: float | None = None
        self._url = url
        self._parse = parse
        self._timeout = timeout
        self._open = opener
        self._etag: str | None = None
        self._snap: tuple | None = None  # (parsed, header timestamp), replaced as one object

    def fetch(self, now: float):
        """The parsed feed, or None when it can't be read or is older than MAX_AGE."""
        with self._lock:
            if self._read_at is not None and 0 <= now - self._read_at < self._min_interval:
                return self._fresh(now)
            self._read_at = now
            self._fetch()
            return self._fresh(now)

    def cached(self, now: float, max_age: float = MAX_AGE):
        """(parsed, header timestamp) of the last good feed if at most `max_age` old, else None.
        Never downloads and never waits for a download (GET /live answers from memory)."""
        snap = self._snap
        if snap is None or snap[1] is None or now - snap[1] > max_age:
            return None
        return snap

    def _fetch(self) -> None:
        headers = {"User-Agent": "anden-api/1.0"}
        if self._etag and self._snap is not None:
            headers["If-None-Match"] = self._etag
        try:
            with self._open(urllib.request.Request(self._url, headers=headers), timeout=self._timeout) as r:
                body = r.read(MAX_BYTES + 1)
                if len(body) > MAX_BYTES:
                    raise ValueError("feed too large")
                etag = r.headers.get("ETag")
            j = json.loads(body.decode("utf-8"))
            self._snap, self._etag = (self._parse(j), feed_time(j)), etag
        except Exception:  # 304, offline, bad JSON: keep the last good one
            pass

    def _fresh(self, now: float):
        snap = self.cached(now)
        return None if snap is None else snap[0]
