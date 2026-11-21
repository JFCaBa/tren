"""Texts and Live Activity state for a followed train; the same strings as the app's
lib/domain/position.dart and lib/follow/follow_logic.dart."""
from __future__ import annotations

from .renfe import Sighting

DELAY_STEP = 2  # minutes: smaller swings in Renfe's delay are noise, not news


def _paradas(n: int) -> str:
    return "a 1 parada" if n == 1 else f"a {n} paradas"


def where_text(stops: list[tuple[str, str]], stop_id: str, pos: Sighting | None) -> str | None:
    """Where the train is, against its stops from its first one up to and including `stop_id`."""
    if pos is None or not stops or stops[-1][0] != stop_id:
        return None
    ids = [s for s, _ in stops]
    if pos.stop_id not in ids:
        return None
    i, j = ids.index(pos.stop_id), len(ids) - 1
    if i == j:
        return "En la estación" if pos.status == "STOPPED_AT" else "Llegando"
    name = stops[i][1]
    lead = "En" if pos.status == "STOPPED_AT" else "Hacia"
    return f"{lead} {name} · {_paradas(j - i)}"


def delay_minutes(delay: int | None) -> int | None:
    """Rounded half away from zero, like Dart's round(), so the app and server agree."""
    if delay is None:
        return None
    m = int(abs(delay) / 60 + 0.5)
    return m if delay >= 0 else -m


def status_text(delay: int | None, cancelled: bool) -> str:
    if cancelled:
        return "Cancelado"
    m = delay_minutes(delay)
    if m is None:
        return ""
    return f"Retraso {m} min" if m >= 1 else "A su hora"


def changes(before: dict | None, after: dict) -> list[str]:
    """Alerts between two readings {delay, cancelled, platform}: platform first, then time.
    A newly cancelled train gives only the cancellation. None before = first reading: nothing."""
    if before is None:
        return []
    if after["cancelled"]:
        return [] if before["cancelled"] else ["Cancelado"]
    out: list[str] = []
    p0, p1 = before.get("platform"), after.get("platform")
    if p1 is not None and p1 != p0:
        out.append(f"Vía {p1}" if p0 is None else f"Cambio de vía: {p0} → {p1}")
    m0, m1 = delay_minutes(before.get("delay")), delay_minutes(after.get("delay"))
    if m1 is not None:
        if m0 is None:
            if m1 >= DELAY_STEP:
                out.append(f"Retraso de {m1} min")
        elif abs(m1 - m0) >= DELAY_STEP:
            out.append(f"Retraso de {m1} min" if m1 >= DELAY_STEP else "Va a su hora")
    return out


def content_state(scheduled: int, usual: str | None, reading: dict, where: str | None) -> dict:
    """The Live Activity's state: keys as TrainActivityAttributes.ContentState (Swift)."""
    cancelled = reading["cancelled"]
    live = reading.get("platform")
    return {
        "departs": None if cancelled else scheduled + (reading.get("delay") or 0),
        "status": status_text(reading.get("delay"), cancelled),
        "platform": live or usual,
        "usual": live is None and usual is not None,
        "where": None if cancelled else where,
        "cancelled": cancelled,
    }
