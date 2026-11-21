from anden_api.live import changes, content_state, status_text, where_text
from anden_api.renfe import Sighting

STOPS = [("10000", "Chamartín"), ("18000", "Atocha"), ("18001", "Méndez Álvaro"), ("18002", "Getafe Centro"), ("18101", "Mine")]


def test_where_texts():
    assert where_text(STOPS, "18101", Sighting("18001", "STOPPED_AT", None)) == "En Méndez Álvaro · a 2 paradas"
    assert where_text(STOPS, "18101", Sighting("18002", "IN_TRANSIT_TO", None)) == "Hacia Getafe Centro · a 1 parada"
    assert where_text(STOPS, "18101", Sighting("18002", "INCOMING_AT", None)) == "Hacia Getafe Centro · a 1 parada"
    assert where_text(STOPS, "18101", Sighting("18101", "INCOMING_AT", "3")) == "Llegando"
    assert where_text(STOPS, "18101", Sighting("18101", "STOPPED_AT", "3")) == "En la estación"


def test_where_unknown():
    assert where_text(STOPS, "18101", None) is None
    assert where_text(STOPS, "18101", Sighting("99999", "STOPPED_AT", None)) is None  # past us or another line
    assert where_text(STOPS, "18002", Sighting("18001", "STOPPED_AT", None)) is None  # list must end at our stop
    assert where_text([], "18101", Sighting("18001", "STOPPED_AT", None)) is None


def test_status():
    assert status_text(None, False) == ""
    assert status_text(20, False) == "A su hora"
    assert status_text(300, False) == "Retraso 5 min"
    assert status_text(300, True) == "Cancelado"


def r(delay=None, cancelled=False, platform=None):
    return {"delay": delay, "cancelled": cancelled, "platform": platform}


def test_changes():
    assert changes(None, r(600, platform="3")) == []
    assert changes(r(), r(platform="3")) == ["Vía 3"]
    assert changes(r(platform="3"), r(platform="5")) == ["Cambio de vía: 3 → 5"]
    assert changes(r(60), r(420)) == ["Retraso de 7 min"]
    assert changes(r(420), r(60)) == ["Va a su hora"]
    assert changes(r(240), r(300)) == []  # a 1-minute swing is noise
    assert changes(r(None), r(300)) == ["Retraso de 5 min"]
    assert changes(r(None), r(60)) == []
    assert changes(r(), r(cancelled=True, platform="4")) == ["Cancelado"]
    assert changes(r(cancelled=True), r(cancelled=True)) == []
    assert changes(r(0, platform="3"), r(300, platform="5")) == ["Cambio de vía: 3 → 5", "Retraso de 5 min"]


def test_content_state():
    s = content_state(1000, "2", r(300), "Hacia Getafe Centro · a 1 parada")
    assert s == {"departs": 1300, "status": "Retraso 5 min", "platform": "2", "usual": True,
                 "where": "Hacia Getafe Centro · a 1 parada", "cancelled": False}
    s = content_state(1000, "2", r(0, platform="7"), None)
    assert (s["platform"], s["usual"]) == ("7", False)
    s = content_state(1000, None, r(cancelled=True), "x")
    assert s == {"departs": None, "status": "Cancelado", "platform": None, "usual": False, "where": None,
                 "cancelled": True}


def test_rounding_matches_dart():
    from anden_api.live import delay_minutes
    assert [delay_minutes(x) for x in (90, 150, -90, 29, 30)] == [2, 3, -2, 0, 1]
