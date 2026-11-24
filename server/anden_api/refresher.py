"""Keeps Renfe's feeds and the station index fresh in the background, so GET /live only reads
memory. Renfe is read only while someone asked for a station in the last `demand` seconds."""
from __future__ import annotations

import threading
import time


class Refresher:
    def __init__(self, trips, positions, stations, clock=time.time, every: float = 5.0,
                 demand: float = 120.0) -> None:
        self._trips, self._positions, self._stations = trips, positions, stations
        self._clock = clock
        self.every = every
        self._demand = demand
        self._asked: float | None = None
        self._wake = threading.Event()

    def touch(self, now: float, wake: bool = False) -> None:
        """A station was asked for; `wake` when there was nothing fresh to answer with."""
        self._asked = now
        if wake:
            self._wake.set()

    def tick(self) -> None:
        now = self._clock()
        asked = self._asked
        for job in ((lambda: self._trips.fetch(now), lambda: self._positions.fetch(now))
                    if asked is not None and 0 <= now - asked < self._demand else ()):
            try:
                job()  # Feed's 20 s cache avoids reading twice with the follow poller
            except Exception:
                pass
        try:
            self._stations.refresh()
        except Exception:
            pass

    def run(self, stop: threading.Event) -> None:
        while not stop.is_set():
            self.tick()
            self._wake.wait(self.every)
            self._wake.clear()
