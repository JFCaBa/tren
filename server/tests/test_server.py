import http.client
import io
import json
import threading

import pytest

from anden_api.follow import FollowStore
from anden_api.server import make_server

NOW = 1_800_000_000.0
TOKEN = "ab" * 32


def body(**over):
    b = {"token": TOKEN, "env": "sandbox", "tripId": "3019L23525C3", "stopId": "18101", "title": "08:12 a Guadalajara",
         "scheduled": int(NOW + 600), "startedAt": int(NOW * 1000), "usual": "2",
         "stops": [["18000", "Atocha"], ["18101", "Mine"]]}
    b.update(over)
    return {k: v for k, v in b.items() if v is not None}


@pytest.fixture
def api():
    store = FollowStore()
    log = io.StringIO()
    s = make_server("127.0.0.1", 0, follows=store, push=object(), clock=lambda: NOW, log=log)
    threading.Thread(target=s.serve_forever, daemon=True).start()
    yield s, store, log
    s.shutdown()
    s.server_close()


def req(s, method, path, data=None, raw=None):
    c = http.client.HTTPConnection("127.0.0.1", s.server_address[1], timeout=10)
    payload = raw if raw is not None else (json.dumps(data).encode() if data is not None else None)
    c.request(method, path, body=payload, headers={"Content-Length": str(len(payload or b""))})
    r = c.getresponse()
    out = r.read()
    c.close()
    return r.status, out


def test_health(api):
    assert req(api[0], "GET", "/health")[0] == 200


def test_follow_and_delete(api):
    s, store, log = api
    assert req(s, "POST", "/follow", body(activityToken="EF" * 128))[0] == 200
    (f,) = store.all()
    assert f.activity == "ef" * 128 and f.train["stops"][-1] == ["18101", "Mine"]
    assert req(s, "DELETE", "/follow", {"token": TOKEN})[0] == 204
    assert len(store) == 0
    assert log.getvalue() == ""


@pytest.mark.parametrize("over", [
    {"token": "ab" * 31}, {"env": "prod"}, {"tripId": "a/b"}, {"stopId": "x"}, {"title": ""},
    {"title": "x" * 81}, {"scheduled": int(NOW - 4 * 3600)}, {"scheduled": int(NOW + 7 * 3600)},
    {"scheduled": 1.5}, {"startedAt": True}, {"usual": "x" * 9}, {"stops": []},
    {"stops": [["18000", "Atocha"]]},  # must end at stopId
    {"stops": [["18101"]]}, {"activityToken": "a" * 513},
])
def test_bad_requests(api, over):
    assert req(api[0], "POST", "/follow", body(**over))[0] == 400
    assert len(api[1]) == 0


def test_bad_json(api):
    assert req(api[0], "POST", "/follow", raw=b"{nope")[0] == 400
    assert req(api[0], "POST", "/follow", raw=b"x" * 20000)[0] == 400


def test_started_too_long_ago_410(api):
    assert req(api[0], "POST", "/follow", body(startedAt=int((NOW - 3 * 3600) * 1000)))[0] == 410


class FakeFeed:
    def __init__(self, value):
        self.value = value

    def fetch(self, now):
        return self.value


def test_train_reading_endpoint():
    from anden_api.renfe import Sighting, Trip
    trips = FakeFeed({"TR1": Trip(300, False)})
    pos = FakeFeed({"TR1": Sighting("18101", "INCOMING_AT", "4"), "TR2": Sighting("18000", "STOPPED_AT", "1")})
    s = make_server("127.0.0.1", 0, follows=None, push=None, clock=lambda: NOW, trips=trips, positions=pos)
    threading.Thread(target=s.serve_forever, daemon=True).start()
    try:
        st, out = req(s, "GET", "/train/TR1/18101")
        assert st == 200 and json.loads(out) == {"live": True, "delay": 300, "cancelled": False,
                                                 "seen": {"stopId": "18101", "status": "INCOMING_AT", "platform": "4"}}
        st, out = req(s, "GET", "/train/TR2/18101")  # a platform elsewhere is not ours
        assert json.loads(out)["seen"]["platform"] is None
        assert json.loads(req(s, "GET", "/train/TR9/18101")[1]) == {"live": True, "delay": None, "cancelled": False, "seen": None}
        assert req(s, "GET", "/train/a%2Fb/18101")[0] == 404
    finally:
        s.shutdown()
        s.server_close()


class FakeLiveFeed:
    def __init__(self, value, ts=NOW - 30):
        self.value, self.ts = value, ts

    def cached(self, now, max_age=300):
        if self.value is None or self.ts is None or now - self.ts > max_age:
            return None
        return self.value, self.ts

    def fetch(self, now):
        return self.value


class FakeStations:
    def __init__(self, index):
        self.index = index

    def get(self, stop):
        return None if self.index is None else self.index.get(stop, frozenset())

    def known(self, stop):
        return self.index is not None and stop in self.index


class FakeRefresher:
    def __init__(self):
        self.touched = []

    def touch(self, now, wake=False):
        self.touched.append((now, wake))


def live_server(trips, positions, index, log=None):
    r = FakeRefresher()
    s = make_server("127.0.0.1", 0, follows=None, push=None, clock=lambda: NOW, log=log or io.StringIO(),
                    trips=trips, positions=positions, stations=FakeStations(index), refresher=r)
    threading.Thread(target=s.serve_forever, daemon=True).start()
    return s, r


def stop_server(s):
    s.shutdown()
    s.server_close()


INDEX = {"18000": frozenset({"TR1", "TR2"}), "18101": frozenset({"TR3"})}


def test_station_reading_filters_trips_and_platforms():
    from anden_api.renfe import Sighting, Trip
    from anden_api.server import station_reading
    trips = {"TR1": Trip(120, False), "TR2": Trip(None, True), "TR3": Trip(60, False)}
    pos = {"TR1": Sighting("18000", "INCOMING_AT", "4", 990), "TR2": Sighting("18000", "STOPPED_AT", None),
           "TR3": Sighting("18000", "STOPPED_AT", "1"), "TR9": Sighting("18101", "STOPPED_AT", "2")}
    out = station_reading(trips, 1000, pos, 995, INDEX["18000"], "18000")
    assert out == {"tripsAt": 1000,
                   "trips": {"TR1": {"delay": 120, "cancelled": False}, "TR2": {"delay": None, "cancelled": True}},
                   "positionsAt": 995,
                   "platforms": {"TR1": {"platform": "4", "at": 990}, "TR3": {"platform": "1", "at": 995}}}
    assert station_reading(trips, 1000, None, None, INDEX["18000"], "18000")["platforms"] == {}


def test_live_ok():
    from anden_api.renfe import Sighting, Trip
    s, r = live_server(FakeLiveFeed({"TR1": Trip(300, False)}),
                       FakeLiveFeed({"TR1": Sighting("18000", "STOPPED_AT", "6", int(NOW - 40))}, ts=NOW - 35), INDEX)
    try:
        st, out = req(s, "GET", "/live/18000")
        assert st == 200
        assert json.loads(out) == {"tripsAt": int(NOW - 30), "trips": {"TR1": {"delay": 300, "cancelled": False}},
                                   "positionsAt": int(NOW - 35),
                                   "platforms": {"TR1": {"platform": "6", "at": int(NOW - 40)}}}
        assert r.touched and r.touched[0][0] == NOW
    finally:
        stop_server(s)


def test_live_positions_missing_still_200():
    from anden_api.renfe import Trip
    s, _ = live_server(FakeLiveFeed({"TR1": Trip(0, False)}), FakeLiveFeed(None, ts=None), INDEX)
    try:
        st, out = req(s, "GET", "/live/18000")
        assert st == 200 and json.loads(out)["positionsAt"] is None and json.loads(out)["platforms"] == {}
    finally:
        stop_server(s)


def test_live_503_without_index():
    s, _ = live_server(FakeLiveFeed({}), FakeLiveFeed({}), None)
    try:
        assert req(s, "GET", "/live/18000")[0] == 503
    finally:
        stop_server(s)


def test_live_503_when_renfe_down_or_frozen():
    # Feed.cached() is None both when Renfe is unreachable and when its feed is > 5 min old.
    s, r = live_server(FakeLiveFeed(None, ts=None), FakeLiveFeed({}), INDEX)
    try:
        assert req(s, "GET", "/live/18000")[0] == 503
        assert r.touched[-1][1] is True  # no data: wake the refresher now
    finally:
        stop_server(s)


def test_live_404_unknown_station():
    s, _ = live_server(FakeLiveFeed({}), FakeLiveFeed({}), INDEX)
    try:
        assert req(s, "GET", "/live/99999")[0] == 404
        assert req(s, "GET", "/live/a")[0] == 404
        assert req(s, "GET", "/live/18000/x")[0] == 404
    finally:
        stop_server(s)


def test_live_not_logged():
    from anden_api.renfe import Trip
    log = io.StringIO()
    s, _ = live_server(FakeLiveFeed({"TR1": Trip(0, False)}), FakeLiveFeed({}), INDEX, log=log)
    try:
        req(s, "GET", "/live/18000")
        req(s, "GET", "/live/99999")
        assert log.getvalue() == ""
    finally:
        stop_server(s)


def test_live_off_without_stations():
    s = make_server("127.0.0.1", 0, follows=None, push=None, clock=lambda: NOW)
    threading.Thread(target=s.serve_forever, daemon=True).start()
    try:
        assert req(s, "GET", "/live/18000")[0] == 404
    finally:
        stop_server(s)


def test_live_old_renfe_is_503_and_wakes():
    """After a quiet spell the cache can be minutes old: the app would call it stale, so the
    server says unavailable (the app reads Renfe) and refreshes now."""
    from anden_api.renfe import Trip
    s, r = live_server(FakeLiveFeed({"TR1": Trip(0, False)}, ts=NOW - 100), FakeLiveFeed({}), INDEX)
    try:
        assert req(s, "GET", "/live/18000")[0] == 503
        assert r.touched[-1] == (NOW, True)
    finally:
        stop_server(s)


def test_live_old_positions_left_out():
    from anden_api.renfe import Sighting, Trip
    s, _ = live_server(FakeLiveFeed({"TR1": Trip(0, False)}),
                       FakeLiveFeed({"TR1": Sighting("18000", "STOPPED_AT", "6")}, ts=NOW - 100), INDEX)
    try:
        st, out = req(s, "GET", "/live/18000")
        assert st == 200 and json.loads(out)["positionsAt"] is None and json.loads(out)["platforms"] == {}
    finally:
        stop_server(s)
