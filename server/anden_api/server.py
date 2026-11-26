"""Andén follow API (behind nginx at https://api.whatplatform.uk/anden/):
POST /follow, DELETE /follow, GET /train/<trip>/<stop>, GET /live/<stop>, GET /board/<stop> (the
website's board, andenapp.com), GET /health. iPhones register the one train they follow; the poller
watches it on Renfe's open feeds and sends alerts and Live Activity updates through APNs.

Privacy: requests are not logged; device and Live Activity tokens live in memory only and are
never logged. Usage stats (stats.py): only aggregates, for the password-protected /admin page;
the client IP (nginx sends it on /live and /board only) and User-Agent are never stored. Logged:
`apns <status> <reason>`, `follow poller: <Class>`, `stats: <Class>`, the startup lines.
"""
from __future__ import annotations

import hmac
import json
import os
import re
import signal
import sys
import threading
import time
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import TextIO

from .admin import render_page, summary
from .apns import Apns
from .board import compute_board
from .follow import MAX_DURATION, FollowStore, Poller
from pathlib import Path

from .refresher import Refresher
from .renfe import POSITIONS_URL, TRIPS_URL, Feed, parse_positions, parse_trips
from .stations import StationTrips
from .stats import Tally, madrid_day
from .stats_db import StatsDB

TOKEN_RE = re.compile(r"[0-9a-fA-F]{64,200}")
ACTIVITY_TOKEN_RE = re.compile(r"[0-9a-fA-F]{64,512}")
TRIP_RE = re.compile(r"[0-9A-Za-z_-]{3,40}")
STOP_RE = re.compile(r"[0-9A-Za-z_-]{3,12}")
ENVS = ("production", "sandbox")
MAX_BODY = 16384
MAX_TITLE = 80
MAX_NAME = 80
MAX_STOPS = 120
MAX_PLATFORM = 8
EARLIEST = 3 * 3600  # scheduled departure may be at most this far in the past (late trains)…
LATEST = 6 * 3600  # …and this far ahead


def follow_request(body: object, now: float):
    """(token, env, train, started, activity) from a POST /follow body, or None if invalid."""
    if not isinstance(body, dict):
        return None
    token, env, activity = body.get("token"), body.get("env"), body.get("activityToken")
    trip, stop, title = body.get("tripId"), body.get("stopId"), body.get("title")
    scheduled, started, usual, stops = body.get("scheduled"), body.get("startedAt"), body.get("usual"), body.get("stops")

    def is_int(x):
        return isinstance(x, int) and not isinstance(x, bool)

    if not (isinstance(token, str) and TOKEN_RE.fullmatch(token) and env in ENVS
            and (activity is None or (isinstance(activity, str) and ACTIVITY_TOKEN_RE.fullmatch(activity)))
            and isinstance(trip, str) and TRIP_RE.fullmatch(trip)
            and isinstance(stop, str) and STOP_RE.fullmatch(stop)
            and isinstance(title, str) and 0 < len(title) <= MAX_TITLE
            and is_int(scheduled) and now - EARLIEST <= scheduled <= now + LATEST
            and is_int(started) and 0 <= started <= (now + 3600) * 1000
            and (usual is None or (isinstance(usual, str) and 0 < len(usual) <= MAX_PLATFORM))
            and isinstance(stops, list) and 1 <= len(stops) <= MAX_STOPS):
        return None
    clean = []
    for s in stops:
        if not (isinstance(s, list) and len(s) == 2 and isinstance(s[0], str) and STOP_RE.fullmatch(s[0])
                and isinstance(s[1], str) and 0 < len(s[1]) <= MAX_NAME):
            return None
        clean.append([s[0], s[1]])
    if clean[-1][0] != stop:
        return None
    train = {"tripId": trip, "stopId": stop, "scheduled": scheduled, "title": title, "usual": usual, "stops": clean}
    return token.lower(), env, train, min(started / 1000, now), activity.lower() if activity else None


TRAIN_PATH = re.compile(r"^/train/([0-9A-Za-z_-]{3,40})/([0-9A-Za-z_-]{3,12})$")


def train_reading(trips, positions, trip: str, stop: str) -> dict:
    """What Renfe says now about one train, for the app (Android's follow service and the home
    screen): a few hundred bytes instead of two ~130 KB feeds."""
    t = trips.get(trip) if trips is not None else None
    p = positions.get(trip) if positions is not None else None
    return {
        "live": trips is not None,
        "delay": t.delay if t else None,
        "cancelled": bool(t and t.cancelled),
        "seen": None if p is None else {"stopId": p.stop_id, "status": p.status,
                                        "platform": p.platform if p.stop_id == stop else None},
    }


LIVE_PATH = re.compile(r"^/live/([0-9A-Za-z_-]{3,12})$")
BOARD_PATH = re.compile(r"^/board/([0-9]{5})$")
BOARD_TTL = 15  # s: many web viewers of one station cost one computation
BOARD_RT_MAX_AGE = 120  # s: the app's 2 min (board.dart _rtMaxAge); /live keeps LIVE_MAX_AGE
SIGHTING_MAX_AGE = 120  # s: a fresh feed can carry an old sighting (app's positionsMaxAge)
ADMIN_PATH = re.compile(r"^/admin(?:\?range=([a-z0-9]{1,8}))?$")
ADMIN_CSP = "default-src 'none'; style-src 'unsafe-inline'; img-src 'self'"
FLUSH_EVERY = 60.0
LIVE_MAX_AGE = 90  # the app calls realtime older than 2 min stale (board.dart _rtMaxAge)


def station_reading(trips, trips_ts, positions, positions_ts, trip_ids, stop: str) -> dict:
    """Delays of the trains that call at `stop` and the platforms of those arriving or standing
    there: what the app's board needs, instead of Renfe's two whole-country feeds."""
    platforms = {}
    for tid, p in (positions or {}).items():
        if p.stop_id == stop and p.platform is not None:
            platforms[tid] = {"platform": p.platform, "at": p.at if p.at is not None else positions_ts}
    return {
        "tripsAt": trips_ts,
        "trips": {tid: {"delay": t.delay, "cancelled": t.cancelled} for tid, t in trips.items() if tid in trip_ids},
        "positionsAt": positions_ts if positions is not None else None,
        "platforms": platforms,
    }


def live_platforms(positions, positions_ts, stop: str, now: float) -> dict[str, str]:
    """trip → platform of trains reported at `stop` within the last 2 minutes (app's platformsAt)."""
    out = {}
    for tid, p in (positions or {}).items():
        at = p.at if p.at is not None else positions_ts
        if p.stop_id == stop and p.platform is not None and at is not None and now - at <= SIGHTING_MAX_AGE:
            out[tid] = p.platform
    return out


def make_server(host: str, port: int, *, follows: FollowStore | None, push, clock=time.time,
                log: TextIO = sys.stderr, trips=None, positions=None, stations=None,
                refresher=None, stats: Tally | None = None, stats_db: StatsDB | None = None,
                admin_key: str = "") -> ThreadingHTTPServer:
    boards: dict[str, tuple[float, dict]] = {}  # stop → (computed at, board), for BOARD_TTL
    boards_lock = threading.Lock()

    class Handler(BaseHTTPRequestHandler):
        server_version = "anden-api"
        sys_version = ""
        timeout = 10

        def log_message(self, fmt, *args):  # requests are not logged (privacy policy)
            pass

        def send_json(self, status: int, body: dict | None):
            data = b"" if body is None else json.dumps(body, separators=(",", ":")).encode()
            self.send_response(status)
            if body is not None:
                self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(data)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(data)

        def read_json(self):
            try:
                n = int(self.headers.get("Content-Length", ""))
            except ValueError:
                return False, None
            if n < 0 or n > MAX_BODY:
                return False, None
            try:
                return True, json.loads(self.rfile.read(n).decode("utf-8"))
            except (ValueError, UnicodeDecodeError, RecursionError):
                return False, None

        def do_GET(self):
            if self.path == "/health":
                return self.send_json(200, {"ok": True})
            m = TRAIN_PATH.match(self.path)
            if m and trips is not None and positions is not None:
                now = clock()
                body = train_reading(trips.fetch(now), positions.fetch(now), m.group(1), m.group(2))
                return self.send_json(200, body)
            m = LIVE_PATH.match(self.path)
            if m and stations is not None and trips is not None and positions is not None:
                return self.live(m.group(1))
            m = BOARD_PATH.match(self.path)
            if m and stations is not None and trips is not None and positions is not None:
                return self.board(m.group(1))
            am = ADMIN_PATH.match(self.path)
            if am:
                return self.admin(am.group(1) or "")
            self.send_json(404, {"error": "not found"})

        def count_live(self, now: float, stop: str):
            if stats is None:
                return
            try:  # stats never break the board
                stats.add_live(now, stop, self.headers.get("X-Real-IP") or None, self.headers.get("User-Agent") or "")
            except Exception as e:
                log.write(f"stats: {type(e).__name__}\n")

        def admin(self, rng: str):
            """The stats page, only with nginx's secret header (nginx asks for the password)."""
            given = self.headers.get("X-Admin-Key") or ""
            if not (admin_key and stats is not None and stats_db is not None
                    and hmac.compare_digest(given.encode(), admin_key.encode())):
                return self.send_json(404, {"error": "not found"})
            now = clock()
            today = madrid_day(now)
            names = stations.names() if stations is not None else {}
            page = render_page(summary(stats_db, today, rng, stats_db.visitors_base(today) + stats.visitors_today(now),
                                       len(follows) if follows is not None else 0, names)).encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(page)))
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Security-Policy", ADMIN_CSP)
            self.send_header("X-Content-Type-Options", "nosniff")
            self.send_header("Referrer-Policy", "no-referrer")
            self.end_headers()
            self.wfile.write(page)

        def live(self, stop: str):
            now = clock()
            trip_ids = stations.get(stop)
            if trip_ids is None:
                return self.send_json(503, {"error": "unavailable"})
            if not stations.known(stop):
                return self.send_json(404, {"error": "not found"})
            t = trips.cached(now, LIVE_MAX_AGE)
            if refresher is not None:
                refresher.touch(now, wake=t is None)
            if t is None:  # nothing fresh (Renfe down or frozen, or nobody asked lately): the app reads Renfe
                self.send_json(503, {"error": "unavailable"})
                return self.count_live(now, stop)  # still someone looking at this station
            pos, pos_ts = positions.cached(now, LIVE_MAX_AGE) or (None, None)
            body = station_reading(t[0], t[1], pos, pos_ts, trip_ids, stop)
            self.send_json(200, body)
            self.count_live(now, stop)

        def board(self, stop: str):
            now = clock()
            feeds = stations.feeds_for(stop)
            if feeds is None:
                return self.send_json(503, {"error": "unavailable"})
            info = stations.station(stop)
            if not feeds or info is None:
                return self.send_json(404, {"error": "not found"})
            with boards_lock:
                hit = boards.get(stop)
            if hit is not None and now - hit[0] < BOARD_TTL:
                body = hit[1]
            else:
                t = trips.cached(now, BOARD_RT_MAX_AGE)
                if refresher is not None:
                    refresher.touch(now, wake=t is None)
                pos, pos_ts = positions.cached(now, BOARD_RT_MAX_AGE) or (None, None)
                b = compute_board(feeds, stop, now, t[0] if t else None, t[1] if t else None,
                                  live_platforms(pos, pos_ts, stop, now))
                body = {"generatedAt": datetime.fromtimestamp(now, timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z"),
                        "station": info, **b}
                with boards_lock:
                    for k in [k for k, (ts, _) in boards.items() if now - ts >= BOARD_TTL]:
                        del boards[k]
                    boards[stop] = (now, body)
            self.send_json(200, body)
            self.count_live(now, stop)

        def do_POST(self):
            if self.path != "/follow":
                return self.send_json(404, {"error": "not found"})
            if follows is None or push is None:
                return self.send_json(503, {"error": "unavailable"})
            ok, body = self.read_json()
            now = clock()
            req = follow_request(body, now) if ok else None
            if req is None:
                return self.send_json(400, {"error": "bad request"})
            token, env, train, started, activity = req
            if now - started >= MAX_DURATION:
                return self.send_json(410, {"error": "gone"})
            result = follows.upsert(token, env, train, started, activity)
            if result not in ("ok", "renewed"):
                return self.send_json(503, {"error": "busy"})
            self.send_json(200, {"ok": True})
            if stats is not None and result == "ok":  # a new follow, not an app re-sync
                try:
                    stats.add_follow(now)
                except Exception as e:
                    log.write(f"stats: {type(e).__name__}\n")

        def do_DELETE(self):
            if self.path != "/follow":
                return self.send_json(404, {"error": "not found"})
            if follows is None:
                return self.send_json(503, {"error": "unavailable"})
            ok, body = self.read_json()
            token = body.get("token") if ok and isinstance(body, dict) else None
            if not (isinstance(token, str) and TOKEN_RE.fullmatch(token)):
                return self.send_json(400, {"error": "bad request"})
            follows.remove(token.lower())
            self.send_json(204, None)

    class Server(ThreadingHTTPServer):
        daemon_threads = True

        def handle_error(self, request, client_address):
            try:
                log.write(f"unhandled {type(sys.exc_info()[1]).__name__}\n")
            except Exception:
                pass

    return Server((host, port), Handler)


def run_flusher(tally: Tally, db: StatsDB, backup_dir: Path, stop: threading.Event, log: TextIO,
                clock=time.time, every: float = FLUSH_EVERY) -> None:
    """Every `every` s the tally's counters go to SQLite; a batch that fails stays pending and is
    retried first. A closed day is backed up once its counters are stored (a failed backup is
    retried alone). One last round when `stop` is set. (Port of What Platform's.)"""
    pending: list = []
    backups: list[str] = []
    while True:
        stopping = stop.wait(every)
        # Stopping: a second round stores what arrived while a failed batch was pending.
        for _ in range(2 if stopping else 1):
            try:
                if not pending:
                    pending = tally.drain(clock())
                db.apply(pending)
                backups += [d.day for d in pending if d.closed]
                pending = []
            except Exception as e:
                log.write(f"stats: {type(e).__name__}\n")
                break
        while backups:
            try:
                db.backup(backup_dir, backups[0])
                backups.pop(0)
            except Exception as e:
                log.write(f"stats: {type(e).__name__}\n")
                break
        if stopping:
            return


def main(env: dict | None = None) -> int:
    env = os.environ if env is None else env
    push = Apns.from_env(env)
    follows = FollowStore() if push is not None else None
    print("follow: on" if push else "follow: off (APNS_* missing or invalid)", file=sys.stderr)
    trips, positions = Feed(TRIPS_URL, parse_trips), Feed(POSITIONS_URL, parse_positions)
    stations = StationTrips(Path(env.get("ANDEN_DATA", "/opt/anden/data/current")))
    print("stations: loaded" if stations.refresh() else "stations: not loaded yet", file=sys.stderr)
    refresher = Refresher(trips, positions, stations)
    tally, stats_db = Tally(), None
    try:
        stats_db = StatsDB(env.get("STATS_DB", "/stats/stats.db"))
    except Exception as e:
        print(f"stats: off ({type(e).__name__})", file=sys.stderr)
    httpd = make_server("0.0.0.0", 8520, follows=follows, push=push, trips=trips, positions=positions,
                        stations=stations, refresher=refresher,
                        stats=tally if stats_db is not None else None, stats_db=stats_db,
                        admin_key=env.get("ANDEN_ADMIN_KEY", "").strip())
    stop_stats = threading.Event()
    flusher = None
    if stats_db is not None:
        flusher = threading.Thread(target=run_flusher, args=(
            tally, stats_db, Path(env.get("STATS_BACKUP_DIR", "/stats/backups")), stop_stats, sys.stderr),
            daemon=True)
        flusher.start()
    stop = threading.Event()
    threading.Thread(target=refresher.run, args=(stop,), daemon=True).start()
    poller = None
    if push is not None:
        poller = Poller(follows, trips, positions, push)
        poll_thread = threading.Thread(target=poller.run, args=(stop,), daemon=True)
        poll_thread.start()

    def on_term(*_):
        if not stop.is_set():
            stop.set()
            threading.Thread(target=httpd.shutdown, daemon=True).start()

    signal.signal(signal.SIGTERM, on_term)
    print(f"listening on :{httpd.server_address[1]}", file=sys.stderr)
    httpd.serve_forever()
    stop_stats.set()  # store the last minute of stats
    if flusher is not None:
        flusher.join(timeout=10)
    if poller is not None:
        poll_thread.join(timeout=15)
        poller.end_all()  # a deploy must not leave Live Activities frozen on lock screens
    return 0


if __name__ == "__main__":
    sys.exit(main())
