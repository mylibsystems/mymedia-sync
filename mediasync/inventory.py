"""Inventory + verification: what exists, and is each output really complete?"""
from __future__ import annotations

import os
import re
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, field

from . import fsutil
from .probe import ExifPool, capture_date, ffprobe_duration, flac_audio_ok, tail_decodes

SIDECAR_NAMES = {"cover.jpg", "poster.jpg", "folder.jpg"}
_LABEL_RE = re.compile(r" \[[^\]\[]*\]$")


@dataclass
class Inventory:
    unsorted: dict = field(default_factory=dict)    # type -> list[(rel, size, mtime_ns)]
    camera: list = field(default_factory=list)      # archive files
    desktop: dict = field(default_factory=dict)     # lib -> {rel: (size, mtime_ns)}
    portable: dict = field(default_factory=dict)


def duration_ok(out_dur: float | None, ref_dur: float | None) -> tuple[bool, str]:
    """A converted file must be readable and not shorter than its source."""
    if out_dur is None:
        return False, "unreadable (ffprobe cannot read it)"
    if ref_dur:
        tol = max(1.5, 0.02 * ref_dur)
        if out_dur < ref_dur - tol:
            return False, f"shorter than its source ({out_dur:.1f}s vs {ref_dur:.1f}s)"
    return True, f"{out_dur:.1f}s"


class Verifier:
    """Checks outputs; results are cached by (path, size, mtime) so unchanged files are confirmed
    from the listing alone while new/changed ones are inspected for real."""

    def __init__(self, state, log, *, deep_all: bool = False, threads: int = 8):
        self.state, self.log = state, log
        self.deep_all = deep_all
        self.threads = threads
        self._verified = state.load_verified()
        self._durations = state.load_durations()
        self._new_verified: list = []
        self._new_durations: list = []
        self._lock = threading.Lock()

    # ---- durations ------------------------------------------------------
    def duration(self, path: str, size: int, mtime_ns: int) -> float | None:
        c = self._durations.get(path)
        if c and c[0] == size and c[1] == mtime_ns:
            return c[2]
        d = ffprobe_duration(path)
        if d is not None:
            with self._lock:
                self._durations[path] = (size, mtime_ns, d)
                self._new_durations.append((path, size, mtime_ns, d))
        return d

    # ---- one file -------------------------------------------------------
    def cached(self, path: str, size: int, mtime_ns: int):
        if self.deep_all:
            return None
        c = self._verified.get(path)
        if c and c[0] == size and c[1] == mtime_ns:
            return c[2], c[3]
        return None

    def check(self, path: str, size: int, mtime_ns: int, kind: str, ref=None) -> tuple[bool, str]:
        """kind: photo | video | audio. ref = (path, size, mtime_ns) of the file it was made from."""
        if size <= 0:
            return False, "empty file"
        hit = self.cached(path, size, mtime_ns)
        if hit is not None:
            return hit
        if kind == "photo":
            ok, detail = fsutil.jpeg_check(path)
        elif kind == "audio" and path.lower().endswith(".flac"):
            ok, detail = flac_audio_ok(path)
        else:
            ref_dur = self.duration(*ref) if ref else None
            ok, detail = duration_ok(self.duration(path, size, mtime_ns), ref_dur)
            if ok:
                ok, why = tail_decodes(path, kind)
                if not ok:
                    detail = why
            if not ok and kind == "video" and ref and self._source_damaged(ref[0], path, detail):
                ok, detail = True, "source is damaged; output is as complete as the source allows"
        with self._lock:
            self._verified[path] = (size, mtime_ns, ok, detail)
            self._new_verified.append((path, size, mtime_ns, ok, detail))
        return ok, detail

    def _source_damaged(self, source: str, output: str, reason: str) -> bool:
        """True when the file this output was made from cannot be read to its end either.

        A camera original cut off mid-recording still claims its full length in the header, so an output that
        stops where the readable data stops would otherwise fail verification (and be rebuilt) on every run.
        """
        if not (reason.startswith("shorter than its source") or reason.startswith("decode error near the end")
                or reason.startswith("end of the file cannot be decoded")):
            return False
        ok, why = tail_decodes(source, "video")
        if ok:
            return False
        try:
            self.log.record("source-damaged.csv", ["time", "source", "output", "source_problem", "output_check"],
                            [time.strftime("%F %T"), source, output, why, reason])
        except Exception:
            pass
        return True

    def flush(self) -> None:
        with self._lock:
            nv, nd = self._new_verified, self._new_durations
            self._new_verified, self._new_durations = [], []
        if nv:
            self.state.set_verified(nv)
        if nd:
            self.state.set_durations(nd)

    def forget(self, path: str) -> None:
        with self._lock:
            self._verified.pop(path, None)
        self.state.drop_verified(path)

    # ---- many files in parallel ----------------------------------------
    def check_many(self, items: list, progress=None, stop=None) -> dict:
        """items: [(key, path, size, mtime_ns, kind, ref)] -> {key: (ok, detail)}"""
        results: dict = {}

        def one(it):
            if stop is not None and stop.is_set():
                return it[0], (True, "not checked (stopped)")
            key, path, size, mt, kind, ref = it
            try:
                r = self.check(path, size, mt, kind, ref)
            except Exception as e:      # never let one bad file stop the scan
                r = (False, f"check failed: {e}")
            return key, r

        done = 0
        with ThreadPoolExecutor(self.threads) as ex:
            for key, r in ex.map(one, items):
                results[key] = r
                done += 1
                if progress and (done % 200 == 0 or done == len(items)):
                    progress(done)
        self.flush()
        return results


# ---------------------------------------------------------------------------
def scan_inventory(settings, status, log, stop) -> Inventory:
    """List every input and output tree (one directory walk each)."""
    inv = Inventory()
    jobs = []
    for kind in ("CAMERA", "DOWNLOADS", "MUSIC", "MOVIES", "TV", "PHOTOS", "VIDEO"):
        jobs.append(("unsorted", kind, settings.source_dir(kind)))
    jobs.append(("camera", "CAMERA", settings.camera))
    for lib in ("MUSIC", "MOVIES", "TV", "PHOTOS"):
        jobs.append(("desktop", lib, settings.desktop(lib)))
        jobs.append(("portable", lib, settings.portable(lib)))

    def run(job):
        what, name, root = job
        rows = list(fsutil.scan_tree(root))
        return what, name, rows

    with ThreadPoolExecutor(4) as ex:
        for what, name, rows in ex.map(run, jobs):
            if what == "unsorted":
                inv.unsorted[name] = rows
            elif what == "camera":
                inv.camera = rows
            else:
                getattr(inv, what)[name] = {rel: (sz, mt) for rel, sz, mt in rows}
            log.info("scan", f"{what} {name}: {len(rows)} files")
            if stop.is_set():
                break
    return inv


def is_output_media(rel: str) -> str | None:
    """photo/video kind of an output file in the photo library; None for sidecars/other files."""
    base = os.path.basename(rel)
    if base.lower() in SIDECAR_NAMES or base.endswith(".thumb.jpg") or fsutil.is_hidden(base):
        return None
    e = fsutil.ext_of(base)
    if e in ("jpg", "jpeg"):
        return "photo"
    if e in ("m4v", "mp4", "mov"):
        return "video"
    return None


def portable_rel(lib: str, desktop_rel: str) -> str:
    """Expected portable path for a desktop file (mirrors portablize.sh)."""
    d, name = os.path.split(desktop_rel)
    stem = name.rsplit(".", 1)[0]
    if lib == "MUSIC":
        out = stem + ".m4a"
    elif lib in ("MOVIES", "TV"):
        out = _LABEL_RE.sub("", stem) + " [SD].m4v"
    else:
        out = name                      # photos & camera videos keep their name
    return os.path.join(d, out) if d else out
