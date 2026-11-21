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
