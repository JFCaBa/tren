"""Build a compact feed.json with Valencia Cercanías C1/C2 schedules from Renfe's GTFS."""

import argparse
import csv
import json
import math
import sys
import tempfile
import time
import urllib.request
import zipfile
from collections import defaultdict
from datetime import date, datetime, timedelta, timezone
from pathlib import Path
from zoneinfo import ZoneInfo

LINES = ("C1", "C2")
VALENCIA_PREFIX = "40T"
VALENCIA_NORD = "65000"
MAX_SECS = 48 * 3600
GTFS_URL = "https://ssl.renfe.com/ftransit/Fichero_CER_FOMENTO/fomento_transit.zip"
MADRID = ZoneInfo("Europe/Madrid")
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


NUCLEO_NAMES = {
    "10": "Madrid",
    "20": "Asturias",
    "30": "Sevilla",
    "31": "Cádiz",
    "32": "Málaga",
    "40": "Valencia",
    "41": "Murcia/Alicante",
    "45": "Murcia/Cartagena",
    "46": "Ferrol",
    "47": "León",
    "51": "Rodalies de Catalunya",
    "60": "Bilbao",
    "61": "San Sebastián",
    "62": "Santander",
    "70": "Zaragoza",
}
GREY = "9E9E9E"
_HEX = set("0123456789abcdefABCDEF")


def _color(c: str) -> str:
    return c.upper() if len(c) == 6 and set(c) <= _HEX else GREY


def build_nucleos(gtfs_dir: Path, today: date, days: int = 7) -> dict:
    """One v2 feed per Cercanías núcleo (route_id prefix), from a single pass over stop_times."""
    gtfs_dir = Path(gtfs_dir)
    valid_from = today - timedelta(days=1)
    valid_to = today + timedelta(days=days)
    generated_at = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    routes = {}  # route_id -> (nucleo, line, color)
    for r in _rows(gtfs_dir / "routes.txt"):
        nucleo = r["route_id"][:2]
        is_rail = r.get("route_type", "2") in ("2", "")  # 3 = bus (replacement services)
        if nucleo in NUCLEO_NAMES and is_rail and r["route_short_name"] and r["route_short_name"] != "BUS":
            routes[r["route_id"]] = (nucleo, r["route_short_name"], _color(r.get("route_color", "")))
    # One color per line: a real color beats grey; ties broken alphabetically for determinism.
    line_colors = {}
    for nucleo, line, color in routes.values():
        best = line_colors.get((nucleo, line))
        if best is None or (best == GREY and color != GREY) or (color != GREY and color < best):
            line_colors[(nucleo, line)] = color
    service_dates = _service_dates(gtfs_dir, valid_from, valid_to)

    trips = {}
    for r in _rows(gtfs_dir / "trips.txt"):
        route = routes.get(r["route_id"])
        dates = service_dates.get(r["service_id"])
        if route and dates:
            trips[r["trip_id"]] = (route, dates)

    times = defaultdict(list)
    for r in _rows(gtfs_dir / "stop_times.txt"):
        if r["trip_id"] in trips:
            t = r.get("departure_time") or r.get("arrival_time")
            if t:
                times[r["trip_id"]].append((int(r["stop_sequence"]), r["stop_id"], _secs(t)))

    stops_all = {r["stop_id"]: r for r in _rows(gtfs_dir / "stops.txt")}
    feeds = {}
    multi_date = 0
    for trip_id, ((nucleo, line, color), dates) in trips.items():
        seq = sorted(times.get(trip_id, []))
        if len(seq) < 2:
            continue
        if any(sid not in stops_all for _, sid, _ in seq):
            print(f"warning: dropping {trip_id}: unknown stops", file=sys.stderr)
            continue
        if any(secs >= MAX_SECS for _, _, secs in seq):
            print(f"warning: dropping {trip_id}: time >= 48:00:00", file=sys.stderr)
            continue
        if len(dates) > 1:
            multi_date += 1
        f = feeds.setdefault(nucleo, {"lines": {}, "stops": set(), "trips": []})
        f["lines"][line] = line_colors[(nucleo, line)]
        f["stops"].update(sid for _, sid, _ in seq)
        f["trips"].append({
            "id": trip_id,
            "line": line,
            "dest": stops_all[seq[-1][1]]["stop_name"],
            "dates": sorted(d.isoformat() for d in dates),
            "times": [[sid, secs] for _, sid, secs in seq],
        })
    if multi_date:
        print(f"warning: {multi_date} trip_ids run on more than one date", file=sys.stderr)

    return {
        nucleo: {
            "version": 2,
            "nucleo": nucleo,
            "name": NUCLEO_NAMES[nucleo],
            "generated_at": generated_at,
            "valid_from": valid_from.isoformat(),
            "valid_to": valid_to.isoformat(),
            "lines": dict(sorted(f["lines"].items())),
            "stops": [
                {
                    "id": sid,
                    "name": stops_all[sid]["stop_name"],
                    "lat": float(stops_all[sid]["stop_lat"]),
                    "lon": float(stops_all[sid]["stop_lon"]),
                }
                for sid in sorted(f["stops"])
            ],
            "trips": sorted(f["trips"], key=lambda t: t["id"]),
        }
        for nucleo, f in sorted(feeds.items())
    }


def build_index(feeds: dict) -> dict:
    """Núcleos and every station once, with the núcleos whose trains call there."""
    stops = {}
    for nucleo, feed in sorted(feeds.items()):
        for s in feed["stops"]:
            entry = stops.setdefault(s["id"], {**s, "nucleos": []})
            entry["nucleos"].append(nucleo)
    return {
        "version": 2,
        "generated_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "nucleos": [
            {"id": n, "name": f["name"], "feed": f"feeds/{n}.json"} for n, f in sorted(feeds.items())
        ],
        "stops": [stops[k] for k in sorted(stops)],
    }


def validate_feed(feed: dict, today: date, min_stops: int = 20) -> list:
    """Return a list of problems; an empty list means the feed can be published."""
    errors = []
    lines = {t["line"] for t in feed["trips"]}
    for line in LINES:
        if line not in lines:
            errors.append(f"no trips for line {line}")
    if len(feed["stops"]) < min_stops:
        errors.append(f"only {len(feed['stops'])} stops (< {min_stops})")
    for line in LINES:
        dates = {d for t in feed["trips"] if t["line"] == line for d in t["dates"]}
        for d in (today, today + timedelta(days=1)):
            if d.isoformat() not in dates:
                errors.append(f"no {line} trips on {d.isoformat()}")
    return errors


def _download(dest: Path, attempts: int = 3) -> None:
    req = urllib.request.Request(GTFS_URL, headers={"User-Agent": "proximotren-pipeline"})
    for attempt in range(1, attempts + 1):
        try:
            with urllib.request.urlopen(req, timeout=120) as resp, open(dest, "wb") as f:
                while chunk := resp.read(1 << 20):
                    f.write(chunk)
            return
        except OSError as e:  # URLError/HTTPError/timeouts are OSError subclasses
            print(f"download attempt {attempt} failed: {e}", file=sys.stderr)
            if attempt == attempts:
                raise
            time.sleep(30 * attempt)


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", required=True, type=Path, help="output directory for feed.json")
    parser.add_argument("--zip", type=Path, help="use a local GTFS zip instead of downloading")
    parser.add_argument("--date", type=date.fromisoformat, help="service date YYYY-MM-DD (default: today in Madrid)")
    parser.add_argument("--min-stops", type=int, default=20)
    args = parser.parse_args(argv)

    today = args.date or datetime.now(MADRID).date()
    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        zpath = args.zip
        if zpath is None:
            zpath = tmp / "gtfs.zip"
            _download(zpath)
        with zipfile.ZipFile(zpath) as z:
            z.extractall(tmp / "gtfs")
        feed = build_feed(tmp / "gtfs", today)

    errors = validate_feed(feed, today, min_stops=args.min_stops)
    if errors:
        for e in errors:
            print(f"error: {e}", file=sys.stderr)
        return 1
    args.out.mkdir(parents=True, exist_ok=True)
    tmp_path = args.out / "feed.json.tmp"
    tmp_path.write_text(json.dumps(feed, ensure_ascii=False, separators=(",", ":")), encoding="utf-8")
    tmp_path.replace(args.out / "feed.json")
    print(f"wrote {args.out / 'feed.json'}: {len(feed['stops'])} stops, {len(feed['trips'])} trips")
    return 0


if __name__ == "__main__":
    sys.exit(main())
