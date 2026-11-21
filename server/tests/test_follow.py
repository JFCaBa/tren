from anden_api.follow import FollowStore, Poller
from anden_api.renfe import Sighting, Trip

T0 = 1_800_000_000.0
TOKEN, ACT = "ab" * 32, "ef" * 128
STOPS = [["10000", "Chamartín"], ["18000", "Atocha"], ["18002", "Getafe Centro"], ["18101", "Mine"]]


def train(scheduled=T0 + 900, trip="T1"):
    return {"tripId": trip, "stopId": "18101", "scheduled": int(scheduled), "title": "08:12 a Guadalajara",
            "usual": "2", "stops": STOPS}


class Clock:
    def __init__(self):
        self.t = T0

    def __call__(self):
        return self.t


class FeedFake:
    def __init__(self):
        self.value = {}
        self.calls = 0

    def fetch(self, now):
        self.calls += 1
        return self.value


class Push:
    def __init__(self):
        self.sent, self.activities = [], []
        self.result, self.activity_result = "ok", "ok"

    def send(self, token, env, title, body):
        self.sent.append((title, body))
        return self.result

    def send_activity(self, token, env, state, *, event="update", priority=5, stale, dismissal=None):
        self.activities.append({"token": token, "state": state, "event": event, "priority": priority,
                                "stale": stale, "dismissal": dismissal})
        return self.activity_result


def setup(activity=ACT):
    store, trips, pos, push, clock = FollowStore(), FeedFake(), FeedFake(), Push(), Clock()
    store.upsert(TOKEN, "production", train(), T0, activity)
    return store, trips, pos, push, clock, Poller(store, trips, pos, push, clock=clock)


def ends(push):
    return [a for a in push.activities if a["event"] == "end"]


def test_first_reading_no_alert_then_platform_and_delay():
    store, trips, pos, push, clock, p = setup()
    trips.value = {"T1": Trip(0, False)}
    p.tick()
    assert push.sent == []
    trips.value = {"T1": Trip(420, False)}
    pos.value = {"T1": Sighting("18101", "INCOMING_AT", "4")}
    clock.t += 30
    p.tick()
    assert push.sent == [("08:12 a Guadalajara", "Vía 4\nRetraso de 7 min")]


def test_live_activity_state_and_where():
    store, trips, pos, push, clock, p = setup()
    trips.value = {"T1": Trip(300, False)}
    pos.value = {"T1": Sighting("18000", "STOPPED_AT", None)}
    p.tick()
    p.tick()
    (a,) = push.activities
    assert a["state"] == {"departs": int(T0) + 900 + 300, "status": "Retraso 5 min", "platform": "2", "usual": True,
                          "where": "En Atocha · a 2 paradas", "cancelled": False}
    assert a["priority"] == 5 and a["stale"] == a["state"]["departs"] + 600
    pos.value = {"T1": Sighting("18101", "INCOMING_AT", "4")}
    p.tick()
    assert push.activities[-1]["priority"] == 10
    assert push.activities[-1]["state"]["platform"] == "4"


def test_platform_sticks_once_seen():
    store, trips, pos, push, clock, p = setup()
    pos.value = {"T1": Sighting("18101", "STOPPED_AT", "4")}
    p.tick()
    pos.value = {"T1": Sighting("18101", "STOPPED_AT", None)}
    p.tick()
    assert push.activities[-1]["state"]["platform"] == "4"
    assert push.sent == []


def test_ends_after_departure_once():
    store, trips, pos, push, clock, p = setup()
    trips.value = {"T1": Trip(60, False)}
    p.tick()
    clock.t = T0 + 900 + 60 + 121
    p.tick()
    p.tick()
    assert len(store) == 0
    (e,) = ends(push)
    assert e["dismissal"] == int(clock.t) + 600


def test_cancelled_alert_then_end():
    store, trips, pos, push, clock, p = setup()
    p.tick()
    trips.value = {"T1": Trip(None, True)}
    p.tick()
    assert push.sent == [("08:12 a Guadalajara", "Cancelado")]
    clock.t += 121
    p.tick()
    p.tick()
    assert len(store) == 0
    assert len(ends(push)) == 1


def test_delete_ends_activity_and_late_token_keeps_readings():
    store, trips, pos, push, clock, p = setup(activity=None)
    trips.value = {"T1": Trip(0, False)}
    p.tick()
    store.upsert(TOKEN, "production", train(), T0, ACT)  # the late Live Activity token
    trips.value = {"T1": Trip(60, False)}
    p.tick()
    assert push.sent == []  # readings kept: no alert for a 1-min change
    assert len(push.activities) == 1
    store.remove(TOKEN)
    p.tick()
    p.tick()
    assert [e["dismissal"] for e in ends(push)] == [int(clock.t)]


def test_no_feeds_no_follows_no_fetch():
    store, trips, pos, push, clock = FollowStore(), FeedFake(), FeedFake(), Push(), Clock()
    Poller(store, trips, pos, push, clock=clock).tick()
    assert trips.calls == 0


def test_feeds_down_keep_state():
    store, trips, pos, push, clock, p = setup()
    trips.value = pos.value = None
    p.tick()
    assert push.sent == [] and push.activities == []
    assert len(store) == 1


def test_three_hours():
    store, trips, pos, push, clock, p = setup()
    store.upsert(TOKEN, "production", train(scheduled=T0 + 5 * 3600), T0, ACT)
    p.tick()
    clock.t += 3 * 3600
    p.tick()
    assert len(store) == 0


def test_device_token_gone_removes_follow():
    store, trips, pos, push, clock, p = setup()
    p.tick()
    push.result = "gone"
    pos.value = {"T1": Sighting("18101", "INCOMING_AT", "4")}
    p.tick()
    assert len(store) == 0


def test_activity_gone_keeps_alerts():
    store, trips, pos, push, clock, p = setup()
    push.activity_result = "gone"
    p.tick()
    pos.value = {"T1": Sighting("18101", "INCOMING_AT", "4")}
    p.tick()
    assert len(push.activities) == 1 and push.sent == [("08:12 a Guadalajara", "Vía 4")]


def test_not_ended_while_renfe_still_places_it_before_us():
    store, trips, pos, push, clock, p = setup()
    trips.value = {"T1": Trip(None, False)}  # Renfe has not published the delay yet
    pos.value = {"T1": Sighting("18002", "STOPPED_AT", None)}
    p.tick()
    clock.t = T0 + 900 + 300
    p.tick()
    assert len(store) == 1
    pos.value = {"T1": Sighting("18101", "STOPPED_AT", "3")}  # standing at ours: about to leave
    p.tick()
    assert len(store) == 0


def test_end_all_on_shutdown():
    store, trips, pos, push, clock, p = setup()
    p.tick()
    p.end_all()
    assert len(store) == 0 and len(ends(push)) == 1


def test_slow_delay_creep_alerts():
    store, trips, pos, push, clock, p = setup()
    for d in (0, 60, 120, 180):
        trips.value = {"T1": Trip(d, False)}
        p.tick()
    assert push.sent == [("08:12 a Guadalajara", "Retraso de 2 min")]  # 0 → 1 → 2 min adds up


def test_activity_error_is_retried():
    store, trips, pos, push, clock, p = setup()
    push.activity_result = "error"
    p.tick()
    push.activity_result = "ok"
    p.tick()
    assert len(push.activities) == 2


def test_no_end_by_time_without_positions():
    store, trips, pos, push, clock, p = setup()
    pos.value = None
    trips.value = {"T1": Trip(None, False)}
    p.tick()
    clock.t = T0 + 900 + 300
    p.tick()
    assert len(store) == 1


def test_cancelled_ends_even_with_feeds_down():
    store, trips, pos, push, clock, p = setup()
    trips.value = {"T1": Trip(None, True)}
    p.tick()
    trips.value = pos.value = None
    clock.t += 121
    p.tick()
    assert len(store) == 0


def test_trip_missing_keeps_delay():
    store, trips, pos, push, clock, p = setup()
    trips.value = {"T1": Trip(600, False)}
    p.tick()
    trips.value = {}
    p.tick()
    assert push.activities[-1]["state"]["status"] == "Retraso 10 min"


def test_full_store_evicts_oldest():
    store = FollowStore(max_follows=2)
    store.upsert("a" * 64, "production", train(trip="A1"), T0, None)
    store.upsert("b" * 64, "production", train(trip="B1"), T0 + 1, None)
    assert store.upsert("c" * 64, "production", train(trip="C1"), T0 + 2, None) == "ok"
    assert sorted(f.token[0] for f in store.all()) == ["b", "c"]
