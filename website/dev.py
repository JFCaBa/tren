#!/usr/bin/env python3
"""Local dev server for andenapp.com: serves website/ like nginx does and proxies the board API.

    python3 website/dev.py [port] [--api URL]   # default 8001 and http://127.0.0.1:8520 (a local API)

A local API: `cd server && ANDEN_DATA=<dir with a current symlink> STATS_DB=/tmp/s.db python -m anden_api.server`
(timetables from a copy of https://api.whatplatform.uk/anden/data/). /api/board/<id> goes to
<URL>/board/<id>.

Station pages, /estaciones, /sitemap.xml, /stations.json and the legal pages come from
_site/current once built:
    python3 website/build_pages.py --data DIR --contact-env /dev/null --out _site/current
"""
from __future__ import annotations

import re
import sys
import urllib.error
import urllib.request
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

SITE = Path(__file__).resolve().parent
BUILT = SITE.parent / "_site" / "current"
UA = "Mozilla/5.0 (Andén dev; preview)"  # "preview": not counted as a person
BOARD = re.compile(r"^/api/board/([0-9]{5})$")
STATION = re.compile(r"^/estacion/([0-9]{5})/?$")
BUILT_PATHS = {"/estaciones": "estaciones.html", "/sitemap.xml": "sitemap.xml", "/stations.json": "stations.json",
               "/privacidad": "privacidad.html", "/ayuda": "ayuda.html", "/legal.css": "legal.css"}
PUBLIC = re.compile(r"^/(robots\.txt|style\.css|js/[a-z]+\.js|app-store-badge\.svg|favicon\.ico|favicon\.png|icon-192\.png|apple-touch-icon\.png)$")
TYPES = {".xml": "application/xml", ".json": "application/json", ".css": "text/css", ".html": "text/html; charset=utf-8"}
api = "http://127.0.0.1:8520"


class Handler(SimpleHTTPRequestHandler):
    def __init__(self, *a, **kw):
        super().__init__(*a, directory=str(SITE), **kw)

    def do_GET(self):
        path = self.path.split("?", 1)[0]
        m = BOARD.match(path)
        if m:
            return self.proxy(f"/board/{m.group(1)}")
        m = STATION.match(path)
        built = BUILT / "estacion" / f"{m.group(1)}.html" if m else (BUILT / BUILT_PATHS[path] if path in BUILT_PATHS else None)
        if built is not None and built.exists():
            return self.send_file(built, 200)
        if path == "/":
            self.path = "/index.html"
        elif not PUBLIC.match(path):
            return self.send_file(SITE / "index.html", 404)  # the shell, as nginx's 404
        return super().do_GET()

    def send_file(self, file: Path, status: int):
        body = file.read_bytes()
        self.send_response(status)
        self.send_header("Content-Type", TYPES.get(file.suffix, "application/octet-stream"))
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def proxy(self, path: str):
        req = urllib.request.Request(api + path, headers={"User-Agent": UA})
        try:
            with urllib.request.urlopen(req, timeout=15) as r:
                status, body = r.status, r.read()
        except urllib.error.HTTPError as e:
            status, body = e.code, e.read()
        except OSError:
            return self.send_error(502)
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def end_headers(self):
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Security-Policy", "default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self'; "
                         "connect-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'")
        super().end_headers()


if __name__ == "__main__":
    args = sys.argv[1:]
    if "--api" in args:
        i = args.index("--api")
        api = args[i + 1].rstrip("/")
        del args[i:i + 2]
    port = int(args[0]) if args else 8001
    print(f"http://localhost:{port}/  (API {api})")
    ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()
