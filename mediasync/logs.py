"""Local logs: run log (text + JSON lines) and cumulative CSV records."""
from __future__ import annotations

import csv
import json
import threading
import time
from collections import deque
from pathlib import Path


class RunLog:
    """Everything that happens in one run, written to the local disk next to CAMERA/UNSORTED."""

    LEVELS = ("INFO", "WARN", "ERROR")

    def __init__(self, logs_dir: Path):
        self.dir = logs_dir
        self.dir.mkdir(parents=True, exist_ok=True)
        stamp = time.strftime("%Y%m%d-%H%M%S")
        self.text_path = self.dir / f"run-{stamp}.log"
        self.jsonl_path = self.dir / f"run-{stamp}.jsonl"
        self._text = open(self.text_path, "a", buffering=1, encoding="utf-8")
        self._json = open(self.jsonl_path, "a", buffering=1, encoding="utf-8")
        self._lock = threading.Lock()
        self.counts = {"INFO": 0, "WARN": 0, "ERROR": 0}
        self.recent_issues: deque = deque(maxlen=200)
        self.collisions = 0
        self._csv_files: dict = {}

    def event(self, level: str, phase: str, message: str, file="", **extra) -> None:
        now = time.time()
        file = str(file) if file else ""
        with self._lock:
            self.counts[level] = self.counts.get(level, 0) + 1
            line = f"{time.strftime('%H:%M:%S', time.localtime(now))} {level:5s} [{phase}] {message}"
            if file:
                line += f"  | {file}"
            self._text.write(line + "\n")
            rec = {"ts": round(now, 3), "level": level, "phase": phase, "message": message, "file": file}
            rec.update(extra)
            self._json.write(json.dumps(rec, ensure_ascii=False) + "\n")
            if level in ("WARN", "ERROR"):
                self.recent_issues.append((now, level, phase, message, file))
                self._append_csv("issues.csv", ["time", "level", "phase", "file", "message"],
                                 [time.strftime("%F %T", time.localtime(now)), level, phase, file, message])

    def info(self, phase, message, file="", **x):
        self.event("INFO", phase, message, file, **x)

    def warn(self, phase, message, file="", **x):
        self.event("WARN", phase, message, file, **x)

    def error(self, phase, message, file="", **x):
        self.event("ERROR", phase, message, file, **x)

    # ---- cumulative csv records ------------------------------------------
    def _append_csv(self, name: str, header: list[str], row: list) -> None:
        path = self.dir / name
        new = not path.exists()
        with open(path, "a", newline="", encoding="utf-8") as fh:
            w = csv.writer(fh)
            if new:
                w.writerow(header)
            w.writerow(row)

    def record(self, name: str, header: list[str], row: list) -> None:
        with self._lock:
            self._append_csv(name, header, row)

    def collision(self, phase: str, wanted: str, existing: str, kept_as: str,
                  size_a: int, sha_a: str, size_b: int, sha_b: str) -> None:
        """A name was already taken by a different file: nothing is overwritten."""
        with self._lock:
            self.collisions += 1
        self.record("collisions.csv",
                    ["time", "phase", "wanted", "existing", "stored_as", "existing_size", "existing_sha256",
                     "new_size", "new_sha256"],
                    [time.strftime("%F %T"), phase, wanted, existing, kept_as, size_a, sha_a, size_b, sha_b])
        self.warn(phase, f"name collision, nothing overwritten (stored as {kept_as})", wanted)

    def close(self) -> None:
        with self._lock:
            self._text.close()
            self._json.close()
