"""Small SQLite state: verification cache, capture dates, ingest ledger, run history."""
from __future__ import annotations

import sqlite3
import threading
import time
from pathlib import Path

SCHEMA = """
CREATE TABLE IF NOT EXISTS verified(path TEXT PRIMARY KEY, size INTEGER, mtime_ns INTEGER,
                                    ok INTEGER, detail TEXT, ts REAL);
CREATE TABLE IF NOT EXISTS dates(path TEXT PRIMARY KEY, size INTEGER, mtime_ns INTEGER,
                                 y TEXT, m TEXT, d TEXT, src TEXT);
CREATE TABLE IF NOT EXISTS ingested(rel TEXT PRIMARY KEY, size INTEGER, mtime_ns INTEGER,
                                    sha256 TEXT, ts REAL);
CREATE TABLE IF NOT EXISTS history(ts REAL, phase TEXT, units INTEGER, seconds REAL);
CREATE TABLE IF NOT EXISTS built(arch_rel TEXT PRIMARY KEY, out_rel TEXT);
CREATE TABLE IF NOT EXISTS durations(path TEXT PRIMARY KEY, size INTEGER, mtime_ns INTEGER, dur REAL);
"""


class State:
    def __init__(self, path: Path):
        path.parent.mkdir(parents=True, exist_ok=True)
        self._db = sqlite3.connect(str(path), check_same_thread=False, timeout=60)
        self._db.execute("PRAGMA journal_mode=WAL")
        self._db.execute("PRAGMA synchronous=NORMAL")
        self._db.executescript(SCHEMA)
        self._lock = threading.Lock()

    # ---- helpers --------------------------------------------------------
    def _exec(self, sql, args=()):
        with self._lock:
            cur = self._db.execute(sql, args)
            self._db.commit()
            return cur

    def _many(self, sql, rows):
        with self._lock:
            self._db.executemany(sql, rows)
            self._db.commit()

    def _one(self, sql, args=()):
        with self._lock:
            return self._db.execute(sql, args).fetchone()

    def _all(self, sql, args=()):
        with self._lock:
            return self._db.execute(sql, args).fetchall()

    # ---- verification cache ---------------------------------------------
    def get_verified(self, path: str, size: int, mtime_ns: int):
        """(ok, detail) when this exact size+mtime was checked before, else None."""
        r = self._one("SELECT ok, detail, size, mtime_ns FROM verified WHERE path=?", (path,))
        if r and r[2] == size and r[3] == mtime_ns:
            return bool(r[0]), r[1]
        return None

    def load_verified(self) -> dict:
        return {p: (s, m, bool(ok), d) for p, s, m, ok, d in
                self._all("SELECT path,size,mtime_ns,ok,detail FROM verified")}

    def set_verified(self, rows) -> None:
        now = time.time()
        self._many("INSERT OR REPLACE INTO verified VALUES(?,?,?,?,?,?)",
                   [(p, s, m, int(ok), d, now) for p, s, m, ok, d in rows])

    def drop_verified(self, path: str) -> None:
        self._exec("DELETE FROM verified WHERE path=?", (path,))

    # ---- capture dates --------------------------------------------------
    def load_dates(self) -> dict:
        return {p: (s, m, y, mo, d, src) for p, s, m, y, mo, d, src in
                self._all("SELECT path,size,mtime_ns,y,m,d,src FROM dates")}

    def set_dates(self, rows) -> None:
        self._many("INSERT OR REPLACE INTO dates VALUES(?,?,?,?,?,?,?)", rows)

    # ---- media durations -------------------------------------------------
    def load_durations(self) -> dict:
        return {p: (s, m, d) for p, s, m, d in self._all("SELECT path,size,mtime_ns,dur FROM durations")}

    def set_durations(self, rows) -> None:
        self._many("INSERT OR REPLACE INTO durations VALUES(?,?,?,?)", rows)

    # ---- ingest ledger --------------------------------------------------
    def load_ingested(self) -> dict:
        return {r: (s, m, h) for r, s, m, h in self._all("SELECT rel,size,mtime_ns,sha256 FROM ingested")}

    def set_ingested(self, rel: str, size: int, mtime_ns: int, sha256: str) -> None:
        self._exec("INSERT OR REPLACE INTO ingested VALUES(?,?,?,?,?)", (rel, size, mtime_ns, sha256, time.time()))

    # ---- camera build map (archive path -> desktop output) ---------------
    def load_built(self) -> dict:
        return dict(self._all("SELECT arch_rel,out_rel FROM built"))

    def set_built(self, rows) -> None:
        self._many("INSERT OR REPLACE INTO built VALUES(?,?)", rows)

    # ---- history for ETA ------------------------------------------------
    def add_history(self, phase: str, units: int, seconds: float) -> None:
        if units > 0 and seconds > 1:
            self._exec("INSERT INTO history VALUES(?,?,?,?)", (time.time(), phase, units, seconds))

    def last_rate(self, phase: str) -> float | None:
        """Units per second of the most recent finished runs of this phase."""
        rows = self._all("SELECT units, seconds FROM history WHERE phase=? ORDER BY ts DESC LIMIT 5", (phase,))
        u = sum(r[0] for r in rows)
        s = sum(r[1] for r in rows)
        return (u / s) if s > 0 and u > 0 else None

    def close(self):
        with self._lock:
            self._db.close()
