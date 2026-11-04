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


# ffmpeg lines that mention "invalid"/"error" but are muxer/timestamp chatter, not a decode failure.
_BENIGN = ("non monotonically increasing dts", "Application provided invalid", "Queue input is backward in time",
           "Non-monotonous DTS", "timestamps are unset")


def _real_error(text: str) -> str:
    for ln in text.split("\n"):
        ln = ln.strip()
        if ("rror" in ln or "nvalid" in ln) and not any(b in ln for b in _BENIGN):
            return ln
    return ""


def tail_decodes(path: str, kind: str = "video", timeout: int = 180) -> tuple[bool, str]:
    """Decode the last second: a truncated file claims its full duration in the header but fails here.

    Files shorter than about a second (e.g. a pregap track) are decoded completely instead.
    """
    dur = ffprobe_duration(path)
    short = dur is not None and dur < 1.5
    try:
        # Only the real streams: an embedded cover picture would make the progress time read N/A.
        maps = ["-map", "0:a:0"] if kind == "audio" else ["-map", "0:v:0", "-map", "0:a:0?"]
        seek = [] if short else ["-sseof", "-1"]
        r = subprocess.run(["ffmpeg", "-hide_banner", "-nostdin", "-v", "error", "-stats", *seek,
                            "-i", path, *maps, "-f", "null", "-"], capture_output=True, text=True, timeout=timeout)
    except (OSError, subprocess.SubprocessError) as e:
        return False, f"cannot run ffmpeg: {e}"
    text = (r.stderr + r.stdout).replace("\r", "\n")
    times = _TIME_RE.findall(text)
    first_err = _real_error(text)
    if not times:
        return False, "end of the file cannot be decoded" + (f" ({first_err[:60]})" if first_err else "")
    t = int(times[-1][0]) * 3600 + int(times[-1][1]) * 60 + float(times[-1][2])
    if t < (dur * 0.5 if short else 0.2):
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


def _flac_streaminfo(path: str):
    """(total_samples, channels, bits_per_sample) from the STREAMINFO block, or None."""
    try:
        with open(path, "rb") as f:
            head = f.read(42)
    except OSError:
        return None
    if len(head) < 42 or head[:4] != b"fLaC" or head[4] & 0x7F != 0:
        return None
    d = head[8:42]
    total = int.from_bytes(d[10:18], "big") & ((1 << 36) - 1)
    channels = ((d[12] >> 1) & 7) + 1
    bps = (((d[12] & 1) << 4) | (d[13] >> 4)) + 1
    return total, channels, bps


def _crc8(data: bytes) -> int:
    c = 0
    for x in data:
        c ^= x
        for _ in range(8):
            c = ((c << 1) ^ 0x07) & 0xFF if c & 0x80 else (c << 1) & 0xFF
    return c


def _valid_frame_header(d: bytes, i: int) -> bool:
    try:
        b2, b3 = d[i + 2], d[i + 3]
        if (b2 >> 4) == 0 or (b2 & 15) == 15 or (b3 & 1) or ((b3 >> 1) & 7) == 3 or (b3 >> 4) > 10:
            return False
        first = d[i + 4]
        ln = (1 if first < 0x80 else 2 if first >> 5 == 6 else 3 if first >> 4 == 14 else 4 if first >> 3 == 30
              else 5 if first >> 2 == 62 else 6 if first >> 1 == 126 else 7)
        hl = 4 + ln + (1 if b2 >> 4 == 6 else 2 if b2 >> 4 == 7 else 0)
        sr = b2 & 15
        hl += 1 if sr == 12 else 2 if sr in (13, 14) else 0
        return _crc8(d[i:i + hl]) == d[i + hl]
    except IndexError:
        return False


def _without_leading_junk(path: str, max_junk: int = 400_000) -> bytes | None:
    """File bytes with anything between the metadata and the first valid audio frame removed."""
    with open(path, "rb") as f:
        d = f.read()
    pos = 4
    while pos + 4 <= len(d):
        h = d[pos]
        pos += 4 + int.from_bytes(d[pos + 1:pos + 4], "big")
        if h & 0x80:
            break
    else:
        return None
    for i in range(pos, min(len(d) - 10, pos + max_junk)):
        if d[i] == 0xFF and d[i + 1] in (0xF8, 0xF9) and _valid_frame_header(d, i):
            return d[:pos] + d[i:]
    return None


def flac_audio_ok(path: str, timeout: int = 900) -> tuple[bool, str]:
    """FLAC integrity that does not trip over junk bytes around a complete stream.

    `flac -t` fails on a stale padding block before the first frame or a trailing tag even though every
    sample decodes.  So: pass `flac -t`, else drop the leading junk and decode tolerantly, looking at where
    the decoder complained.  Errors before the first sample or after the last one are junk; an error inside
    the audio, or fewer samples than the header promises, is damage.
    """
    import tempfile
    try:
        if subprocess.run(["flac", "-t", "-s", path], capture_output=True, timeout=timeout).returncode == 0:
            return True, "ok"
        info = _flac_streaminfo(path)
        if not info or info[2] % 8:
            return False, "flac test failed"
        total, channels, bps = info
        frame_bytes = channels * (bps // 8)
        clean = _without_leading_junk(path)
        with tempfile.NamedTemporaryFile(suffix=".flac") as tmp, tempfile.TemporaryFile() as err:
            if clean is None:
                src = path
            else:
                tmp.write(clean)
                tmp.flush()
                src = tmp.name
            proc = subprocess.Popen(["flac", "-d", "-F", "-s", "--force-raw-format", "--endian=little",
                                     "--sign=signed", "-o", "-", src], stdout=subprocess.PIPE, stderr=err)
            n = 0
            while True:
                chunk = proc.stdout.read(1 << 20)
                if not chunk:
                    break
                n += len(chunk)
            proc.stdout.close()
            proc.wait(timeout=timeout)
            err.seek(0)
            text = err.read().decode("utf-8", "replace")
    except (OSError, subprocess.SubprocessError) as e:
        return False, f"cannot run flac: {e}"
    got = n // frame_bytes
    if total and got < total:
        return False, f"only {got} of {total} samples decode"
    positions = [int(m) for m in re.findall(r"after processing (\d+) samples", text)]
    inside = [x for x in positions if 0 < x < got]
    if inside:
        return False, f"decode error inside the audio (at sample {inside[0]})"
    return True, "ok (junk bytes around a complete stream)"
