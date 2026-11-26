"""The next trains from one station: the app's computeBoard (app/lib/domain/board.dart) in Python,
for the website's GET /board/<stop>. Same rules, so the web and the app show the same trains:
service days and civil times are Renfe's (Europe/Madrid), GTFS times count from "noon minus 12 h"
of the service day (right on daylight-saving change days), real time only for a trip id that runs
on one day. Filters (destinations, via) are the app's only."""
from __future__ import annotations

import re
from datetime import date, datetime, timedelta
from zoneinfo import ZoneInfo

from .renfe import Trip

MADRID = ZoneInfo("Europe/Madrid")
RT_MAX_AGE = 120  # s
FEED_MAX_AGE = 3 * 86400  # s
GRACE_AFTER_DEPARTURE = 60  # s
LIVE_PLATFORM_WITHIN_MINUTES = 15
GREY = "#9E9E9E"
_TRIP_ID = re.compile(r"^[0-9A-Z]{5}\d{5}[A-Za-z0-9]+$")


def train_number(trip_id: str) -> str | None:
    return trip_id[5:10] if _TRIP_ID.match(trip_id) else None


def _service_time(day: date, secs: int) -> float:
    return datetime(day.year, day.month, day.day, 12, tzinfo=MADRID).timestamp() - 43200 + secs


def _iso(ts: float) -> str:
    return datetime.fromtimestamp(ts, MADRID).isoformat()


def _epoch(s: str) -> float:
    return datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp()


def compute_board(feeds: list[dict], stop_id: str, now: float, rt: dict[str, Trip] | None,
                  rt_ts: float | None, live_platforms: dict[str, str], limit: int = 8) -> dict:
    rt_fresh = rt is not None and rt_ts is not None and now - rt_ts < RT_MAX_AGE
    today = datetime.fromtimestamp(now, MADRID).date()
    days = [today + timedelta(days=o) for o in (-1, 0, 1)]

    candidates = []  # light first; stops only for the ones shown
    for f in feeds:
        for trip in f["trips"]:
            times = trip["times"]
            idx = next((i for i, t in enumerate(times) if t[0] == stop_id), -1)
            if idx < 0 or idx == len(times) - 1:
                continue  # not served, or terminates here
            dates = trip["dates"]
            by_id = len(dates) == 1
            rt_trip = rt.get(trip["id"]) if rt_fresh and by_id else None
            cancelled = rt_trip is not None and rt_trip.cancelled
            delay = None if rt_trip is None or cancelled else rt_trip.delay
            live = delay is not None or cancelled
            for day in days:
                if day.isoformat() not in dates:
                    continue
                scheduled = _service_time(day, times[idx][1])
                estimated = scheduled + (delay or 0)
                if estimated < now - GRACE_AFTER_DEPARTURE:
                    continue
                candidates.append((estimated, f, trip, idx, day, scheduled, delay, live, cancelled))

    candidates.sort(key=lambda c: c[0])
    departures = []
    for estimated, f, trip, idx, day, scheduled, delay, live, cancelled in candidates[:limit]:
        names = {s["id"]: s["name"] for s in f["stops"]}
        minutes = max(0, int(estimated - now) // 60)
        train = train_number(trip["id"])
        colour = f.get("lines", {}).get(trip["line"])
        departures.append({
            "tripId": trip["id"],
            "line": trip["line"],
            "color": f"#{colour}" if colour else GREY,
            "dest": trip["dest"],
            "scheduled": _iso(scheduled),
            "estimated": _iso(estimated),
            "delay": delay,
            "live": live,
            "cancelled": cancelled,
            "minutes": minutes,
            "usualPlatform": (f.get("platforms") or {}).get(stop_id, {}).get(train) if train else None,
            # Renfe only reports a platform while the train arrives; a trip id that repeats on
            # other days must not lend it to tomorrow's run.
            "livePlatform": live_platforms.get(trip["id"]) if minutes <= LIVE_PLATFORM_WITHIN_MINUTES else None,
            "stops": [{"id": sid, "name": names.get(sid, sid), "time": _iso(_service_time(day, secs) + (delay or 0))}
                      for sid, secs in trip["times"][idx:]],
        })
    today_s = today.isoformat()
    return {
        "rtStale": not rt_fresh,
        "feedStale": any(now - _epoch(f["generated_at"]) > FEED_MAX_AGE for f in feeds),
        "feedCoversToday": bool(feeds) and all(f["valid_from"] <= today_s <= f["valid_to"] for f in feeds),
        "hasMore": len(candidates) > limit,
        "departures": departures,
    }
