import threading

from anden_api.refresher import Refresher


class Counter:
    def __init__(self):
        self.n = 0

    def fetch(self, now):
        self.n += 1

    def refresh(self):
        self.n += 1


def make(now):
    t, p, s = Counter(), Counter(), Counter()
    return Refresher(t, p, s, clock=lambda: now[0], demand=120), t, p, s


def test_fetches_only_with_demand():
    now = [1000.0]
    r, t, p, s = make(now)
    r.tick()
    assert (t.n, p.n, s.n) == (0, 0, 1)  # no one asked: Renfe is not read
    r.touch(1000)
    r.tick()
    assert (t.n, p.n) == (1, 1)
    now[0] = 1121
    r.tick()
    assert (t.n, p.n) == (1, 1)  # demand older than 2 min


def test_touch_wakes_the_loop():
    now = [1000.0]
    r, t, p, s = make(now)
    r.every = 3600  # only a wake-up can make it tick again
    stop = threading.Event()
    th = threading.Thread(target=r.run, args=(stop,), daemon=True)
    th.start()
    r.touch(1000, wake=True)
    for _ in range(200):
        if t.n:
            break
        threading.Event().wait(0.01)
    stop.set()
    r.touch(1000, wake=True)
    th.join(2)
    assert t.n >= 1 and not th.is_alive()


def test_tick_survives_errors():
    class Boom:
        def fetch(self, now):
            raise RuntimeError("x")

        def refresh(self):
            raise RuntimeError("x")

    now = [1000.0]
    r = Refresher(Boom(), Boom(), Boom(), clock=lambda: now[0])
    r.touch(1000)
    r.tick()  # no exception
