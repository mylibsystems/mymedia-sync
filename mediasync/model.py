"""Shared data model: tasks and the live progress state read by the UI."""
from __future__ import annotations

import threading
import time
from dataclasses import dataclass, field
from collections import deque
from itertools import islice
from typing import Callable

# Phase keys in the order they run. (label, description)
PHASES = [
    ("scan", "Scan & verify", "inventory every input and output, confirm each is complete"),
    ("ingest", "Ingest", "router → local disk (copy only, router untouched)"),
    ("backup", "Backup", "UNSORTED/CAMERA → CAMERA (protected archive)"),
    ("desktop", "Desktop", "CAMERA / UNSORTED → LIBRARY.DESKTOP"),
    ("portable", "Portable", "LIBRARY.DESKTOP → LIBRARY.PORTABLE"),
    ("finalize", "Finalize", "playlists, cleanup, final confirmation"),
]
PHASE_KEYS = [p[0] for p in PHASES]
# Prior speed (units/hour) used for ETAs before any measurement exists.
PRIOR_RATE_PER_HOUR = {"ingest": 600.0, "backup": 6000.0, "desktop": 400.0, "portable": 600.0, "finalize": 1e9}
# Phases that count towards the overall "UNSORTED → desktop → portable" bar.
WORK_PHASES = ("ingest", "backup", "desktop", "portable")


@dataclass
class Task:
    id: int
    phase: str
    kind: str                      # photo | video | audio | file
    name: str                      # shown in the UI
    src: str
    size: int = 0
    argv: list | None = None       # shell worker command; None = done natively in Python
    env: dict | None = None
    units: int = 1
    meta: dict = field(default_factory=dict)
    # ---- runtime ----
    state: str = "queued"          # queued | running | done | failed | skipped
    step: str = ""
    pct: float | None = None       # 0..100 when known
    bytes_done: int = 0
    speed: str = ""
    started: float = 0.0
    finished: float = 0.0
    note: str = ""
    attempts: int = 0

    @property
    def elapsed(self) -> float:
        if not self.started:
            return 0.0
        return (self.finished or time.time()) - self.started


class PhaseState:
    def __init__(self, key: str, label: str, desc: str):
        self.key, self.label, self.desc = key, label, desc
        self.state = "pending"     # pending | running | done | skipped
        self.total = 0             # units planned
        self.done = 0              # units completed OK
        self.failed = 0
        self.skipped = 0           # confirmed already complete (counted as done in the bar)
        self.started = 0.0
        self.finished = 0.0
        self.samples: list[tuple[float, int]] = []   # (time, done) for the rolling rate
        self.detail = ""

    @property
    def completed(self) -> int:
        return self.done + self.failed

    @property
    def active_seconds(self) -> float:
        if not self.started:
            return 0.0
        return (self.finished or time.time()) - self.started


class Status:
    """Everything the UI needs; all mutation goes through the lock."""

    def __init__(self, prior_rates: dict | None = None):
        self.lock = threading.RLock()
        self.phases = {k: PhaseState(k, lbl, d) for k, lbl, d in PHASES}
        self.active: dict[int, Task] = {}
        self.queue = deque()                   # waiting tasks of the running phase (head first)
        self.slots = 4                         # fixed number of worker rows on screen (never changes)
        self.workers_now = 0
        self.started = time.time()
        self.finished = 0.0
        self.paused = False
        self.stop_requested = False
        self.state = "starting"                # starting | running | finishing | done | stopped | failed
        self.current_phase = ""
        self.message = ""
        self.prior_rates = prior_rates or {}
        self.warnings = 0
        self.errors = 0
        self.collisions = 0
        self.bytes_done = 0
        self.bytes_total = 0
        self.summary: list[str] = []

    # ---- phase control --------------------------------------------------
    def begin_phase(self, key: str, units: int, detail: str = "") -> None:
        """Start a phase with `units` still to do. Units already credited to it (work that a
        combined worker finished earlier) are kept, so the totals stay exact."""
        with self.lock:
            ph = self.phases[key]
            credited = ph.done + ph.failed + ph.skipped
            ph.state = "running"
            ph.total = credited + units
            ph.started, ph.finished, ph.detail = time.time(), 0.0, detail
            ph.samples = [(ph.started, credited)]
            self.current_phase = key
            self.message = detail

    def set_total(self, key: str, total: int) -> None:
        with self.lock:
            self.phases[key].total = total

    def end_phase(self, key: str, state: str = "done") -> None:
        with self.lock:
            ph = self.phases[key]
            ph.state, ph.finished = state, time.time()

    def plan_phase(self, key: str, total: int, detail: str = "") -> None:
        """Planned (not yet started) work, so the overall bar knows the full size up front."""
        with self.lock:
            ph = self.phases[key]
            ph.total = total
            ph.detail = detail

    def advance(self, key: str, *, done: int = 0, failed: int = 0, skipped: int = 0) -> None:
        with self.lock:
            ph = self.phases[key]
            ph.done += done
            ph.failed += failed
            ph.skipped += skipped
            now = time.time()
            ph.samples.append((now, ph.completed + ph.skipped))
            cutoff = now - 600
            while len(ph.samples) > 2 and ph.samples[1][0] < cutoff:
                ph.samples.pop(0)

    # ---- rates / ETA ----------------------------------------------------
    def rate_info(self, key: str) -> tuple[float | None, bool]:
        """(units per second, measured?). Measured = from this run; else a prior from past runs/defaults."""
        with self.lock:
            ph = self.phases[key]
            s = ph.samples
            if ph.state == "running" and len(s) >= 2:
                dt = s[-1][0] - s[0][0]
                du = s[-1][1] - s[0][1]
                if dt >= 20 and du > 0:
                    return du / dt, True
                if ph.active_seconds >= 20 and (ph.completed + ph.skipped) > 0:
                    return (ph.completed + ph.skipped) / ph.active_seconds, True
            prior = self.prior_rates.get(key)
            if prior:
                return prior, False
            default = PRIOR_RATE_PER_HOUR.get(key)
            return (default / 3600.0 if default else None), False

    def rate(self, key: str) -> float | None:
        return self.rate_info(key)[0]

    def remaining(self, key: str) -> int:
        ph = self.phases[key]
        return max(0, ph.total - ph.completed - ph.skipped) if ph.state != "done" else 0

    def phase_eta(self, key: str) -> float | None:
        rem = self.remaining(key)
        if rem == 0:
            return 0.0
        r = self.rate(key)
        return rem / r if r else None

    def overall(self) -> dict:
        """Counts and a time-weighted percentage across ingest → backup → desktop → portable."""
        with self.lock:
            total = done = 0
            weight_total = weight_done = 0.0
            eta = 0.0
            eta_known = True
            approx = False
            for key in WORK_PHASES:
                ph = self.phases[key]
                if ph.state == "skipped" or ph.total == 0:
                    continue
                completed = min(ph.total, ph.completed + ph.skipped)
                total += ph.total
                done += completed
                r = self.rate(key) or (PRIOR_RATE_PER_HOUR.get(key, 600.0) / 3600.0)
                w = 1.0 / r                       # seconds one unit is expected to take
                weight_total += ph.total * w
                weight_done += completed * w
                rem = self.phase_eta(key)
                if rem is None:
                    eta_known = False
                else:
                    eta += rem
                    if self.remaining(key) > 0 and not self.rate_info(key)[1]:
                        approx = True
            pct = (100.0 * weight_done / weight_total) if weight_total > 0 else (100.0 if self.state == "done" else 0.0)
            return {"total": total, "done": done, "pct": min(100.0, pct),
                    "eta": eta if eta_known else None, "eta_approx": approx,
                    "elapsed": (self.finished or time.time()) - self.started}

    # ---- snapshot for the UI --------------------------------------------
    def snapshot(self) -> dict:
        with self.lock:
            return {
                "state": self.state, "paused": self.paused, "message": self.message,
                "current": self.current_phase, "slots": self.slots, "workers_now": self.workers_now,
                "phases": [(p.key, p.label, p.state, p.total, p.done, p.failed, p.skipped,
                            self.rate(p.key), self.phase_eta(p.key), p.detail, p.active_seconds)
                           for p in self.phases.values()],
                "active": [self._task_view(t) for t in sorted(self.active.values(), key=lambda t: t.started)],
                "queue": [(t.name, t.phase, t.kind, t.size) for t in islice(self.queue, 3000)],
                "queue_len": len(self.queue),
                "overall": self.overall(),
                "warnings": self.warnings, "errors": self.errors, "collisions": self.collisions,
                "summary": list(self.summary),
            }

    @staticmethod
    def _task_view(t: Task) -> dict:
        return {"name": t.name, "phase": t.phase, "kind": t.kind, "step": t.step, "pct": t.pct,
                "elapsed": t.elapsed, "speed": t.speed, "size": t.size, "bytes_done": t.bytes_done,
                "attempts": t.attempts}
