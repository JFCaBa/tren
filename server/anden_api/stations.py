"""Which trains call at each station, from the timetables built nightly on this host
(tren repo, pipeline/vps/feed.sh → /opt/anden/data/current, a symlink to one generation)."""
from __future__ import annotations

import json
import os
import threading
from pathlib import Path


class StationTrips:
    """stop_id → trip ids. `refresh()` (the refresher thread) loads a new generation in full before
    publishing it; `get()` only reads the published index, never the disk."""

    def __init__(self, root: str | Path) -> None:
        self._root = Path(root)
        self._lock = threading.Lock()  # one refresh at a time
        self._gen: str | None = None
        self._failed: str | None = None  # a generation that could not be read: not retried
        self._index: dict[str, frozenset[str]] | None = None
        self._names: dict[str, tuple[str, str]] = {}

    @property
    def loaded(self) -> bool:
        return self._index is not None

    def get(self, stop_id: str) -> frozenset[str] | None:
        """Trips calling at `stop_id` (empty if unknown), or None while nothing is loaded."""
        index = self._index
        if index is None:
            return None
        return index.get(stop_id, frozenset())

    def known(self, stop_id: str) -> bool:
        index = self._index
        return index is not None and stop_id in index

    def names(self) -> dict[str, tuple[str, str]]:
        """stop_id → (station name, núcleo name) for /admin; empty while nothing is loaded."""
        return self._names

    def _load_feed(self, path: Path) -> dict:
        with open(path, encoding="utf-8") as f:
            return json.load(f)

    def refresh(self) -> bool:
        """Load the generation `current` points to, if new. False if it could not be read (the
        previous index stays)."""
        with self._lock:
            gen = os.path.realpath(self._root)
            if gen == self._gen and self._index is not None:
                return True
            if gen == self._failed:
                return False
            try:
                base = Path(gen)
                index = self._load_feed(base / "index.json")
                acc: dict[str, set[str]] = {}
                for n in index["nucleos"]:
                    feed = self._load_feed(base / n["feed"])
                    for t in feed["trips"]:
                        tid = t["id"]
                        for stop, _ in t["times"]:
                            acc.setdefault(stop, set()).add(tid)
                nucleos = {n["id"]: n.get("name") or "" for n in index["nucleos"]}
                names = {}
                for st in index.get("stops") or []:
                    ns = st.get("nucleos") or [None]
                    names[st["id"]] = (st.get("name") or st["id"], nucleos.get(ns[0], ""))
            except FileNotFoundError:
                return False  # not built yet (or mid-swap): try again next time
            except (OSError, ValueError, KeyError, TypeError):
                self._failed = gen
                return False
            self._index = {s: frozenset(t) for s, t in acc.items()}
            self._names = names
            self._gen = gen
            return True
