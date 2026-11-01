"""Filesystem helpers: fast listing, hashing, verified copy, JPEG integrity, file kinds."""
from __future__ import annotations

import hashlib
import os
import shutil
import subprocess
import threading
from pathlib import Path
from typing import Callable, Iterator

# Same extension routing as orginize.sh.
PHOTO_EXT = {"jpg", "jpeg", "png", "bmp", "webp", "heic", "heif", "avif", "orf", "rw2", "cr2",
             "nef", "arw", "dng", "tiff", "tif", "psd"}
VIDEO_EXT = {"mp4", "mov", "avi", "mkv", "mpeg", "avc", "m4v", "m2v", "wmv", "ts", "m2ts",
             "mts", "flv", "webm", "ogv", "3gp", "3g2", "vob", "asf"}
AUDIO_EXT = {"m4a", "m4b", "flac", "mp3", "aac", "ogg", "opus", "wav", "aiff", "wv", "ape",
             "mka", "wma", "caf", "mp2"}
RAW_EXT = {"orf", "rw2", "cr2", "nef", "arw", "dng"}
NOISE_NAMES = {".ds_store", "thumbs.db", "desktop.ini", ".spotlight-v100", ".trashes",
               ".fseventsd", ".temporaryitems", ".localized"}


def ext_of(name: str) -> str:
    return name.rsplit(".", 1)[-1].lower() if "." in name else ""


def classify(name: str) -> str | None:
    e = ext_of(name)
    if e in PHOTO_EXT:
        return "photo"
    if e in VIDEO_EXT:
        return "video"
    if e in AUDIO_EXT:
        return "audio"
    return None


def is_hidden(name: str) -> bool:
    return name.startswith(".") or name.lower() in NOISE_NAMES or name.startswith("._")


# ---------------------------------------------------------------------------
# listing
# ---------------------------------------------------------------------------
_FIND_OK: bool | None = None
_FIND_LOCK = threading.Lock()


def _find_supports_printf() -> bool:
    global _FIND_OK
    with _FIND_LOCK:
        if _FIND_OK is None:
            try:
                r = subprocess.run(["find", "/dev/null", "-printf", "x"], capture_output=True, timeout=10)
                _FIND_OK = r.returncode == 0 and r.stdout == b"x"
            except (OSError, subprocess.SubprocessError):
                _FIND_OK = False
        return _FIND_OK


def scan_tree(root: os.PathLike | str, *, skip_hidden: bool = True) -> Iterator[tuple[str, int, int]]:
    """Yield (relative_path, size, mtime_ns) for every regular file under root.

    Uses one GNU `find -printf` pass when available: that is a single directory
    walk, which is what makes listing 65,000 files on an SMB share take seconds
    instead of one stat round-trip per file.
    """
    root = os.fspath(root)
    if not os.path.isdir(root):
        return
    if _find_supports_printf():
        proc = subprocess.Popen(["find", root, "-type", "f", "-printf", r"%s\t%T@\t%P\0"],
                                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        buf = b""
        assert proc.stdout is not None
        while True:
            chunk = proc.stdout.read(1 << 20)
            if not chunk:
                break
            buf += chunk
            *items, buf = buf.split(b"\0")
            for it in items:
                row = _parse_find_row(it, skip_hidden)
                if row:
                    yield row
        if buf:
            row = _parse_find_row(buf, skip_hidden)
            if row:
                yield row
        proc.stdout.close()
        proc.wait()
        return
    for dirpath, dirnames, filenames in os.walk(root):
        for fn in filenames:
            full = os.path.join(dirpath, fn)
            rel = os.path.relpath(full, root)
            if skip_hidden and any(is_hidden(p) for p in rel.split(os.sep)):
                continue
            try:
                st = os.stat(full)
            except OSError:
                continue
            yield rel, st.st_size, st.st_mtime_ns


def _parse_find_row(raw: bytes, skip_hidden: bool):
    try:
        size_s, mt_s, rel = raw.decode("utf-8", "surrogateescape").split("\t", 2)
    except ValueError:
        return None
    if skip_hidden and any(is_hidden(p) for p in rel.split("/")):
        return None
    whole, _, frac = mt_s.partition(".")
    mtime_ns = int(whole) * 1_000_000_000 + int((frac + "000000000")[:9] or 0)
    return rel, int(size_s), mtime_ns


# ---------------------------------------------------------------------------
# hashing / copying
# ---------------------------------------------------------------------------
CHUNK = 4 << 20


def sha256_file(path, progress: Callable[[int], None] | None = None) -> str:
    h = hashlib.sha256()
    with open(path, "rb", buffering=0) as f:
        while True:
            b = f.read(CHUNK)
            if not b:
                break
            h.update(b)
            if progress:
                progress(len(b))
    return h.hexdigest()


def copy_verified(src, dst_tmp, progress: Callable[[int], None] | None = None) -> tuple[str, int]:
    """Copy src to dst_tmp streaming; return (sha256 of the bytes read, size). fsyncs the copy."""
    h = hashlib.sha256()
    total = 0
    with open(src, "rb", buffering=0) as fi, open(dst_tmp, "wb", buffering=0) as fo:
        while True:
            b = fi.read(CHUNK)
            if not b:
                break
            fo.write(b)
            h.update(b)
            total += len(b)
            if progress:
                progress(len(b))
        try:
            os.fsync(fo.fileno())
        except OSError:
            pass
    try:
        shutil.copystat(src, dst_tmp)
    except OSError:
        pass
    return h.hexdigest(), total


def same_filesystem(a, b) -> bool:
    try:
        return os.stat(a).st_dev == os.stat(b).st_dev
    except OSError:
        return False


# ---------------------------------------------------------------------------
# JPEG integrity (no decoding, reads only headers + the last bytes)
# ---------------------------------------------------------------------------
def jpeg_check(path, size_hint: int | None = None) -> tuple[bool, str]:
    """Return (ok, detail). Valid = SOI, a frame header with real dimensions, EOI at the end."""
    try:
        with open(path, "rb") as f:
            f.seek(0, 2)
            size = f.tell()
            if size == 0:
                return False, "empty file"
            if size < 4:
                return False, f"too small ({size} bytes)"
            f.seek(0)
            if f.read(2) != b"\xff\xd8":
                return False, "no JPEG start marker"
            width = height = 0
            while True:
                b = f.read(1)
                if not b:
                    return False, "ended before the image data"
                if b != b"\xff":
                    continue
                m = f.read(1)
                while m == b"\xff":
                    m = f.read(1)
                if not m:
                    return False, "ended inside the header"
                mk = m[0]
                if mk in (0x00, 0x01) or 0xD0 <= mk <= 0xD8:
                    continue
                seg = f.read(2)
                if len(seg) < 2:
                    return False, "ended inside the header"
                ln = (seg[0] << 8) | seg[1]
                if mk in (0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7, 0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF):
                    data = f.read(5)
                    if len(data) < 5:
                        return False, "short frame header"
                    height = (data[1] << 8) | data[2]
                    width = (data[3] << 8) | data[4]
                    break
                if mk == 0xDA:      # start of scan before any frame header
                    return False, "no frame header"
                f.seek(ln - 2, 1)
            if width <= 0 or height <= 0:
                return False, "zero dimensions"
            f.seek(max(0, size - 64))
            tail = f.read(64)
            if b"\xff\xd9" not in tail:
                return False, "truncated (no end-of-image marker)"
            return True, f"{width}x{height}"
    except OSError as e:
        return False, f"unreadable: {e.strerror or e}"


def human_bytes(n: float) -> str:
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if abs(n) < 1024 or unit == "TB":
            return f"{n:.0f} {unit}" if unit == "B" else f"{n:.1f} {unit}"
        n /= 1024
    return f"{n:.1f} TB"


def human_duration(sec: float | None) -> str:
    if sec is None or sec != sec or sec < 0:
        return "--:--"
    sec = int(sec)
    d, rem = divmod(sec, 86400)
    h, rem = divmod(rem, 3600)
    m, s = divmod(rem, 60)
    if d:
        return f"{d}d{h:02d}h"
    if h:
        return f"{h}h{m:02d}m"
    return f"{m:02d}:{s:02d}"
