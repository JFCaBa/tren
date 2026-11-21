"""Followed trains, in memory only, and the poller that watches them on Renfe's feeds and pushes
alerts and Live Activity updates. Same design as What Platform's api/platform_api/follow.py."""
from __future__ import annotations

import dataclasses
import sys
import threading
import time
from dataclasses import dataclass
from typing import Callable, TextIO

from .live import changes, content_state, where_text

MAX_DURATION = 3 * 3600
AFTER_DEPARTURE = 120  # the follow ends this long after the expected departure
CANCELLED_LINGER = 120
STALE_AFTER = 600
STALE_UNKNOWN = 3600
DISMISS_GONE = 600  # an ended Live Activity stays this long on the lock screen once the train left
DISMISS_NOW = 0
END_ATTEMPTS = 3

_UPDATABLE = {"last", "alerted", "cancelled_at", "activity", "state"}
_ACTIVITY_FIELDS = {"activity", "state"}
_SAME_KEYS = ("tripId", "stopId", "scheduled")


def same_train(a: dict, b: dict) -> bool:
    return all(a.get(k) == b.get(k) for k in _SAME_KEYS)


@dataclass
class Follow:
    token: str
    env: str
    train: dict  # tripId, stopId, scheduled (epoch s), title, usual, stops [[id, name], ...]
    started: float
    gen: int
    last: dict | None = None  # last reading {delay, cancelled, platform}
    alerted: dict | None = None  # the reading alerts were last computed against (slow drifts add up)
    cancelled_at: float | None = None
    activity: str | None = None
    state: dict | None = None  # Live Activity state last pushed
    act_gen: int = 0


@dataclass
class Ended:
    activity: str
    env: str
    state: dict | None
    dismiss_after: int
    attempts: int = 0


def _copy(f: Follow) -> Follow:
    return dataclasses.replace(f, train=dict(f.train), last=dict(f.last) if f.last else None,
                               state=dict(f.state) if f.state else None)


class FollowStore:
    """Thread-safe; keyed by device token, one train per device."""

    def __init__(self, max_follows: int = 500) -> None:
        self._max = max_follows
        self._lock = threading.Lock()
        self._follows: dict[str, Follow] = {}
        self._gen = 0
        self._ended: list[Ended] = []

    def _end(self, f: Follow, dismiss_after: int) -> None:
        if f.activity:
            self._ended.append(Ended(f.activity, f.env, f.state, dismiss_after if f.state else DISMISS_NOW))

    def upsert(self, token: str, env: str, train: dict, started: float, activity: str | None = None) -> str:
        """"ok" or "busy". The same train keeps its readings and start (an app re-sync)."""
        with self._lock:
            cur = self._follows.get(token)
            if cur is not None and same_train(cur.train, train):
                if activity and activity != cur.activity:
                    if cur.activity:
                        self._end(cur, DISMISS_NOW)  # before env changes: the old one's own env
                    cur.act_gen += 1
                    cur.activity, cur.state = activity, None
                cur.env = env
                return "ok"
            if cur is None and len(self._follows) >= self._max:
                # Full (tokens are not verified up front): the oldest follow makes room.
                oldest = min(self._follows.values(), key=lambda f: f.started)
                del self._follows[oldest.token]
                self._end(oldest, DISMISS_NOW)
            if cur is not None and cur.activity != activity:
                self._end(cur, DISMISS_NOW)
            self._gen += 1
            self._follows[token] = Follow(token, env, dict(train), started, self._gen, activity=activity)
            return "ok"

    def remove(self, token: str, gen: int | None = None, dismiss_after: int = DISMISS_NOW) -> None:
        with self._lock:
            cur = self._follows.get(token)
            if cur is not None and (gen is None or cur.gen == gen):
                del self._follows[token]
                self._end(cur, dismiss_after)

    def update(self, token: str, gen: int, act_gen: int | None = None, **fields) -> bool:
        bad = set(fields) - _UPDATABLE
        if bad:
            raise TypeError(f"cannot update fields: {sorted(bad)}")
        with self._lock:
            cur = self._follows.get(token)
            if cur is None or cur.gen != gen:
                return False
            if act_gen is not None and cur.act_gen != act_gen:
                fields = {k: v for k, v in fields.items() if k not in _ACTIVITY_FIELDS}
            for k, v in fields.items():
                setattr(cur, k, v)
            return True

    def is_current(self, token: str, gen: int) -> bool:
        with self._lock:
            cur = self._follows.get(token)
            return cur is not None and cur.gen == gen

    def all(self) -> list[Follow]:
        with self._lock:
            return [_copy(f) for f in self._follows.values()]

    def take_ended(self) -> list[Ended]:
        with self._lock:
            live = {f.activity for f in self._follows.values() if f.activity}
            out, self._ended = [e for e in self._ended if e.activity not in live], []
            return out

    def retry_end(self, e: Ended) -> None:
        with self._lock:
            if e.attempts + 1 < END_ATTEMPTS:
                self._ended.append(dataclasses.replace(e, attempts=e.attempts + 1))

    def __len__(self) -> int:
        with self._lock:
            return len(self._follows)


def _carry_platform(alerted: dict, reading: dict) -> dict:
    """The alert baseline keeps its delay (so small steps add up) but follows the platform and
    cancellation, which are alerted on any change."""
    return {"delay": alerted.get("delay"), "cancelled": reading["cancelled"], "platform": reading["platform"]}


def _before_us(f: Follow, pos) -> bool:
    """Renfe places the train on one of its stops up to ours (and not standing at ours)."""
    if pos is None:
        return False
    ids = [s[0] for s in f.train.get("stops") or []]
    if pos.stop_id not in ids:
        return False
    return ids.index(pos.stop_id) < len(ids) - 1 or pos.status != "STOPPED_AT"


def _departs(f: Follow, delay: int | None) -> int:
    return int(f.train["scheduled"]) + (delay or 0)


class Poller:
    """One read of each Renfe feed per tick for every follow. Pushes are sent outside the store
    lock and results written back by generation, so a DELETE or a new train wins."""

    def __init__(self, store: FollowStore, trips, positions, push,
                 clock: Callable[[], float] = time.time, log: TextIO = sys.stderr) -> None:
        self._store = store
        self._trips = trips  # .fetch(now) -> dict[tripId, Trip] | None
        self._positions = positions  # .fetch(now) -> dict[tripId, Sighting] | None
        self._push = push
        self._clock = clock
        self._log = log

    def tick(self) -> None:
        now = self._clock()
        for f in self._store.all():
            if now - f.started >= MAX_DURATION:
                self._store.remove(f.token, f.gen, DISMISS_NOW)
        self._send_ends(now)
        follows = self._store.all()
        if not follows:
            return
        trips = self._trips.fetch(now)
        positions = self._positions.fetch(now)
        for f in follows:
            try:
                self._check(f, trips, positions, now)
            except Exception as e:  # one bad follow never stops the tick
                self._note(e)
        self._send_ends(now)

    def _reading(self, f: Follow, trips, positions) -> tuple[dict, object]:
        last = f.last or {"delay": None, "cancelled": False, "platform": None}
        tid, stop = f.train["tripId"], f.train["stopId"]
        t = trips.get(tid) if trips is not None else None
        if t is None:  # feed down, or Renfe dropped the trip for a while: keep what we knew
            delay, cancelled = last["delay"], last["cancelled"]
        else:
            delay, cancelled = t.delay, t.cancelled
        pos = positions.get(tid) if positions is not None else None
        platform = last.get("platform")  # once announced, it stays
        if pos is not None and pos.stop_id == stop and pos.platform:
            platform = pos.platform
        return {"delay": delay, "cancelled": cancelled, "platform": platform}, pos

    def _check(self, f: Follow, trips, positions, now: float) -> None:
        if not self._store.is_current(f.token, f.gen):
            return
        if trips is None and positions is None:
            # Renfe unreachable: no news, but a cancelled train still ends on time.
            if f.cancelled_at is not None and now - f.cancelled_at >= CANCELLED_LINGER:
                self._store.remove(f.token, f.gen, DISMISS_GONE)
            return
        reading, pos = self._reading(f, trips, positions)
        cancelled_at = (f.cancelled_at or now) if reading["cancelled"] else None
        texts = changes(f.alerted if f.last is not None else None, reading)
        alerted = reading if texts or f.alerted is None else _carry_platform(f.alerted, reading)
        if texts:
            try:
                result = self._push.send(f.token, f.env, f.train["title"], "\n".join(texts))
            except Exception as e:
                self._note(e)
                result = "error"
            if result == "gone":
                self._store.remove(f.token, f.gen)
                return
        extra: dict = {"alerted": alerted}
        if f.activity and self._store.is_current(f.token, f.gen):
            try:
                extra.update(self._activity(f, reading, pos, now))
            except Exception as e:  # the Live Activity never stops the alerts
                self._note(e)
        self._store.update(f.token, f.gen, f.act_gen, last=reading, cancelled_at=cancelled_at, **extra)
        if cancelled_at is not None and now - cancelled_at >= CANCELLED_LINGER:
            self._store.remove(f.token, f.gen, DISMISS_GONE)
        elif (not reading["cancelled"] and positions is not None
              and now >= _departs(f, reading["delay"]) + AFTER_DEPARTURE and not _before_us(f, pos)):
            # Renfe often publishes a delay late: a train it still places on our stops is not gone.
            self._store.remove(f.token, f.gen, DISMISS_GONE)

    def _activity(self, f: Follow, reading: dict, pos, now: float) -> dict:
        stops = [(s[0], s[1]) for s in f.train.get("stops") or []]
        state = content_state(int(f.train["scheduled"]), f.train.get("usual"), reading,
                              where_text(stops, f.train["stopId"], pos))
        if state == f.state:
            return {}
        old = f.state
        urgent = old is not None and (state["platform"] != old.get("platform")
                                      or state["cancelled"] != old.get("cancelled"))
        stale = state["departs"] + STALE_AFTER if state["departs"] else int(now) + STALE_UNKNOWN
        result = self._push.send_activity(f.activity, f.env, state, priority=10 if urgent else 5, stale=stale)
        if result == "gone":
            return {"activity": None, "state": None}
        return {"state": state} if result == "ok" else {}  # an error is retried next tick

    def _send_ends(self, now: float) -> None:
        for e in self._store.take_ended():
            state = e.state or {"departs": None, "status": "", "platform": None, "usual": False,
                                "where": None, "cancelled": False}
            try:
                result = self._push.send_activity(e.activity, e.env, state, event="end", priority=10,
                                                  stale=int(now), dismissal=int(now) + e.dismiss_after)
            except Exception as ex:
                self._note(ex)
                result = "error"
            if result == "error":
                self._store.retry_end(e)

    def end_all(self) -> None:
        """On shutdown: end every Live Activity, so none stays frozen on a lock screen."""
        for f in self._store.all():
            self._store.remove(f.token, f.gen, DISMISS_NOW)
        self._send_ends(self._clock())

    def run(self, stop: threading.Event, every: float = 30.0) -> None:
        while not stop.is_set():
            began = self._clock()
            try:
                self.tick()
            except Exception as e:
                self._note(e)
            stop.wait(max(0.0, min(every, every - (self._clock() - began))))

    def _note(self, e: BaseException) -> None:
        """Exception type only: messages may carry tokens."""
        try:
            self._log.write(f"follow poller: {type(e).__name__}\n")
        except Exception:
            pass
