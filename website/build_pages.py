#!/usr/bin/env python3
"""Builds andenapp.com's crawlable pages from a timetable generation.

    python3 website/build_pages.py [--data DIR] [--site DIR] [--legal DIR] [--contact-env FILE] [--out DIR]

Writes, for nginx (pipeline/vps/andenapp.com.conf):
  estacion/{id}.html  website/index.html with that station's title, canonical, JSON-LD, heading and
                      nearby stations (the live board still comes from website/js/app.js)
  estaciones.html     every station A–Z
  sitemap.xml         home, A–Z, privacy, help and every station
  stations.json       [{id, name, lat, lon, nucleo}] for the search box and "Cerca de ti"
  privacidad.html, ayuda.html, legal.css
                      web/privacidad.html and web/soporte.html rendered with the contact details
                      (pipeline/render_pages.py), for the site's paths and CSP

--data is a generation of pipeline/vps/feed.sh (index.json). --out is a symlink to the current
build (current-<time>/ next to it): a new build is written in full and swapped in with one rename,
so nginx never sees a half-written set; on any failure the published pages stay. The previous build
is kept, older ones removed. Port of the platform repo's deploy/web/build_pages.py.
"""
from __future__ import annotations

import argparse
import fcntl
import heapq
import html
import json
import math
import os
import re
import shutil
import sys
import time
import unicodedata
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "pipeline"))
from render_pages import render  # noqa: E402

ORIGIN = "https://andenapp.com"
APP_STORE = "https://apps.apple.com/es/app/id6835200430"
NEARBY = 6
ID_RE = re.compile(r"^[0-9]{5}$")
MARKERS = ("head", "body", "extra")
LEGAL = (("privacidad.html", "privacidad.html", "/privacidad"), ("soporte.html", "ayuda.html", "/ayuda"))

e = html.escape  # quote=True: also ' and "


def ld(data: dict) -> str:
    """JSON for a <script type="application/ld+json">: nothing in it can close the tag."""
    s = json.dumps(data, ensure_ascii=False, separators=(",", ":"))
    return s.replace("<", "\\u003c").replace(">", "\\u003e").replace("&", "\\u0026")


def haversine_m(a: dict, b: dict) -> float:
    r = 6371000.0
    p1, p2 = math.radians(a["lat"]), math.radians(b["lat"])
    dp, dl = p2 - p1, math.radians(b["lon"] - a["lon"])
    h = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 2 * r * math.asin(math.sqrt(h))


def nearest(st: dict, all_st: list[dict], n: int = NEARBY) -> list[tuple[dict, float]]:
    others = ((o, haversine_m(st, o)) for o in all_st if o["id"] != st["id"])
    return heapq.nsmallest(n, others, key=lambda x: (x[1], x[0]["id"]))


def fmt_distance(m: float) -> str:
    """As the app (home_screen.dart): 450 m, 1,2 km."""
    if m < 1000:
        return f"{round(m / 10) * 10} m"
    return f"{m / 1000:.1f} km".replace(".", ",")


def validate(stations: list[dict], min_count: int) -> None:
    if len(stations) < min_count:
        raise ValueError(f"only {len(stations)} stations (< {min_count})")
    seen = set()
    for s in stations:
        if not ID_RE.match(str(s.get("id", ""))) or s["id"] in seen:
            raise ValueError(f"bad or repeated stop id: {s.get('id')!r}")
        seen.add(s["id"])
        if not str(s.get("name", "")).strip():
            raise ValueError(f"{s['id']}: no name")
        if not all(isinstance(s.get(k), (int, float)) and not isinstance(s.get(k), bool) for k in ("lat", "lon")):
            raise ValueError(f"{s['id']}: no position")


def fill(template: str, parts: dict[str, str]) -> str:
    out = template
    for k in MARKERS:
        pat = re.compile(rf"<!--seo:{k}-->.*?<!--/seo:{k}-->", re.S)
        if len(pat.findall(out)) != 1:
            raise ValueError(f"template needs exactly one <!--seo:{k}--> block")
        out = pat.sub(lambda _m, v=parts[k]: v, out)
    return out


def station_page(template: str, st: dict, all_st: list[dict]) -> str:
    name, sid, where = st["name"], st["id"], st["nucleo"]
    url = f"{ORIGIN}/estacion/{sid}"
    title = f"{name} — próximos trenes y andén | Andén"
    desc = (f"Próximos trenes desde {name} ({where}): andén, retrasos y cancelaciones en tiempo real, "
            "cada 30 segundos. Gratis y sin registro.")
    data = {"@context": "https://schema.org", "@type": "TrainStation", "name": name, "identifier": sid,
            "url": url, "geo": {"@type": "GeoCoordinates", "latitude": st["lat"], "longitude": st["lon"]}}
    head = "\n".join([
        f"<title>{e(title)}</title>",
        f'<meta name="description" content="{e(desc)}">',
        f'<link rel="canonical" href="{url}">',
        '<meta property="og:type" content="website">',
        '<meta property="og:site_name" content="Andén">',
        f'<meta property="og:title" content="{e(title)}">',
        f'<meta property="og:description" content="{e(desc)}">',
        f'<meta property="og:url" content="{url}">',
        f'<meta property="og:image" content="{ORIGIN}/apple-touch-icon.png">',
        f'<script type="application/ld+json">{ld(data)}</script>',
    ])
    body = "\n".join([
        '  <div class="top"><a class="logo" href="/">← Andén</a>'
        f'<a class="badge small" href="{APP_STORE}" rel="noopener"><img src="/app-store-badge.svg" '
        'alt="Descárgalo en el App Store" width="102" height="34"></a></div>',
        f'  <h1 class="station">{e(name)}</h1>',
        f'  <p class="tag">¿De qué andén sale mi tren en {e(name)}? Próximos trenes desde {e(name)} '
        f'({e(where)}) con su andén, retrasos y cancelaciones de Renfe, actualizados cada 30 segundos.</p>',
    ])
    near = "\n".join(
        f'    <li><a href="/estacion/{o["id"]}">{e(o["name"])}</a> <span class="crs">{fmt_distance(m)}</span></li>'
        for o, m in nearest(st, all_st))
    extra = "\n".join([
        f'<aside id="extra" class="extra" data-path="/estacion/{sid}">',
        f"  <h2>Estaciones cercanas a {e(name)}</h2>",
        f'  <ul class="nearby">\n{near}\n  </ul>',
        '  <p><a href="/estaciones">Todas las estaciones</a></p>',
        "</aside>",
    ])
    return fill(template, {"head": head, "body": body, "extra": extra})


def _fold(text: str) -> str:
    """Case- and accent-free, so Álora sorts with the A's."""
    return "".join(c for c in unicodedata.normalize("NFD", text.casefold()) if not unicodedata.combining(c))


def _key(s: dict) -> tuple:
    return (_fold(s["name"]), s["id"])


def _letter(name: str) -> str:
    first = unicodedata.normalize("NFD", name[:1].upper())[:1]
    return first if "A" <= first <= "Z" else "#"


ICONS = """<link rel="icon" href="/favicon.ico" sizes="16x16 32x32 48x48">
<link rel="icon" href="/favicon.png" type="image/png" sizes="96x96">
<link rel="icon" href="/icon-192.png" type="image/png" sizes="192x192">
<link rel="apple-touch-icon" href="/apple-touch-icon.png">"""


def a_to_z_page(all_st: list[dict]) -> str:
    groups: dict[str, list[dict]] = {}
    for s in sorted(all_st, key=_key):
        groups.setdefault(_letter(s["name"]), []).append(s)
    letters = sorted(groups)
    index = " ".join(f'<a href="#{k}">{k}</a>' for k in letters)
    sections = "\n".join(
        f'<h2 id="{k}">{k}</h2>\n<ul class="az">\n'
        + "\n".join(f'  <li><a href="/estacion/{s["id"]}">{e(s["name"])}</a> <span class="crs">{e(s["nucleo"])}</span></li>'
                    for s in groups[k])
        + "\n</ul>"
        for k in letters)
    title = "Todas las estaciones — próximos trenes y andén | Andén"
    desc = f"Próximos trenes, andenes y retrasos de las {len(all_st)} estaciones de Cercanías y Rodalies."
    return f"""<!doctype html>
<html lang="es">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{e(title)}</title>
<meta name="description" content="{e(desc)}">
<link rel="canonical" href="{ORIGIN}/estaciones">
<meta name="color-scheme" content="light dark">
{ICONS}
<link rel="stylesheet" href="/style.css">
</head>
<body>
<main>
<div class="top"><a class="logo" href="/">← Andén</a><a class="badge small" href="{APP_STORE}" rel="noopener"><img src="/app-store-badge.svg" alt="Descárgalo en el App Store" width="102" height="34"></a></div>
<h1>Todas las estaciones</h1>
<p class="tag">{e(desc)} Elige una para ver sus próximos trenes.</p>
<nav class="letters">{index}</nav>
{sections}
<footer>Datos: Renfe · <a href="/privacidad">Privacidad</a> · <a href="/ayuda">Ayuda</a></footer>
</main>
</body>
</html>
"""


def sitemap(all_st: list[dict], generated: str) -> str:
    def url(path: str, lastmod: str | None) -> str:
        lm = f"<lastmod>{e(lastmod)}</lastmod>" if lastmod else ""
        return f"<url><loc>{ORIGIN}{path}</loc>{lm}</url>"

    day = (generated or "")[:10]
    lastmod = day if re.match(r"^\d{4}-\d{2}-\d{2}$", day) else None
    urls = [url("/", None), url("/estaciones", lastmod), url("/privacidad", None), url("/ayuda", None)]
    urls += [url(f"/estacion/{s['id']}", lastmod) for s in sorted(all_st, key=lambda s: s["id"])]
    return ('<?xml version="1.0" encoding="UTF-8"?>\n'
            '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n' + "\n".join(urls) + "\n</urlset>\n")


def read_env(path: Path) -> dict:
    """KEY=VALUE lines (the contact details, never in the repo); a missing file is empty."""
    try:
        text = path.read_text(encoding="utf-8")
    except FileNotFoundError:
        return {}
    env = {}
    for line in text.splitlines():
        k, sep, v = line.partition("=")
        if sep and k.strip() and not k.lstrip().startswith("#"):
            env[k.strip()] = v.strip()
    return env


def legal_page(template: str, env: dict, path: str) -> str:
    out, _warnings = render(template, env)
    out = out.replace('href="legal.css"', 'href="/legal.css"')
    out = out.replace('href="privacidad.html"', 'href="/privacidad"').replace('href="soporte.html"', 'href="/ayuda"')
    out = re.sub(r'href="((?:favicon|icon-192|apple-touch-icon)\.(?:ico|png))"', r'href="/\1"', out)
    if "<style" in out or "style=" in out:
        raise ValueError("legal pages must not have inline styles (site CSP)")
    return out.replace("</head>", f'<link rel="canonical" href="{ORIGIN}{path}">\n</head>', 1)


def stations_of(index: dict) -> list[dict]:
    nucleos = {n["id"]: n.get("name") or n["id"] for n in index.get("nucleos") or []}
    out = []
    for s in index.get("stops") or []:
        out.append({**s, "nucleo": ", ".join(nucleos.get(n, n) for n in s.get("nucleos") or [])})
    return out


def build(data_dir: Path, template_path: Path, legal_dir: Path, contact_env: Path, out: Path,
          min_count: int = 800) -> None:
    """Writes every page into the new directory `out` (must not exist)."""
    index = json.loads((data_dir / "index.json").read_text(encoding="utf-8"))
    all_st = stations_of(index)
    validate(all_st, min_count)
    template = template_path.read_text(encoding="utf-8")
    fill(template, {k: "" for k in MARKERS})  # markers present before writing anything
    env = read_env(contact_env)
    legal = [(legal_page((legal_dir / src).read_text(encoding="utf-8"), env, path), dst)
             for src, dst, path in LEGAL]
    (out / "estacion").mkdir(parents=True)
    for st in all_st:
        (out / "estacion" / f"{st['id']}.html").write_text(station_page(template, st, all_st), encoding="utf-8")
    (out / "estaciones.html").write_text(a_to_z_page(all_st), encoding="utf-8")
    (out / "sitemap.xml").write_text(sitemap(all_st, str(index.get("generated_at", ""))), encoding="utf-8")
    search = [{"id": s["id"], "name": s["name"], "lat": s["lat"], "lon": s["lon"], "nucleo": s["nucleo"]}
              for s in sorted(all_st, key=_key)]
    (out / "stations.json").write_text(json.dumps(search, ensure_ascii=False, separators=(",", ":")), encoding="utf-8")
    for page, dst in legal:
        (out / dst).write_text(page, encoding="utf-8")
    shutil.copyfile(legal_dir / "legal.css", out / "legal.css")


def publish(build_dir: Path, link: Path) -> None:
    """Points `link` at `build_dir` in one rename, keeps the previous build, removes older ones."""
    if link.exists() and not link.is_symlink():
        raise ValueError(f"{link} is a real directory; move it away once, then run again")
    previous = os.readlink(link) if link.is_symlink() else None
    tmp = link.with_name(f".{link.name}.tmp-{os.getpid()}")
    if tmp.is_symlink() or tmp.exists():
        tmp.unlink()
    os.symlink(build_dir.name, tmp)
    os.replace(tmp, link)
    # Published from here on: a failed cleanup only leaves an old build behind.
    keep = {build_dir.name, previous}
    for p in link.parent.glob(f"{link.name}-*"):
        if p.name not in keep and p.is_dir() and not p.is_symlink():
            try:
                shutil.rmtree(p)
            except OSError as err:
                print(f"build_pages: could not remove old build {p.name}: {err}", file=sys.stderr)


def main(argv: list[str] | None = None) -> int:
    repo = Path(__file__).resolve().parents[1]
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--data", default="/opt/anden/data/current")
    ap.add_argument("--site", default=str(repo / "website"))
    ap.add_argument("--legal", default=str(repo / "web"))
    ap.add_argument("--contact-env", default="/opt/anden/web.env")
    ap.add_argument("--out", default="/opt/anden/pages/current")
    ap.add_argument("--min-count", type=int, default=800)
    args = ap.parse_args(argv)

    link = Path(args.out)
    link.parent.mkdir(parents=True, exist_ok=True)
    with open(link.parent / f".{link.name}.lock", "w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)  # a manual run and the nightly one never overlap
        build_dir = link.with_name(f"{link.name}-{time.strftime('%Y%m%d%H%M%S', time.gmtime())}-{time.time_ns() % 10**9}")
        try:
            build(Path(args.data), Path(args.site) / "index.html", Path(args.legal), Path(args.contact_env),
                  build_dir, args.min_count)
            os.chmod(build_dir, 0o755)
            publish(build_dir, link)
        except (OSError, ValueError, KeyError, TypeError) as err:
            shutil.rmtree(build_dir, ignore_errors=True)
            print(f"build_pages: failed, published pages unchanged: {err}", file=sys.stderr)
            return 1
    print(f"build_pages: {len(list((build_dir / 'estacion').iterdir()))} stations -> {link} ({build_dir.name})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
