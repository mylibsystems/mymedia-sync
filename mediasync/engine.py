"""Runs the existing shell workers (orginize.sh / portablize.sh ...) UNCHANGED and turns their
output into live per-file progress. No encoder command line is built or altered here."""
from __future__ import annotations

import os
import re
import select
import signal
import subprocess
import threading
import time
from dataclasses import dataclass, field

from .model import Task

_TIME = re.compile(r"time=(\d+):(\d+):(\d+(?:\.\d+)?)")
_DUR = re.compile(r"Duration:\s*(\d+):(\d+):(\d+(?:\.\d+)?)")
_SPEED = re.compile(r"speed=\s*([0-9.]+)x")
_WRITTEN = re.compile(r"^\[OK\] (?:Written|Copied FLAC|Remuxed desktop[^:]*): (.+)$")
_TAGGED = re.compile(r"^\[(START|OK|WARN|ERROR|SKIP|KEEP|MOVED|DONE|INFO)\]\s*(.*)$")

# Messages that are normal noise, not problems (kept in the log at INFO level only).
_BENIGN = (
    re.compile(r"exiftool failed .*Bad format"),
    re.compile(r"No audio track matched"),
    re.compile(r"Maker notes could not be parsed"),
    re.compile(r"Odd offset for"),
)

_STEP_BY_COMMAND = {
    "ffmpeg": "encoding", "ffprobe": "probing", "magick": "converting image", "convert": "converting image",
    "mogrify": "orienting image", "identify": "reading image", "exiftool": "metadata",
    "AtomicParsley": "tagging", "metaflac": "tagging", "flac": "encoding flac", "fpcalc": "fingerprint",
    "curl": "online lookup", "wget": "online lookup", "cp": "copying", "mv": "moving", "cmp": "comparing",
    "sha256sum": "checksum", "eyeD3": "tagging",
}


@dataclass
class Result:
    rc: int = 0
    outputs: list = field(default_factory=list)
    problems: list = field(default_factory=list)       # (level, message)
    skipped: bool = False
    tail: list = field(default_factory=list)


def _children(pid: int) -> list[int]:
    out = []
    try:
        for tid in os.listdir(f"/proc/{pid}/task"):
            try:
                with open(f"/proc/{pid}/task/{tid}/children") as f:
                    out += [int(x) for x in f.read().split()]
            except OSError:
                continue
    except OSError:
        pass
    return out


def _comm(pid: int) -> str:
    try:
        with open(f"/proc/{pid}/comm") as f:
            return f.read().strip()
    except OSError:
        return ""


def current_step(root_pid: int) -> str:
    """Name what the worker is running right now (deepest known tool). Linux /proc; '' elsewhere."""
    if not os.path.isdir("/proc"):
        return ""
    best, depth = "", -1
    stack = [(root_pid, 0)]
    seen = 0
    while stack and seen < 200:
        pid, d = stack.pop()
        seen += 1
        step = _STEP_BY_COMMAND.get(_comm(pid), "")
        if step and d >= depth:
            best, depth = step, d
        stack += [(c, d + 1) for c in _children(pid)]
    return best


_STEP_NAMES = (("Camera video converting", "video convert"), ("Photo converting", "photo convert"),
               ("Audio converting", "audio convert"), ("Video converting", "video convert"),
               ("Portable from desktop", "portable derive"), ("Album context", "album lookup"))


def _short_step(text: str) -> str:
    for long, short in _STEP_NAMES:
        if text.startswith(long):
            return short
    return text.split(":", 1)[0][:20]


def _seconds(m) -> float:
    return int(m.group(1)) * 3600 + int(m.group(2)) * 60 + float(m.group(3))


class Engine:
    def __init__(self, status, log, stop: threading.Event):
        self.status, self.log, self.stop = status, log, stop
        self._procs: dict[int, subprocess.Popen] = {}
        self._lock = threading.Lock()

    # ---- control --------------------------------------------------------
    def terminate_all(self) -> None:
        with self._lock:
            procs = list(self._procs.values())
        for p in procs:
            try:
                os.killpg(os.getpgid(p.pid), signal.SIGTERM)
            except (OSError, ProcessLookupError):
                pass

    # ---- one worker run -------------------------------------------------
    def run(self, task: Task) -> Result:
        res = Result()
        dur = 0.0
        last_step_probe = 0.0
        try:
            proc = subprocess.Popen(task.argv, env=task.env, stdin=subprocess.DEVNULL,
                                    stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                    start_new_session=True, bufsize=0)
        except OSError as e:
            res.rc = 127
            res.problems.append(("ERROR", f"cannot start worker: {e}"))
            return res
        with self._lock:
            self._procs[proc.pid] = proc
        fd = proc.stdout.fileno()
        buf = b""
        try:
            while True:
                ready, _, _ = select.select([fd], [], [], 1.0)
                now = time.time()
                if ready:
                    chunk = os.read(fd, 65536)
                    if not chunk:
                        break
                    buf += chunk
                    parts = re.split(rb"[\r\n]", buf)
                    buf = parts.pop()
                    for raw in parts:
                        if raw:
                            dur = self._line(task, res, raw.decode("utf-8", "replace"), dur)
                if now - last_step_probe >= 1.0:
                    last_step_probe = now
                    step = current_step(proc.pid)
                    if step:
                        task.step = step
                if self.stop.is_set():
                    break
        finally:
            if buf:
                self._line(task, res, buf.decode("utf-8", "replace"), dur)
            if self.stop.is_set() and proc.poll() is None:
                try:
                    os.killpg(os.getpgid(proc.pid), signal.SIGTERM)
                except (OSError, ProcessLookupError):
                    pass
            try:
                proc.wait(timeout=60)
            except subprocess.TimeoutExpired:
                try:
                    os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
                except (OSError, ProcessLookupError):
                    pass
                proc.wait()
            with self._lock:
                self._procs.pop(proc.pid, None)
        res.rc = proc.returncode if proc.returncode is not None else 1
        return res

    # ---- line parser ----------------------------------------------------
    def _line(self, task: Task, res: Result, line: str, dur: float) -> float:
        line = line.rstrip()
        if not line:
            return dur
        if len(res.tail) >= 30:
            res.tail.pop(0)
        res.tail.append(line)
        m = _DUR.search(line)
        if m and "Input #" not in line and dur == 0.0:
            dur = _seconds(m)
        if "Input #" in line:
            dur = 0.0
            task.pct = None
        m = _TIME.search(line)
        if m:
            pos = _seconds(m)
            if dur > 0:
                task.pct = max(0.0, min(100.0, 100.0 * pos / dur))
            ms = _SPEED.search(line)
            task.speed = f"{ms.group(1)}x" if ms else task.speed
            return dur
        t = _TAGGED.match(line)
        if not t:
            return dur
        tag, rest = t.group(1), t.group(2)
        if tag == "START":
            task.step = _short_step(rest)
            task.pct = None
        elif tag == "OK":
            w = _WRITTEN.match(line)
            if w:
                res.outputs.append(w.group(1).strip())
        elif tag in ("WARN", "ERROR"):
            if any(b.search(rest) for b in _BENIGN):
                self.log.info(task.phase, rest[:200], task.src)
            else:
                res.problems.append((tag, rest))
        elif tag == "SKIP":
            res.skipped = True
        return dur
