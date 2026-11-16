"""Record which platform (vía) each Cercanías train uses at each station.

Renfe's GTFS-RT vehicle positions carry the platform in the vehicle label ("C1-23525-PLATF.(6)")
for the stop the train is arriving at or standing in. Every run adds those sightings to a small
JSON state, keyed by "<stop_id>|<train number>", keeping the last few dated observations; the
nightly build turns them into a "usual platform" per train.
"""

import re
from datetime import date, datetime, timedelta, timezone

MAX_OBS = 10  # observations kept per stop and train
KEEP_DAYS = 45  # keys with nothing newer are dropped
MAX_FEED_AGE = timedelta(minutes=15)  # older responses are a frozen feed, not news
STATUSES = {"INCOMING_AT", "STOPPED_AT"}  # the platform belongs to stopId only then

_LABEL = re.compile(r"([A-Za-z0-9]+)-(\d+)(?:-PLATF\.\(([^)]*)\))?")
_TRIP = re.compile(r"[0-9A-Z]{5}\d{5}[A-Za-z0-9]+")
_DATE = re.compile(r"\d{4}-\d{2}-\d{2}")


def parse_label(label: str):
    """(line, train, platform or None), or None if the label is not Renfe's format."""
    m = _LABEL.fullmatch((label or "").strip())
    if not m:
        return None
    platform = (m.group(3) or "").strip() or None
    return m.group(1), m.group(2), platform


def train_number(trip_id: str):
    """Train number inside a Renfe trip_id ("3019L23525C1" -> "23525"); None for other shapes."""
    return trip_id[5:10] if _TRIP.fullmatch(trip_id or "") else None


def observations(vp: dict, now: datetime) -> list:
    """(key, platform) sightings in a vehicle_positions response; [] if it is stale."""
    if now.tzinfo is None:
        now = now.replace(tzinfo=timezone.utc)
    limit = MAX_FEED_AGE.total_seconds()

    def fresh(ts) -> bool:
        try:
            return abs(now.timestamp() - int(ts)) <= limit
        except (TypeError, ValueError):
            return False

    if not isinstance(vp, dict) or not fresh((vp.get("header") or {}).get("timestamp")):
        return []
    out = []
    for e in vp.get("entity") or []:
        v = (e or {}).get("vehicle") or {}
        stop = v.get("stopId")
        if v.get("currentStatus") not in STATUSES or not stop or stop == "00000":
            continue
        if "timestamp" in v and not fresh(v["timestamp"]):
            continue  # a vehicle frozen in an otherwise fresh feed
        parsed = parse_label((v.get("vehicle") or {}).get("label", ""))
        train = train_number((v.get("trip") or {}).get("tripId", ""))
        if parsed and parsed[2] and train:
            out.append((f"{stop}|{train}", parsed[2]))
    return out


def valid_state(obj) -> bool:
    if not isinstance(obj, dict) or obj.get("version") != 1 or not isinstance(obj.get("obs"), dict):
        return False
    for k, items in obj["obs"].items():
        if not isinstance(k, str) or not isinstance(items, list):
            return False
        for it in items:
            if not (isinstance(it, list) and len(it) == 2 and all(isinstance(x, str) for x in it)
                    and _DATE.fullmatch(it[1])):
                return False
    return True


def merge(state: dict, obs: list, today: str) -> dict:
    """Add today's sightings: one per key and day (the latest wins), last MAX_OBS kept, old keys pruned."""
    merged = {k: [list(x) for x in v] for k, v in state.get("obs", {}).items()}
    for key, platform in obs:
        items = [x for x in merged.get(key, []) if x[1] != today]
        items.append([platform, today])
        merged[key] = items
    cutoff = (date.fromisoformat(today) - timedelta(days=KEEP_DAYS)).isoformat()
    kept = {}
    for k, v in merged.items():
        v = sorted((x for x in v if x[1] >= cutoff), key=lambda x: x[1])[-MAX_OBS:]
        if v:
            kept[k] = v
    return {
        "version": 1,
        "updated": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "obs": dict(sorted(kept.items())),
    }


SOURCE = "https://gtfsrt.renfe.com/vehicle_positions.json"


def _local_day(updated: str) -> str:
    """Madrid date of an ISO UTC timestamp ("" if unparseable, so it sorts first)."""
    from zoneinfo import ZoneInfo

    try:
        t = datetime.strptime(updated, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
    except (TypeError, ValueError):
        return ""
    return t.astimezone(ZoneInfo("Europe/Madrid")).date().isoformat()


def _madrid_today() -> str:
    from zoneinfo import ZoneInfo

    return datetime.now(ZoneInfo("Europe/Madrid")).date().isoformat()


def main(argv=None) -> int:
    """One collection pass. 0 = done or nothing to do; 1 = refused to touch a suspicious state."""
    import argparse
    import json
    import os
    import sys
    import urllib.request
    from pathlib import Path

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--state", required=True, type=Path)
    parser.add_argument("--url", default=SOURCE)
    parser.add_argument("--today", help="YYYY-MM-DD (default: today in Madrid)")
    args = parser.parse_args(argv)
    today = args.today or _madrid_today()

    previous = None
    if args.state.exists():
        try:
            previous = json.loads(args.state.read_text(encoding="utf-8"))
        except ValueError:
            previous = None
        if not valid_state(previous):
            print(f"error: {args.state} is unreadable or invalid; not overwriting it", file=sys.stderr)
            return 1

    try:
        req = urllib.request.Request(args.url, headers={"User-Agent": "tren-platforms/1.0"})
        with urllib.request.urlopen(req, timeout=20) as resp:
            vp = json.loads(resp.read().decode("utf-8"))
    except Exception as e:  # network, HTTP or JSON: skip this pass, the next one will retry
        print(f"warning: could not fetch {args.url}: {e}", file=sys.stderr)
        return 0

    state = merge(previous or {"version": 1, "updated": "", "obs": {}},
                  observations(vp, datetime.now(timezone.utc)), today)
    if previous and state["obs"] == previous["obs"]:
        print("no changes")
        return 0
    stale = _local_day(previous.get("updated", "")) < (date.fromisoformat(today) - timedelta(days=2)).isoformat() \
        if previous else True
    if previous and not stale and len(state["obs"]) < len(previous["obs"]) / 2:
        print(f"error: keys would drop from {len(previous['obs'])} to {len(state['obs'])}; not writing",
              file=sys.stderr)
        return 1

    def write(path: Path, text: str) -> None:
        tmp = path.with_suffix(path.suffix + ".tmp")
        tmp.write_text(text, encoding="utf-8")
        os.replace(tmp, path)

    if previous and _local_day(previous.get("updated", "")) < today:
        write(args.state.with_name("platforms-prev.json"), args.state.read_text(encoding="utf-8"))
    write(args.state, json.dumps(state, ensure_ascii=False, separators=(",", ":")))
    print(f"{len(state['obs'])} keys; {sum(len(v) for v in state['obs'].values())} observations")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
