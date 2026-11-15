"""Build a compact feed.json with Valencia Cercanías C1/C2 schedules from Renfe's GTFS."""

import csv
import math
import sys
from collections import defaultdict
from datetime import date, datetime, timedelta, timezone
from pathlib import Path

LINES = ("C1", "C2")
VALENCIA_PREFIX = "40T"
VALENCIA_NORD = "65000"
MAX_SECS = 48 * 3600
WEEKDAYS = ("monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday")


def _rows(path: Path):
    """Yield CSV rows as dicts with stripped keys and values."""
    with open(path, encoding="utf-8-sig", newline="") as f:
        reader = csv.reader(f)
        header = [h.strip() for h in next(reader)]
        for row in reader:
            if row:
                yield {k: v.strip() for k, v in zip(header, row)}


def _secs(hms: str) -> int:
    h, m, s = (int(x) for x in hms.split(":"))
    return h * 3600 + m * 60 + s


def _haversine(a, b) -> float:
    lat1, lon1, lat2, lon2 = map(math.radians, (a[0], a[1], b[0], b[1]))
    h = math.sin((lat2 - lat1) / 2) ** 2 + math.cos(lat1) * math.cos(lat2) * math.sin((lon2 - lon1) / 2) ** 2
    return 2 * 6371000 * math.asin(math.sqrt(h))


def _parse_date(s: str) -> date:
    return datetime.strptime(s, "%Y%m%d").date()


def _service_dates(gtfs_dir: Path, start: date, end: date) -> dict:
    """service_id -> set of dates within [start, end]."""
    dates = defaultdict(set)
    cal = gtfs_dir / "calendar.txt"
    if cal.exists():
        for r in _rows(cal):
            d = max(_parse_date(r["start_date"]), start)
            last = min(_parse_date(r["end_date"]), end)
            while d <= last:
                if r[WEEKDAYS[d.weekday()]] == "1":
                    dates[r["service_id"]].add(d)
                d += timedelta(days=1)
    cd = gtfs_dir / "calendar_dates.txt"
    if cd.exists():
        for r in _rows(cd):
            d = _parse_date(r["date"])
            if start <= d <= end:
                if r["exception_type"] == "1":
                    dates[r["service_id"]].add(d)
                elif r["exception_type"] == "2":
                    dates[r["service_id"]].discard(d)
    return dates


def build_feed(gtfs_dir: Path, today: date, days: int = 7) -> dict:
    gtfs_dir = Path(gtfs_dir)
    valid_from = today - timedelta(days=1)
    valid_to = today + timedelta(days=days)

    route_line = {
        r["route_id"]: r["route_short_name"]
        for r in _rows(gtfs_dir / "routes.txt")
        if r["route_id"].startswith(VALENCIA_PREFIX) and r["route_short_name"] in LINES
    }
    service_dates = _service_dates(gtfs_dir, valid_from, valid_to)

    trips = {}
    for r in _rows(gtfs_dir / "trips.txt"):
        line = route_line.get(r["route_id"])
        if line is None:
            continue
        dates = service_dates.get(r["service_id"])
        if not dates:
            continue
        if r["trip_id"] in trips:
            print(f"warning: duplicate trip_id {r['trip_id']}", file=sys.stderr)
        trips[r["trip_id"]] = {"line": line, "dates": dates}

    times = defaultdict(list)
    for r in _rows(gtfs_dir / "stop_times.txt"):
        if r["trip_id"] in trips:
            t = r.get("departure_time") or r.get("arrival_time")
            if not t:
                continue  # non-timepoint stop: no published time, not shown
            times[r["trip_id"]].append((int(r["stop_sequence"]), r["stop_id"], _secs(t)))

    stops_all = {r["stop_id"]: r for r in _rows(gtfs_dir / "stops.txt")}

    def coords(stop_id):
        s = stops_all[stop_id]
        return float(s["stop_lat"]), float(s["stop_lon"])

    nord = coords(VALENCIA_NORD)
    multi_date = 0
    out_trips = []
    stop_lines = defaultdict(set)
    for trip_id, info in trips.items():
        seq = sorted(times.get(trip_id, []))
        if len(seq) < 2:
            continue
        unknown = [sid for _, sid, _ in seq if sid not in stops_all]
        if unknown:
            print(f"warning: dropping {trip_id}: unknown stops {unknown}", file=sys.stderr)
            continue
        if any(secs >= MAX_SECS for _, _, secs in seq):
            print(f"warning: dropping {trip_id}: time >= 48:00:00", file=sys.stderr)
            continue
        if len(info["dates"]) > 1:
            multi_date += 1
        first, last = seq[0][1], seq[-1][1]
        direction = "in" if _haversine(coords(last), nord) < _haversine(coords(first), nord) else "out"
        for _, stop_id, _ in seq:
            stop_lines[stop_id].add(info["line"])
        out_trips.append({
            "id": trip_id,
            "line": info["line"],
            "dir": direction,
            "dest": stops_all[last]["stop_name"],
            "dates": sorted(d.isoformat() for d in info["dates"]),
            "times": [[stop_id, secs] for _, stop_id, secs in seq],
        })

    if multi_date:
        print(f"warning: {multi_date} trip_ids run on more than one date", file=sys.stderr)

    out_stops = [
        {
            "id": sid,
            "name": stops_all[sid]["stop_name"],
            "lat": float(stops_all[sid]["stop_lat"]),
            "lon": float(stops_all[sid]["stop_lon"]),
            "lines": sorted(stop_lines[sid]),
        }
        for sid in sorted(stop_lines)
    ]

    return {
        "version": 1,
        "generated_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "valid_from": valid_from.isoformat(),
        "valid_to": valid_to.isoformat(),
        "stops": out_stops,
        "trips": sorted(out_trips, key=lambda t: t["id"]),
    }
