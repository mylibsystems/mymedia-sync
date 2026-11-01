"""exiftool / ffprobe helpers.

capture_date() follows read_photo_date() in metadata.sh step by step (same tags, same
order, same filename fallbacks) but talks to ONE long-running exiftool process, so
dating 65,000 files does not cost 65,000 process starts.
"""
from __future__ import annotations

import os
import queue
import re
import subprocess
import threading

_DATE_RE = re.compile(r"^[12][0-9]{3}:[01][0-9]:[0-3][0-9]$")
_FN_SEP = re.compile(r"([12][0-9]{3})[._-]([01][0-9])[._-]([0-3][0-9])")
_FN_COMPACT = re.compile(r"([12][0-9]{3})([01][0-9])([0-3][0-9])")

_EMBEDDED_ARGS = ["-d", "%Y:%m:%d", "-DateTimeOriginal", "-EXIF:DateTimeDigitized",
                  "-QuickTime:CreateDate", "-QuickTime:MediaCreateDate",
                  "-QuickTime:TrackCreateDate", "-XMP:DateCreated", "-XMP:CreateDate",
                  "-IPTC:DateCreated", "-GPS:GPSDateStamp", "-s3"]
_FS_ARGS = ["-d", "%Y:%m:%d", "-FileCreateDate", "-FileModifyDate", "-s3"]


class ExifToolServer:
    """A persistent `exiftool -stay_open` process (one request at a time)."""

    def __init__(self):
        self._proc = subprocess.Popen(
            ["exiftool", "-stay_open", "True", "-@", "-"],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        self._lock = threading.Lock()

    def run(self, args: list[str]) -> str:
        with self._lock:
            assert self._proc.stdin is not None and self._proc.stdout is not None
            payload = "\n".join(args + ["-execute"]) + "\n"
            self._proc.stdin.write(payload.encode("utf-8", "surrogateescape"))
            self._proc.stdin.flush()
            out = []
            while True:
                line = self._proc.stdout.readline()
                if not line:
                    break
                s = line.decode("utf-8", "replace")
                if s.strip() == "{ready}":
                    break
                out.append(s)
            return "".join(out)

    def close(self):
        try:
            if self._proc.stdin:
                self._proc.stdin.write(b"-stay_open\nFalse\n")
                self._proc.stdin.flush()
                self._proc.stdin.close()
            self._proc.wait(timeout=10)
        except Exception:
            self._proc.kill()


class ExifPool:
    """A few servers shared by threads."""

    def __init__(self, n: int = 3):
        self._q: queue.Queue[ExifToolServer] = queue.Queue()
        self._all = []
        for _ in range(max(1, n)):
            s = ExifToolServer()
            self._all.append(s)
            self._q.put(s)

    def run(self, args: list[str]) -> str:
        s = self._q.get()
        try:
            return s.run(args)
        finally:
            self._q.put(s)

    def close(self):
        for s in self._all:
            s.close()


def _first_valid_date(text: str) -> str | None:
    for ln in text.splitlines():
        ln = ln.strip()
        if not ln:
            continue
        d = ln.split(" ", 1)[0]
        if _DATE_RE.match(d):
            return d
    return None


def capture_date(path, pool: ExifPool) -> tuple[str, str, str, str] | None:
    """(YYYY, MM, DD, source) or None — same result as read_photo_date in metadata.sh."""
    path = os.fspath(path)
    dt = _first_valid_date(pool.run(_EMBEDDED_ARGS + [path]))
    src = "embedded metadata"
    if dt is None:
        dt = _first_valid_date(pool.run(_FS_ARGS + [path]))
        src = "filesystem date"
    if dt is None:
        bn = os.path.basename(path)
        m = _FN_SEP.search(bn)
        if m:
            dt, src = f"{m.group(1)}:{m.group(2)}:{m.group(3)}", "filename (separated)"
        else:
            m = _FN_COMPACT.search(bn)
            if m:
                dt, src = f"{m.group(1)}:{m.group(2)}:{m.group(3)}", "filename (compact)"
    if dt is None:
        return None
    return dt[0:4], dt[5:7], dt[8:10], src


_TIME_RE = re.compile(r"time=(\d+):(\d+):(\d+(?:\.\d+)?)")


def tail_decodes(path: str, kind: str = "video", timeout: int = 180) -> tuple[bool, str]:
    """Decode the last second: a truncated file claims its full duration in the header but fails here."""
    try:
        # Only the real streams: an embedded cover picture would make the progress time read N/A.
        maps = ["-map", "0:a:0"] if kind == "audio" else ["-map", "0:v:0", "-map", "0:a:0?"]
        r = subprocess.run(["ffmpeg", "-hide_banner", "-nostdin", "-v", "error", "-stats", "-sseof", "-1",
                            "-i", path, *maps, "-f", "null", "-"], capture_output=True, text=True, timeout=timeout)
    except (OSError, subprocess.SubprocessError) as e:
        return False, f"cannot run ffmpeg: {e}"
    text = (r.stderr + r.stdout).replace("\r", "\n")
    times = _TIME_RE.findall(text)
    first_err = next((ln.strip() for ln in text.split("\n") if "rror" in ln or "nvalid" in ln), "")
    if not times:
        return False, "end of the file cannot be decoded" + (f" ({first_err[:60]})" if first_err else "")
    t = int(times[-1][0]) * 3600 + int(times[-1][1]) * 60 + float(times[-1][2])
    if t < 0.2:
        return False, "end of the file cannot be decoded (nothing readable in the last second)"
    if first_err:
        return False, f"decode error near the end ({first_err[:60]})"
    return True, "ok"


def ffprobe_duration(path: str, timeout: int = 120) -> float | None:
    try:
        r = subprocess.run(
            ["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "default=nw=1:nk=1", path],
            capture_output=True, text=True, timeout=timeout)
    except (OSError, subprocess.SubprocessError):
        return None
    if r.returncode != 0 or r.stderr.strip():
        return None
    try:
        v = float(r.stdout.strip().splitlines()[0])
    except (ValueError, IndexError):
        return None
    return v if v > 0 else None
