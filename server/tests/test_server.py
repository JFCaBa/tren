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
