"""board.py against the same cases as the app's app/test/board_test.dart (filters left out: the web
has none)."""
from datetime import datetime, timezone
from zoneinfo import ZoneInfo

from anden_api.board import compute_board, train_number
from anden_api.renfe import Trip

MADRID = ZoneInfo("Europe/Madrid")
NORD = {"id": "65000", "name": "València Nord", "lat": 39.4669, "lon": -0.3772}
SILLA = {"id": "64200", "name": "Silla", "lat": 39.3620, "lon": -0.4150}
GANDIA = {"id": "69110", "name": "Gandia", "lat": 38.9705, "lon": -0.1798}


def hm(h, m):
    return h * 3600 + m * 60


def out(tid, secs, dates=("2026-11-15",), line="C1"):
    return {"id": tid, "line": line, "dest": "Gandia", "dates": list(dates),
            "times": [["65000", secs - 900], ["64200", secs], ["69110", secs + 2700]]}


def inb(tid, secs, dates=("2026-11-15",)):
    return {"id": tid, "line": "C2", "dest": "València Nord", "dates": list(dates),
            "times": [["64200", secs], ["65000", secs + 900]]}


def feed(trips, generated_at="2026-11-15T03:00:00Z", valid_to="2026-11-22", nucleo="40",
         stops=(NORD, SILLA, GANDIA), lines=None, platforms=None):
    return {"version": 2, "nucleo": nucleo, "name": f"N{nucleo}", "generated_at": generated_at,
            "valid_from": "2026-11-14", "valid_to": valid_to,
            "lines": {"C1": "7AB3DE", "C2": "F79529"} if lines is None else lines,
            "stops": list(stops), "trips": trips, "platforms": platforms or {}}


def at(y, mo, d, h, mi, s=0):
    return datetime(y, mo, d, h, mi, s, tzinfo=MADRID).timestamp()


def iso(y, mo, d, h, mi, s=0):
    return datetime(y, mo, d, h, mi, s, tzinfo=MADRID).isoformat()


NOW = at(2026, 11, 15, 18, 0)


def board(feeds, stop, now=NOW, rt=None, rt_ts=None, live=None, limit=8):
    return compute_board(feeds, stop, now, rt, rt_ts, live or {}, limit)


def ids(b):
    return [d["tripId"] for d in b["departures"]]


def test_orders_by_estimated_time_and_limits_to_8():
    trips = [out(f"o{i}", hm(18, 10 + i)) if i % 2 == 0 else inb(f"i{i}", hm(18, 10 + i)) for i in range(9, -1, -1)]
    b = board([feed(trips)], "64200")
    assert ids(b) == ["o0", "i1", "o2", "i3", "o4", "i5", "o6", "i7"]
    first = b["departures"][0]
    assert (first["minutes"], first["dest"], first["line"]) == (10, "Gandia", "C1")
    assert b["hasMore"] is True


def test_has_more():
    b = board([feed([out(f"o{i}", hm(18, 10 + i)) for i in range(10)])], "64200", limit=16)
    assert len(b["departures"]) == 10
    assert b["hasMore"] is False


def test_merges_departures_of_several_feeds():
    cist = {"id": "05761", "name": "Cistierna", "lat": 42.8, "lon": -5.1}
    end = {"id": "E", "name": "Fin", "lat": 42.0, "lon": -5.0}

    def t(tid, s):
        return {"id": tid, "line": "C1", "dest": "Fin", "dates": ["2026-11-15"], "times": [["05761", s], ["E", s + 600]]}
    a = feed([t("L", hm(18, 10))], nucleo="47", stops=(cist, end))
    b = feed([t("B", hm(18, 5))], nucleo="60", stops=(cist, end))
    assert ids(board([a, b], "05761")) == ["B", "L"]


def test_color_from_its_feed_grey_when_missing():
    assert board([feed([inb("i", hm(18, 5))])], "64200")["departures"][0]["color"] == "#F79529"
    assert board([feed([inb("i", hm(18, 5))], lines={})], "64200")["departures"][0]["color"] == "#9E9E9E"


def test_usual_platform_from_feed_live_platform_from_caller():
    f = feed([out("3019L23525C1", hm(18, 10))], platforms={"64200": {"23525": "1"}})
    d = board([f], "64200")["departures"][0]
    assert (d["usualPlatform"], d["livePlatform"]) == ("1", None)
    d = board([f], "64200", live={"3019L23525C1": "3"})["departures"][0]
    assert (d["usualPlatform"], d["livePlatform"]) == ("1", "3")


def test_live_platform_only_for_imminent_run():
    f = feed([out("R", hm(18, 10), dates=("2026-11-15", "2026-11-16"))])
    b = board([f], "64200", live={"R": "3"})
    assert [d["livePlatform"] for d in b["departures"]] == ["3", None]


def test_usual_platform_of_another_station_not_used():
    f = feed([out("3019L23525C1", hm(18, 10))], platforms={"65000": {"23525": "4"}})
    assert board([f], "64200")["departures"][0]["usualPlatform"] is None


def test_excludes_trips_terminating_at_stop():
    assert ids(board([feed([inb("i", hm(18, 5)), out("o", hm(18, 30))])], "65000")) == ["o"]


def test_includes_previous_service_day_after_midnight():
    b = board([feed([out("night", 88200, dates=("2026-11-14",))])], "64200", now=at(2026, 11, 15, 0, 20))
    d = b["departures"][0]
    assert (d["tripId"], d["minutes"], d["scheduled"]) == ("night", 10, iso(2026, 11, 15, 0, 30))


def test_positive_delay_live():
    d = board([feed([out("a", hm(18, 10))])], "64200", rt={"a": Trip(540, False)}, rt_ts=NOW)["departures"][0]
    assert (d["live"], d["delay"], d["estimated"], d["minutes"]) == (True, 540, iso(2026, 11, 15, 18, 19), 19)


def test_negative_delay():
    d = board([feed([out("a", hm(18, 10))])], "64200", rt={"a": Trip(-180, False)}, rt_ts=NOW)["departures"][0]
    assert (d["delay"], d["estimated"], d["minutes"]) == (-180, iso(2026, 11, 15, 18, 7), 7)


def test_stale_realtime_falls_back_to_scheduled():
    b = board([feed([out("a", hm(18, 10))])], "64200", rt={"a": Trip(540, False)}, rt_ts=at(2026, 11, 15, 17, 57))
    assert b["rtStale"] is True
    d = b["departures"][0]
    assert (d["live"], d["delay"], d["estimated"]) == (False, None, d["scheduled"])


def test_fresh_realtime_not_stale():
    assert board([feed([out("a", hm(18, 10))])], "64200", rt={}, rt_ts=NOW)["rtStale"] is False
    assert board([feed([out("a", hm(18, 10))])], "64200")["rtStale"] is True


def test_trip_without_delay_not_live():
    b = board([feed([out("a", hm(18, 10))])], "64200", rt={"a": Trip(None, False)}, rt_ts=NOW)
    assert b["departures"][0]["live"] is False


def test_ambiguous_trip_id_ignores_realtime():
    f = feed([out("a", hm(18, 10), dates=("2026-11-15", "2026-11-16"))])
    d = board([f], "64200", rt={"a": Trip(300, True)}, rt_ts=NOW)["departures"][0]
    assert (d["live"], d["cancelled"]) == (False, False)


def test_cancelled_shown_as_cancelled():
    b = board([feed([out("a", hm(18, 10)), out("b", hm(18, 20))])], "64200", rt={"a": Trip(None, True)}, rt_ts=NOW)
    assert [(d["tripId"], d["cancelled"], d["live"]) for d in b["departures"]] == [("a", True, True), ("b", False, False)]


def test_train_within_last_minute_still_shown():
    f = [feed([out("a", hm(18, 0))])]
    assert board(f, "64200", now=at(2026, 11, 15, 18, 0, 30))["departures"][0]["minutes"] == 0
    assert board(f, "64200", now=at(2026, 11, 15, 18, 1, 30))["departures"] == []


def test_late_night_shows_tomorrow_first_trains():
    d = board([feed([out("early", hm(5, 30), dates=("2026-11-16",))])], "64200", now=at(2026, 11, 15, 23, 50))["departures"][0]
    assert (d["tripId"], d["scheduled"]) == ("early", iso(2026, 11, 16, 5, 30))


def test_dst_spring_forward():
    f = feed([out("a", 36000, dates=("2027-03-28",))], valid_to="2027-03-30")
    assert board([f], "64200", now=at(2027, 3, 28, 6, 0))["departures"][0]["scheduled"] == iso(2027, 3, 28, 10, 0)


def test_dst_fall_back():
    f = feed([out("a", 36000, dates=("2026-10-25",))], valid_to="2026-10-27")
    assert board([f], "64200", now=at(2026, 10, 25, 6, 0))["departures"][0]["scheduled"] == iso(2026, 10, 25, 10, 0)


def test_month_boundary_previous_month_service_day():
    f = feed([out("night", 88200, dates=("2026-11-30",))], valid_to="2026-12-05")
    assert board([f], "64200", now=at(2026, 12, 1, 0, 20))["departures"][0]["scheduled"] == iso(2026, 12, 1, 0, 30)


def test_madrid_service_day_whatever_the_host_zone():
    # now is a plain epoch; 23:20 UTC on the 14th is 00:20 in Madrid on the 15th
    now = datetime(2026, 11, 14, 23, 20, tzinfo=timezone.utc).timestamp()
    d = board([feed([out("night", 88200, dates=("2026-11-14",))])], "64200", now=now)["departures"][0]
    assert (d["tripId"], d["minutes"]) == ("night", 10)
    assert d["scheduled"].endswith("+01:00")


def test_stops_to_the_end_with_delay():
    d = board([feed([out("a", hm(18, 10))])], "64200", rt={"a": Trip(120, False)}, rt_ts=NOW)["departures"][0]
    assert [s["name"] for s in d["stops"]] == ["Silla", "Gandia"]
    assert (d["stops"][0]["time"], d["stops"][-1]["time"]) == (iso(2026, 11, 15, 18, 12), iso(2026, 11, 15, 18, 57))
    assert d["stops"][0]["id"] == "64200"


def test_scheduled_stops_use_scheduled_times():
    d = board([feed([out("a", hm(18, 30))])], "65000")["departures"][0]
    assert [s["name"] for s in d["stops"]] == ["València Nord", "Silla", "Gandia"]
    assert d["stops"][0]["time"] == iso(2026, 11, 15, 18, 15)


def test_no_feeds_not_covering_today():
    assert board([], "64200")["feedCoversToday"] is False


def test_feed_staleness_flags():
    fresh = board([feed([])], "64200")
    assert (fresh["feedStale"], fresh["feedCoversToday"]) == (False, True)
    old = board([feed([], generated_at="2026-11-11T00:00:00Z", valid_to="2026-11-14")], "64200")
    assert (old["feedStale"], old["feedCoversToday"]) == (True, False)


def test_train_number():
    assert train_number("3019L23525C1") == "23525"
    assert train_number("R") is None
