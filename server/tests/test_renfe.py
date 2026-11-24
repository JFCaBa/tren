import io
import json
import urllib.error

from anden_api.renfe import Feed, Sighting, Trip, parse_positions, parse_trips


def test_parse_trips():
    j = {"header": {"timestamp": "100"}, "entity": [
        {"tripUpdate": {"trip": {"tripId": "A"}, "delay": 120}},
        {"tripUpdate": {"trip": {"tripId": "B", "scheduleRelationship": "CANCELED"}}},
        {"tripUpdate": {"trip": {}}}, None, {"x": 1}]}
    assert parse_trips(j) == {"A": Trip(120, False), "B": Trip(None, True)}
    assert parse_trips({}) == {}


def test_parse_positions():
    def v(tid, stop, status, label):
        return {"vehicle": {"trip": {"tripId": tid}, "stopId": stop, "currentStatus": status, "vehicle": {"label": label}}}
    j = {"entity": [v("A", "18000", "STOPPED_AT", "C3-23525-PLATF.(6)"),
                    v("B", "18001", "IN_TRANSIT_TO", "C3-23526-PLATF.(2)"),
                    v("C", "18002", "INCOMING_AT", "C3-23527"),
                    v("D", "00000", "STOPPED_AT", "x"), v("E", "1", "WEIRD", "x"), {"vehicle": None}]}
    assert parse_positions(j) == {"A": Sighting("18000", "STOPPED_AT", "6"),
                                  "B": Sighting("18001", "IN_TRANSIT_TO", None),
                                  "C": Sighting("18002", "INCOMING_AT", None)}


class Resp:
    def __init__(self, body, etag=None):
        self._b = body
        self.headers = {"ETag": etag} if etag else {}

    def read(self, n=-1):
        return self._b

    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False


def test_feed_etag_and_staleness():
    calls = []
    answers = [Resp(json.dumps({"header": {"timestamp": 1000}, "entity": []}).encode(), "e1"),
               urllib.error.HTTPError("u", 304, "nm", {}, io.BytesIO()),
               OSError("down")]

    def opener(req, timeout):
        calls.append(req.headers.get("If-none-match"))
        a = answers.pop(0)
        if isinstance(a, Exception):
            raise a
        return a

    f = Feed("https://example.test/t.json", parse_trips, opener=opener)
    assert f.fetch(1010) == {}
    assert f.fetch(1100) == {}  # 304: the last answer
    assert calls == [None, "e1"]
    assert f.fetch(1400) is None  # offline and older than 5 min


def test_feed_min_interval_reuses_last_read():
    calls = []

    def opener(req, timeout):
        calls.append(1)
        return Resp(json.dumps({"header": {"timestamp": 1000}, "entity": []}).encode())

    f = Feed("https://example.test/t.json", parse_trips, opener=opener, min_interval=20)
    f.fetch(1000)
    f.fetch(1010)
    assert len(calls) == 1
    f.fetch(1021)
    assert len(calls) == 2


def test_positions_keep_vehicle_timestamp():
    j = {"entity": [{"vehicle": {"trip": {"tripId": "A"}, "stopId": "18000", "currentStatus": "STOPPED_AT",
                                 "timestamp": "990", "vehicle": {"label": "C3-1-PLATF.(6)"}}}]}
    assert parse_positions(j)["A"].at == 990
    assert Sighting("1", "STOPPED_AT", None) == Sighting("1", "STOPPED_AT", None, None)


def test_feed_cached_and_timestamp():
    calls = []

    def opener(req, timeout):
        calls.append(1)
        return Resp(json.dumps({"header": {"timestamp": 1000}, "entity": []}).encode())

    f = Feed("https://example.test/t.json", parse_trips, opener=opener)
    assert f.cached(1000) is None  # cached() never downloads
    assert calls == []
    f.fetch(1000)
    assert f.cached(1100) == ({}, 1000)  # data and its own header timestamp, together
    assert f.cached(1100, max_age=90) is None  # fresher limit for the board
    assert f.cached(1301) is None  # older than 5 min
    assert len(calls) == 1


def test_cached_does_not_wait_for_a_download():
    import threading
    started, release = threading.Event(), threading.Event()
    bodies = [json.dumps({"header": {"timestamp": 1000}, "entity": []}).encode(),
              json.dumps({"header": {"timestamp": 1030}, "entity": []}).encode()]

    def opener(req, timeout):
        if len(bodies) == 1:  # second download: hang until released
            started.set()
            release.wait(5)
        return Resp(bodies.pop(0))

    f = Feed("https://example.test/t.json", parse_trips, opener=opener, min_interval=0)
    f.fetch(1000)
    th = threading.Thread(target=f.fetch, args=(1030,))
    th.start()
    assert started.wait(2)
    t0 = __import__("time").monotonic()
    assert f.cached(1030) == ({}, 1000)  # the last good one, right away
    assert __import__("time").monotonic() - t0 < 0.5
    release.set()
    th.join(2)
    assert f.cached(1031) == ({}, 1030)
