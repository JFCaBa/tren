"""Andén follow API (behind nginx at https://api.whatplatform.uk/anden/):
POST /follow, DELETE /follow, GET /health. iPhones register the one train they follow; the poller
watches it on Renfe's open feeds and sends alerts and Live Activity updates through APNs.

Privacy: requests are not logged; device and Live Activity tokens live in memory only and are
never logged. Logged: `apns <status> <reason>`, `follow poller: <Class>`, the startup line.
"""
from __future__ import annotations

import json
import os
import re
import signal
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import TextIO

from .apns import Apns
from .follow import MAX_DURATION, FollowStore, Poller
from .renfe import POSITIONS_URL, TRIPS_URL, Feed, parse_positions, parse_trips

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


def make_server(host: str, port: int, *, follows: FollowStore | None, push, clock=time.time,
                log: TextIO = sys.stderr, trips=None, positions=None) -> ThreadingHTTPServer:
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
            self.send_json(404, {"error": "not found"})

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
            if follows.upsert(token, env, train, started, activity) != "ok":
                return self.send_json(503, {"error": "busy"})
            self.send_json(200, {"ok": True})

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


def main(env: dict | None = None) -> int:
    env = os.environ if env is None else env
    push = Apns.from_env(env)
    follows = FollowStore() if push is not None else None
    print("follow: on" if push else "follow: off (APNS_* missing or invalid)", file=sys.stderr)
    trips, positions = Feed(TRIPS_URL, parse_trips), Feed(POSITIONS_URL, parse_positions)
    httpd = make_server("0.0.0.0", 8520, follows=follows, push=push, trips=trips, positions=positions)
    stop = threading.Event()
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
    if poller is not None:
        poll_thread.join(timeout=15)
        poller.end_all()  # a deploy must not leave Live Activities frozen on lock screens
    return 0


if __name__ == "__main__":
    sys.exit(main())
