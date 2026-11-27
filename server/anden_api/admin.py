"""The /admin stats page: one self-contained HTML page (inline CSS and SVG, no script, nothing
loaded from elsewhere), rendered from the aggregates in StatsDB. Port of What Platform's
api/platform_api/admin.py, in Spanish, stations ranked by people."""
from __future__ import annotations

from datetime import date, timedelta
from html import escape

from .stats_db import StatsDB

RANGES = {"today": 0, "7d": 6, "30d": 29, "all": None}  # days back from today, inclusive
RANGE_LABELS = (("today", "Hoy"), ("7d", "7 días"), ("30d", "30 días"), ("all", "Todo"))
DEFAULT_RANGE = "7d"
DAILY_DAYS = 30
TOP = 20
CHANNELS = (("app", "App"), ("web", "Web"))


def _back(today: str, n: int) -> str:
    return (date.fromisoformat(today) - timedelta(days=n)).isoformat()


def summary(db: StatsDB, today: str, rng: str, live_visitors: int, active_follows: int,
            names: dict[str, tuple[str, str]], live_channels: dict[str, int] | None = None) -> dict:
    rng = rng if rng in RANGES else DEFAULT_RANGE
    since = None if RANGES[rng] is None else _back(today, RANGES[rng])
    first = _back(today, DAILY_DAYS - 1)
    by_day = {d["day"]: d for d in db.days(first)}
    daily = [{"day": _back(today, n), "visitors": by_day.get(_back(today, n), {}).get("visitors", 0)}
             for n in range(DAILY_DAYS - 1, -1, -1)]
    daily[-1]["visitors"] = live_visitors
    hours = db.hours(since)
    versions = db.versions(since)
    total = sum(versions.values())
    live_channels = live_channels or {}
    # Days before today from the store; today from the live sets (the store lags until the next flush).
    stored = db.channels(since, before=today)
    by_channel = {ch: stored.get(ch, 0) + live_channels.get(ch, 0) for ch, _ in CHANNELS}
    return {
        "range": rng,
        "visitors_today": live_visitors,
        "channels_today": {ch: live_channels.get(ch, 0) for ch, _ in CHANNELS},
        "channels": [{"channel": label, "people": by_channel[ch]} for ch, label in CHANNELS],
        "stations_today": db.stations_count(today),
        "follows_today": by_day.get(today, {}).get("follows", 0),
        "active_follows": active_follows,
        "daily": daily,
        "top": [{"stop": st, "name": names.get(st, (st, ""))[0], "nucleo": names.get(st, (st, ""))[1], "people": n}
                for st, n in db.top_stations(since, TOP)],
        "hours": [hours.get(h, 0) for h in range(24)],
        "versions": [{"version": v, "requests": n, "pct": round(100 * n / total)}
                     for v, n in sorted(versions.items(), key=lambda kv: (-kv[1], kv[0]))],
    }


CSS = """
:root { --brand: #B91C1C; --accent: #B45309; --ink: #111827; --muted: #6B7280; --bg: #F9FAFB;
  --card: #FFFFFF; --line: #E5E7EB; --bar: #B91C1C; }
@media (prefers-color-scheme: dark) { :root { --brand: #FCA5A5; --accent: #FBBF24; --ink: #F3F4F6;
  --muted: #9CA3AF; --bg: #0B1220; --card: #111A2E; --line: #1F2A44; --bar: #F87171; } }
* { box-sizing: border-box; }
body { margin: 0; background: var(--bg); color: var(--ink);
  font: 15px/1.45 -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; }
main { max-width: 760px; margin: 0 auto; padding: 20px 16px 40px; }
h1 { font-size: 20px; margin: 0 0 16px; color: var(--brand); }
h1 a { float: right; font-size: 14px; font-weight: 500; color: var(--brand); text-decoration: none;
  padding: 4px 10px; border: 1px solid var(--line); border-radius: 999px; }
h2 { font-size: 15px; margin: 28px 0 10px; color: var(--muted); font-weight: 600;
  text-transform: uppercase; letter-spacing: .04em; }
nav { display: flex; gap: 6px; flex-wrap: wrap; margin: 28px 0 -12px; }
h2 small { text-transform: none; letter-spacing: 0; font-weight: 400; }
nav a { padding: 6px 12px; border-radius: 999px; border: 1px solid var(--line); color: var(--ink);
  text-decoration: none; font-size: 14px; }
nav a.on { background: var(--brand); border-color: var(--brand); color: var(--bg); }
.cards { display: grid; grid-template-columns: repeat(3, 1fr); gap: 10px; }
.card { background: var(--card); border: 1px solid var(--line); border-radius: 12px; padding: 12px; }
.card b { display: block; font-size: 26px; font-variant-numeric: tabular-nums; }
.card span { color: var(--muted); font-size: 13px; }
.card small { display: block; color: var(--muted); font-size: 12px; margin-top: 2px; }
.panel { background: var(--card); border: 1px solid var(--line); border-radius: 12px; padding: 12px; }
svg { display: block; width: 100%; height: auto; }
svg rect { fill: var(--bar); }
svg rect.today { fill: var(--accent); }
svg text { fill: var(--muted); font-size: 10px; }
.row { display: grid; grid-template-columns: minmax(0, 1fr) 2fr auto; gap: 8px; align-items: center;
  padding: 3px 0; font-size: 14px; }
.row .name { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.row .name small { color: var(--muted); }
.row .bar { height: 10px; background: var(--line); border-radius: 5px; overflow: hidden; }
.row .bar i { display: block; height: 100%; background: var(--bar); }
.row .n { font-variant-numeric: tabular-nums; color: var(--muted); }
.empty { color: var(--muted); }
footer { margin-top: 28px; color: var(--muted); font-size: 12px; }
"""


def _bars(values: list[int], labels: list[str], highlight_last: bool) -> str:
    w, h, gap = 600, 120, 2
    top = max(values) or 1
    bw = w / len(values)
    out = [f'<svg viewBox="0 0 {w} {h + 16}" role="img">']
    for i, v in enumerate(values):
        bh = round(h * v / top) if v else 0
        cls = ' class="today"' if highlight_last and i == len(values) - 1 else ""
        out.append(f'<rect{cls} x="{i * bw + gap / 2:.1f}" y="{h - bh}" width="{bw - gap:.1f}" '
                   f'height="{bh}" rx="2"><title>{escape(labels[i])}: {v}</title></rect>')
    for i in range(0, len(values), max(1, len(values) // 6)):
        out.append(f'<text x="{i * bw:.1f}" y="{h + 13}">{escape(labels[i])}</text>')
    out.append("</svg>")
    return "".join(out)


def _rows(items: list[tuple[str, str, int]]) -> str:
    top = max((n for _, _, n in items), default=0) or 1
    return "".join(
        f'<div class="row"><span class="name">{escape(name)} <small>{escape(sub)}</small></span>'
        f'<span class="bar"><i style="width:{100 * n / top:.1f}%"></i></span><span class="n">{n:,}</span></div>'
        for name, sub, n in items)


def render_page(s: dict) -> str:
    nav = "".join(f'<a href="?range={k}"{" class=on" if k == s["range"] else ""}>{label}</a>'
                  for k, label in RANGE_LABELS)
    by_channel_today = " · ".join(f"{label} {s['channels_today'][ch]:,}" for ch, label in CHANNELS)
    cards = (f'<div class="card"><b>{s["visitors_today"]:,}</b><span>Personas hoy</span>'
             f'<small>{by_channel_today}</small></div>'
             f'<div class="card"><b>{s["stations_today"]:,}</b><span>Estaciones hoy</span></div>'
             f'<div class="card"><b>{s["active_follows"]:,} / {s["follows_today"]:,}</b>'
             f'<span>Trenes seguidos ahora / hoy</span></div>')
    daily = _bars([d["visitors"] for d in s["daily"]], [d["day"][5:] for d in s["daily"]], True)
    empty = '<p class="empty">Aún no hay datos.</p>'
    channels = _rows([(c["channel"], "", c["people"]) for c in s["channels"]])
    top = _rows([(t["name"], t["nucleo"], t["people"]) for t in s["top"]]) or empty
    hours = _bars(s["hours"], [f"{h:02d}" for h in range(24)], False) if any(s["hours"]) else empty
    versions = _rows([(v["version"], f'{v["pct"]}%', v["requests"]) for v in s["versions"]]) or empty
    return f"""<!doctype html>
<html lang="es"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Andén · estadísticas</title><style>{CSS}</style></head>
<body><main>
<h1>Andén · estadísticas <a href="/admin">← What Platform</a></h1>
<div class="cards">{cards}</div>
<h2>Personas al día <small>· últimos 30 días</small></h2><div class="panel">{daily}</div>
<nav class="range">{nav}</nav>
<h2>Personas por origen <small>· app y web</small></h2><div class="panel">{channels}</div>
<h2>Estaciones más vistas <small>· personas</small></h2><div class="panel">{top}</div>
<h2>Horas punta <small>· consultas</small></h2><div class="panel">{hours}</div>
<h2>Versiones de la app <small>· consultas</small></h2><div class="panel">{versions}</div>
<footer>Cada persona cuenta una vez al día, sin guardar su IP. Hora de Madrid.</footer>
</main></body></html>
"""
