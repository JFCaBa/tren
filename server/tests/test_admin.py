import pytest

from anden_api.admin import render_page, summary
from anden_api.stats import Delta
from anden_api.stats_db import StatsDB

TODAY = "2026-11-23"
NAMES = {"18000": ("Madrid-Puerta de Atocha", "Madrid"), "65000": ("València Nord", "Valencia"),
         "BAD": ("<script>alert(1)</script>", "x")}


def delta(day, visitors=0, requests=0, stations=None, versions=None, follows=0, hours=None, channels=None):
    return Delta(day, visitors, False, requests, follows, hours or {}, stations or {}, versions or {}, channels or {})


@pytest.fixture
def db(tmp_path):
    d = StatsDB(tmp_path / "s.db")
    d.apply([
        delta(TODAY, visitors=5, requests=40, stations={"18000": (4, 40)}, versions={"1.5": 30, "otro": 10},
              follows=2, hours={8: 40}),
        delta("2026-11-13", visitors=9, requests=70, stations={"65000": (9, 70)}, versions={"1.4": 70},
              channels={"app": 9}),
        delta("2026-11-20", visitors=3, channels={"app": 1, "web": 2}),
    ])
    yield d
    d.close()


def s(db, rng="7d", live=6, active=1, channels=None):
    return summary(db, TODAY, rng, live, active, NAMES, {"app": 4, "web": 2} if channels is None else channels)


def test_summary_ranges(db):
    assert [t["stop"] for t in s(db, "7d")["top"]] == ["18000"]
    assert [t["stop"] for t in s(db, "all")["top"]] == ["65000", "18000"]
    assert s(db, "today")["top"][0] == {"stop": "18000", "name": "Madrid-Puerta de Atocha", "nucleo": "Madrid", "people": 4}
    assert s(db, "x")["range"] == "7d"


def test_summary_cards(db):
    x = s(db)
    assert (x["visitors_today"], x["stations_today"], x["follows_today"], x["active_follows"]) == (6, 1, 2, 1)


def test_daily_fills_gaps_and_uses_live(db):
    daily = s(db, live=42)["daily"]
    assert len(daily) == 30 and daily[0]["day"] == "2026-10-25"
    by = {d["day"]: d["visitors"] for d in daily}
    assert (by["2026-11-13"], by["2026-11-14"], by[TODAY]) == (9, 0, 42)


def test_hours_and_versions(db):
    assert s(db)["hours"][8] == 40 and len(s(db)["hours"]) == 24
    assert s(db, "today")["versions"] == [{"version": "1.5", "requests": 30, "pct": 75},
                                         {"version": "otro", "requests": 10, "pct": 25}]


def test_unknown_station_name(db):
    db.apply([delta(TODAY, stations={"99999": (9, 9)})])
    assert s(db, "today")["top"][0] == {"stop": "99999", "name": "99999", "nucleo": "", "people": 9}


def test_empty_db(tmp_path):
    d = StatsDB(tmp_path / "e.db")
    assert "Aún no hay datos" in render_page(summary(d, TODAY, "7d", 0, 0, NAMES))
    d.close()


def test_range_nav_below_unfiltered(db):
    page = render_page(s(db))
    nav = page.index('href="?range=today"')
    assert page.index("Personas hoy") < nav and page.index("Personas al día") < nav < page.index("Estaciones más vistas")


def test_render_escapes(db):
    db.apply([delta(TODAY, stations={"BAD": (99, 99)})])
    page = render_page(s(db, "today"))
    assert "<script>" not in page and "&lt;script&gt;" in page


def test_render_sections(db):
    page = render_page(s(db))
    for text in ("Andén · estadísticas", "Personas al día", "Estaciones más vistas", "Horas punta",
                 "Versiones de la app", "Madrid-Puerta de Atocha", "Hora de Madrid"):
        assert text in page
    for text in ("<script", "http://", "https://"):
        assert text not in page
    assert 'href="?range=30d"' in page


def test_links_back_to_what_platform_admin(db):
    assert '<a href="/admin">' in render_page(s(db))


def test_channels_today_live_and_range(db):
    db.apply([delta(TODAY, channels={"app": 1, "web": 1})])  # stored today: replaced by the live counts
    x = s(db)
    assert x["channels_today"] == {"app": 4, "web": 2}
    assert x["channels"] == [{"channel": "App", "people": 5}, {"channel": "Web", "people": 4}]
    assert s(db, "today")["channels"] == [{"channel": "App", "people": 4}, {"channel": "Web", "people": 2}]
    assert s(db, "all")["channels"][0] == {"channel": "App", "people": 14}


def test_render_channels(db):
    page = render_page(s(db))
    assert "<small>App 4 · Web 2</small>" in page
    nav = page.index('href="?range=today"')
    assert nav < page.index("Personas por origen") < page.index("Estaciones más vistas")


def test_channels_empty(tmp_path):
    d = StatsDB(tmp_path / "e.db")
    x = summary(d, TODAY, "7d", 0, 0, NAMES, {})
    assert x["channels"] == [{"channel": "App", "people": 0}, {"channel": "Web", "people": 0}]
    assert "<small>App 0 · Web 0</small>" in render_page(x)
    d.close()
