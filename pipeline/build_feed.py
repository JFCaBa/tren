"""Build a compact feed.json with Valencia Cercanías C1/C2 schedules from Renfe's GTFS."""

import argparse
import csv
import json
import math
import sys
import tempfile
import time
import urllib.error
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
    bad_trips = set()
    for r in _rows(gtfs_dir / "stop_times.txt"):
        if r["trip_id"] in trips:
            t = r.get("departure_time") or r.get("arrival_time")
            if t:
                try:
                    times[r["trip_id"]].append((int(r["stop_sequence"]), r["stop_id"], _secs(t)))
                except ValueError:
                    bad_trips.add(r["trip_id"])  # one bad row drops its trip, not the whole run

    def usable(stop):
        try:
            float(stop["stop_lat"]), float(stop["stop_lon"])
            return True
        except (KeyError, ValueError):
            return False

    stops_all = {r["stop_id"]: r for r in _rows(gtfs_dir / "stops.txt") if usable(r)}
    feeds = {}
    multi_date = 0
    for trip_id, ((nucleo, line, color), dates) in trips.items():
        seq = sorted(times.get(trip_id, []))
        if len(seq) < 2:
            continue
        if trip_id in bad_trips:
            print(f"warning: dropping {trip_id}: invalid time", file=sys.stderr)
            continue
        if any(sid not in stops_all for _, sid, _ in seq):
            print(f"warning: dropping {trip_id}: unknown stops or invalid coordinates", file=sys.stderr)
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


PAGES_BASE = "https://jfcaba.github.io/tren"


def validate_nucleo(feed: dict, today: date, previous) -> list:
    """Problems that make a núcleo feed unpublishable; compares with the previous publication."""
    errors = []
    dates = {d for t in feed["trips"] for d in t["dates"]}
    for d in (today, today + timedelta(days=1)):
        if d.isoformat() not in dates:
            errors.append(f"no trips on {d.isoformat()}")
    if previous:
        if len(feed["stops"]) < 0.5 * len(previous.get("stops", [])):
            errors.append(f"only {len(feed['stops'])} stops vs {len(previous.get('stops', []))} before")
        if len(feed["trips"]) < 0.5 * len(previous.get("trips", [])):
            errors.append(f"only {len(feed['trips'])} trips vs {len(previous.get('trips', []))} before")
    return errors


class PreviousUnreachable(Exception):
    """The previous publication could not be read (not the same as "it does not exist")."""


def _fetch_previous(base: str, path: str, attempts: int = 2):
    """Raw bytes of a previously published file, None if it does not exist (404 / missing file).

    Any other failure raises PreviousUnreachable: treating an outage as "no previous" could drop
    a whole núcleo from the index or skip the shrink check.
    """
    for attempt in range(1, attempts + 1):
        try:
            req = urllib.request.Request(f"{base}/{path}", headers={"User-Agent": "proximotren-pipeline"})
            with urllib.request.urlopen(req, timeout=60) as resp:
                return resp.read()
        except urllib.error.HTTPError as e:
            if e.code == 404:
                return None
            err = e
        except urllib.error.URLError as e:
            if isinstance(e.reason, FileNotFoundError):
                return None
            err = e
        except (OSError, ValueError) as e:  # ValueError: malformed base URL
            err = e
        if attempt < attempts:
            time.sleep(3)
    raise PreviousUnreachable(f"{path}: {err}")


def _is_feed_v2(obj) -> bool:
    """A previous publication is only trusted if it looks like a v2 núcleo feed."""
    return (
        isinstance(obj, dict)
        and obj.get("version") == 2
        and isinstance(obj.get("name"), str)
        and isinstance(obj.get("valid_to"), str)
        and isinstance(obj.get("stops"), list)
        and isinstance(obj.get("trips"), list)
    )


def _write_atomic(path: Path, data: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_bytes(data)
    tmp.replace(path)


def _dump(obj) -> bytes:
    return json.dumps(obj, ensure_ascii=False, separators=(",", ":")).encode("utf-8")


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", required=True, type=Path, help="output directory (index.json, feeds/, feed.json)")
    parser.add_argument("--zip", type=Path, help="use a local GTFS zip instead of downloading")
    parser.add_argument("--date", type=date.fromisoformat, help="service date YYYY-MM-DD (default: today in Madrid)")
    parser.add_argument("--min-stops", type=int, default=20, help="minimum stops for the v1 Valencia feed")
    parser.add_argument("--previous-base", default=PAGES_BASE, help="where the previous publication lives")
    args = parser.parse_args(argv)
    base = args.previous_base.rstrip("/")

    today = args.date or datetime.now(MADRID).date()
    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        zpath = args.zip
        if zpath is None:
            zpath = tmp / "gtfs.zip"
            _download(zpath)
        with zipfile.ZipFile(zpath) as z:
            z.extractall(tmp / "gtfs")
        feeds = build_nucleos(tmp / "gtfs", today)
        try:
            v1 = build_feed(tmp / "gtfs", today)
            v1_errors = None
        except (KeyError, ValueError) as e:  # e.g. Valencia Nord missing: v1 is legacy, never fatal
            v1, v1_errors = None, [f"build failed: {e!r}"]

    try:
        prev_ids = set()
        raw_index = _fetch_previous(base, "index.json")
        if raw_index:
            try:
                prev_ids = {n["id"] for n in json.loads(raw_index)["nucleos"]}
            except (ValueError, KeyError, TypeError) as e:
                # Can't know which núcleos existed: same risk as an outage.
                raise PreviousUnreachable(f"index.json unreadable: {e!r}")

        published = {}  # nucleo -> (raw bytes, parsed feed)
        fresh = 0
        for nucleo in sorted(set(feeds) | prev_ids):
            raw_prev = _fetch_previous(base, f"feeds/{nucleo}.json")
            prev = None
            if raw_prev:
                try:
                    prev = json.loads(raw_prev)
                except ValueError:
                    prev = None
                if not _is_feed_v2(prev):
                    print(f"warning: previous feeds/{nucleo}.json is not a v2 feed; ignored", file=sys.stderr)
                    prev = None
            new = feeds.get(nucleo)
            errors = validate_nucleo(new, today, prev) if new else ["missing from GTFS"]
            if not errors:
                published[nucleo] = (_dump(new), new)
                fresh += 1
            elif prev and prev["valid_to"] >= today.isoformat():
                print(f"warning: nucleo {nucleo} kept previous: {'; '.join(errors)}", file=sys.stderr)
                published[nucleo] = (raw_prev, prev)
            else:
                print(f"warning: nucleo {nucleo} omitted (no usable previous): {'; '.join(errors)}", file=sys.stderr)
    except PreviousUnreachable as e:
        print(f"error: previous publication unreachable ({e}); not publishing", file=sys.stderr)
        return 1

    if fresh == 0:
        # Nothing new validated: fail loudly so CI alerts; Pages keeps serving the last deploy.
        print("error: no nucleo passed validation", file=sys.stderr)
        return 1

    # Decide the legacy v1 before writing anything, so a failure never leaves out/ half written.
    if v1_errors is None:
        v1_errors = validate_feed(v1, today, min_stops=args.min_stops)
    v1_raw = None
    if not v1_errors:
        v1_raw = _dump(v1)
    else:
        try:
            v1_raw = _fetch_previous(base, "feed.json")
        except PreviousUnreachable as e:
            print(f"error: previous publication unreachable ({e}); not publishing", file=sys.stderr)
            return 1
        if v1_raw:
            print(f"warning: feed.json kept previous: {'; '.join(v1_errors)}", file=sys.stderr)
        else:
            print(f"warning: feed.json omitted (no previous): {'; '.join(v1_errors)}", file=sys.stderr)

    for nucleo, (raw, _) in published.items():
        _write_atomic(args.out / "feeds" / f"{nucleo}.json", raw)
    index = build_index({n: f for n, (_, f) in published.items()})
    _write_atomic(args.out / "index.json", _dump(index))

    if v1_raw:
        _write_atomic(args.out / "feed.json", v1_raw)

    print(f"wrote {len(published)} nucleos, {len(index['stops'])} stations to {args.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
