from datetime import datetime, timezone

from anden_api.stats import Tally, madrid_day, madrid_hour


def utc(*a) -> float:
    return datetime(*a, tzinfo=timezone.utc).timestamp()


# November: Madrid is UTC+1. 23 Nov 2026 10:00 UTC = 11:00 Madrid.
D = (2026, 11, 23)
D1 = (2026, 11, 24)
UA = "Anden/1.5"


class Keys:
    def __init__(self):
        self.calls = 0

    def __call__(self):
        self.calls += 1
        return bytes([self.calls]) * 32


def test_people_dedupe_and_versions():
    t = Tally()
    ts = utc(*D, 10)
    for _ in range(3):
        t.add_live(ts, "18000", "1.2.3.4", UA)
    t.add_live(ts, "18000", "5.6.7.8", "Anden/1.4")
    t.add_live(ts, "18000", "9.9.9.9", "curl/8")
    [d] = t.drain(ts + 1)
    assert d.visitors == 2 and d.requests == 5 and not d.closed
    assert d.versions == {"1.5": 3, "1.4": 1, "otro": 1}
    assert d.stations == {"18000": (2, 5)}


def test_station_people_distinct():
    t = Tally()
    ts = utc(*D, 10)
    for _ in range(10):
        t.add_live(ts, "18000", "1.2.3.4", UA)  # one person polling every 30 s
    t.add_live(ts, "69110", "1.2.3.4", UA)
    t.add_live(ts, "69110", "5.6.7.8", UA)
    [d] = t.drain(ts + 1)
    assert d.stations == {"18000": (1, 10), "69110": (2, 2)}
    assert d.visitors == 2


def test_station_people_absolute_across_drains():
    t = Tally()
    ts = utc(*D, 10)
    t.add_live(ts, "18000", "1.2.3.4", UA)
    t.drain(ts + 1)
    t.add_live(ts + 2, "18000", "1.2.3.4", UA)
    t.add_live(ts + 2, "18000", "5.6.7.8", UA)
    [d] = t.drain(ts + 3)
    assert d.stations == {"18000": (2, 2)}  # people so far today; requests since last drain


def test_no_ip_counts_request_not_person():
    t = Tally()
    ts = utc(*D, 10)
    t.add_live(ts, "18000", None, UA)
    t.add_live(ts, "18000", "", UA)
    [d] = t.drain(ts + 1)
    assert (d.visitors, d.requests, d.stations) == (0, 2, {"18000": (0, 2)})


def test_hours_madrid():
    t = Tally()
    t.add_live(utc(*D, 7, 10), "18000", "1.2.3.4", UA)  # 08:10 Madrid
    t.add_live(utc(*D, 8, 0), "18000", "1.2.3.4", UA)
    [d] = t.drain(utc(*D, 8, 1))
    assert d.hours == {8: 1, 9: 1}


def test_drain_resets_counters_but_not_visitors():
    t = Tally()
    ts = utc(*D, 10)
    t.add_live(ts, "18000", "1.2.3.4", UA)
    t.drain(ts + 1)
    [d] = t.drain(ts + 2)
    assert d.requests == 0 and d.visitors == 1
    assert t.visitors_today() == 1


def test_madrid_midnight():
    # 23:00 UTC on 23 Nov is 00:00 on 24 Nov in Madrid (winter); summer is UTC+2.
    assert madrid_day(utc(*D, 22, 59, 59)) == "2026-11-23"
    assert madrid_day(utc(*D, 23, 0, 0)) == "2026-11-24"
    assert (madrid_day(utc(2026, 6, 1, 21, 59, 59)), madrid_day(utc(2026, 6, 1, 22, 0))) == ("2026-06-01", "2026-06-02")
    assert madrid_hour(utc(2026, 6, 1, 22, 30)) == 0


def test_day_close_on_drain():
    keys = Keys()
    t = Tally(key_factory=keys)
    t.add_live(utc(*D, 21), "18000", "1.2.3.4", UA)
    t.add_live(utc(*D, 22), "18000", "5.6.7.8", UA)
    [d] = t.drain(utc(*D, 23, 0, 30))
    assert (d.day, d.closed, d.visitors, d.requests, d.stations) == ("2026-11-23", True, 2, 2, {"18000": (2, 2)})
    assert t.visitors_today() == 0
    assert keys.calls == 2


def test_day_close_on_request_keeps_closed_station_people():
    t = Tally()
    t.add_live(utc(*D, 22), "18000", "1.2.3.4", UA)
    t.add_live(utc(*D, 23, 1), "18000", "5.6.7.8", UA)  # new Madrid day
    a, b = t.drain(utc(*D, 23, 2))
    assert (a.day, a.closed, a.visitors, a.stations) == ("2026-11-23", True, 1, {"18000": (1, 1)})
    assert (b.day, b.closed, b.visitors, b.stations) == ("2026-11-24", False, 1, {"18000": (1, 1)})


def test_closed_station_people_without_new_requests():
    t = Tally()
    t.add_live(utc(*D, 20), "18000", "1.2.3.4", UA)
    t.drain(utc(*D, 20, 1))  # requests already drained
    [d] = t.drain(utc(*D, 23, 1))
    assert d.closed and d.stations == {"18000": (1, 0)}


def test_late_request_dropped():
    t = Tally()
    t.add_live(utc(*D, 22), "18000", "1.2.3.4", UA)
    t.drain(utc(*D, 23, 1))
    t.add_live(utc(*D, 22, 59), "18000", "5.6.7.8", UA)
    t.add_follow(utc(*D, 22, 59))
    assert t.drain(utc(*D, 23, 2)) == []


def test_follows():
    t = Tally()
    t.add_follow(utc(*D, 10))
    [d] = t.drain(utc(*D, 10, 1))
    assert d.follows == 1


def test_visitors_today_after_midnight_without_traffic():
    t = Tally()
    t.add_live(utc(*D, 22), "18000", "1.2.3.4", UA)
    assert t.visitors_today(utc(*D, 22, 30)) == 1
    assert t.visitors_today(utc(*D, 23, 0, 10)) == 0


def test_same_ip_new_day_new_hash():
    t = Tally()
    t.add_live(utc(*D, 12), "18000", "1.2.3.4", UA)
    t.add_live(utc(*D1, 12), "18000", "1.2.3.4", UA)
    a, b = t.drain(utc(*D1, 13))
    assert (a.visitors, b.visitors) == (1, 1)


def test_nothing_sensitive_kept():
    t = Tally()
    t.add_live(utc(*D, 12), "18000", "1.2.3.4", "Anden/1.5 SecretUA")
    t.drain(utc(*D1, 0, 1))
    dump = repr(vars(t))
    assert "1.2.3.4" not in dump and "SecretUA" not in dump


def test_only_numeric_versions_count_as_people():
    t = Tally()
    ts = utc(*D, 10)
    for i in range(50):
        t.add_live(ts, "18000", "1.2.3.4", f"Anden/x{i}")  # made-up versions: not the app
    t.add_live(ts, "18000", "1.2.3.4", "Anden/1.5")
    t.add_live(ts, "18000", "1.2.3.4", "Anden/1.5 (iPhone; extra)")  # same person: ip + version
    [d] = t.drain(ts + 1)
    assert d.visitors == 1 and d.stations == {"18000": (1, 52)}
    assert d.versions == {"otro": 50, "1.5": 2}


def test_browser_counts_as_web_person():
    t = Tally()
    t.add_live(utc(*D, 10), "18000", "203.0.113.9", "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X)")
    [d] = t.drain(utc(*D, 10))
    assert (d.visitors, d.versions) == (1, {"web": 1})


def test_bot_browser_ua_is_otro():
    t = Tally()
    for ua in ("Mozilla/5.0 (compatible; Googlebot/2.1)", "Mozilla/5.0 HeadlessChrome/120", "Mozilla/5.0 (link preview)"):
        t.add_live(utc(*D, 10), "18000", "203.0.113.9", ua)
    [d] = t.drain(utc(*D, 10))
    assert (d.visitors, d.versions) == (0, {"otro": 3})
