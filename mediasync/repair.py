"""Repair damaged desktop FLACs from trusted source folders (for example the SD card the music came from).

A desktop FLAC that fails the integrity check is matched to a good copy in one of the configured source
folders (same audio MD5, else same artist / album / track / title).  The good copy must pass the strict
decoder test.  The repaired file keeps the library file's own tags and cover art; only the audio (and the
stream info / seek table that describe it) comes from the source.  The damaged original is saved first to
<local disk>/repair-backup, the new file is written next to it and verified, and the portable copy that was
derived from the damaged file is removed so the portable step rebuilds it from the healthy one.
"""
from __future__ import annotations

import hashlib
import json
import os
import re
import shutil
import subprocess
import time
import unicodedata
from pathlib import Path

from .probe import _valid_frame_header
from .inventory import portable_rel


def _norm(s: str) -> str:
    return re.sub(r"[\W_]+", " ", unicodedata.normalize("NFKD", s).casefold()).strip()


def _metadata(d: bytes):
    """(valid metadata blocks as (type, data), offset where the walk stopped)."""
    pos, out = 4, []
    if d[:4] != b"fLaC":
        return [], 4
    while pos + 4 <= len(d):
        h = d[pos]
        t = h & 0x7F
        n = int.from_bytes(d[pos + 1:pos + 4], "big")
        ok = ((t == 0 and n == 34 and not out)
              or (t in (1, 3, 4, 5, 6) and out and pos + 4 + n <= len(d) and (t != 3 or n % 18 == 0)))
        if not ok:
            break
        out.append((t, d[pos + 4:pos + 4 + n]))
        pos += 4 + n
        if h & 0x80:
            break
    return out, pos


def _first_frame(d: bytes, pos: int) -> int | None:
    for i in range(pos, min(len(d) - 10, pos + 3_000_000)):
        if d[i] == 0xFF and d[i + 1] in (0xF8, 0xF9) and _valid_frame_header(d, i):
            return i
    return None


def _title(vc: bytes) -> str:
    try:
        pos = 4 + int.from_bytes(vc[:4], "little")
        n = int.from_bytes(vc[pos:pos + 4], "little")
        pos += 4
        for _ in range(n):
            ln = int.from_bytes(vc[pos:pos + 4], "little")
            kv = vc[pos + 4:pos + 4 + ln].decode("utf-8", "replace")
            pos += 4 + ln
            if kv.upper().startswith("TITLE="):
                return kv[6:]
    except Exception:
        pass
    return ""


def rebuild(lib_bytes: bytes, src_bytes: bytes) -> tuple[bytes, str] | None:
    """Library tags + cover art around the source's audio.  Returns (file bytes, note)."""
    sb, spos = _metadata(src_bytes)
    lb, _ = _metadata(lib_bytes)
    first = _first_frame(src_bytes, spos)
    if not sb or first is None:
        return None
    meta = [sb[0]] + [b for b in sb if b[0] == 3]
    note = "tags and cover kept"
    lib_vc = [b for b in lb if b[0] == 4]
    if lib_vc:
        meta.append(lib_vc[0])
    else:
        meta += [b for b in sb if b[0] == 4][:1]
        note = "library tags unreadable: tags taken from the source"
    pics = [b for b in lb if b[0] == 6]
    if not pics:
        pics = [b for b in sb if b[0] == 6]
        if lb:
            note += "; cover taken from the source"
    meta += pics
    meta.append((1, b"\0" * 1024))
    out = bytearray(b"fLaC")
    for i, (t, data) in enumerate(meta):
        out += bytes([t | (0x80 if i == len(meta) - 1 else 0)]) + len(data).to_bytes(3, "big") + data
    return bytes(out) + src_bytes[first:], note


def _strict_ok(path: str) -> bool:
    return subprocess.run(["flac", "-t", "-s", path], capture_output=True).returncode == 0


def _sha(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for b in iter(lambda: f.read(1 << 20), b""):
            h.update(b)
    return h.hexdigest()


class Repairer:
    def __init__(self, settings, log, guard, verifier, stop=None):
        self.s, self.log, self.guard, self.verifier, self.stop = settings, log, guard, verifier, stop
        self.sources = [Path(p) for p in getattr(settings, "repair_music_sources", ()) if Path(p).is_dir()]
        self._by_md5: dict[str, list[str]] = {}
        self._good: dict[str, bool] = {}
        self._dirs: dict[str, list[tuple[str, str]]] = {}

    # ---- source index (cached: header reads over a slow card are costly) ----------------------
    def _index(self) -> None:
        cache_file = Path(self.s.logs) / "repair-source-index.json"
        known = {}
        if cache_file.exists():
            try:
                known = json.load(open(cache_file))
            except (OSError, ValueError):
                known = {}
        fresh = {}
        for root in self.sources:
            for dirpath, _dirs, files in os.walk(root):
                for name in files:
                    if not name.lower().endswith(".flac") or name.startswith("._"):
                        continue
                    p = os.path.join(dirpath, name)
                    try:
                        st = os.stat(p)
                    except OSError:
                        continue
                    c = known.get(p)
                    if c and c[0] == st.st_size and c[1] == st.st_mtime_ns:
                        fresh[p] = c
                        continue
                    try:
                        with open(p, "rb") as f:
                            head = f.read(42)
                        md5 = head[26:42].hex() if head[:4] == b"fLaC" and len(head) >= 42 else ""
                    except OSError:
                        md5 = ""
                    fresh[p] = [st.st_size, st.st_mtime_ns, md5]
        try:
            json.dump(fresh, open(cache_file, "w"))
        except OSError:
            pass
        for p, (_sz, _mt, md5) in fresh.items():
            if md5 and md5 != "0" * 32:
                self._by_md5.setdefault(md5, []).append(p)

    def _source_good(self, path: str) -> bool:
        if path not in self._good:
            self._good[path] = _strict_ok(path)
        return self._good[path]

    def _find_by_layout(self, rel: str, lib_bytes: bytes) -> str | None:
        artist, album, fn = rel.split("/")
        m = re.match(r"0?(\d+)\.(\d+) - (.*)\.flac$", fn)
        if not m:
            return None
        disc, tr, title = int(m[1]), int(m[2]), m[3]
        for root in self.sources:
            try:
                artists = [a for a in os.listdir(root) if (root / a).is_dir()]
            except OSError:
                continue
            for ca in artists:
                if _norm(ca) != _norm(artist) and _norm(artist) != "various artists":
                    continue
                for cal in os.listdir(root / ca):
                    if not (root / ca / cal).is_dir() or cal[:4] != album[:4]:
                        continue
                    a, b = set(_norm(album[5:]).split()), set(_norm(cal[5:]).split())
                    if len(a & b) / max(1, len(a | b)) < 0.6:
                        continue
                    for cf in os.listdir(root / ca / cal):
                        mm = re.match(r"0?(\d+)\.(\d+) - (.*)\.flac$", cf)
                        if mm and int(mm[1]) == disc and int(mm[2]) == tr and _norm(mm[3]) == _norm(title):
                            return str(root / ca / cal / cf)
        return None

    def candidate(self, rel: str, lib_bytes: bytes) -> tuple[str | None, str]:
        lb, _ = _metadata(lib_bytes)
        md5 = lb[0][1][18:34].hex() if lb and lb[0][0] == 0 else ""
        if md5 and self._by_md5.get(md5):
            return self._by_md5[md5][0], "same audio checksum"
        found = self._find_by_layout(rel, lib_bytes)
        return (found, "same album, track number and title") if found else (None, "no source copy")

    # ---- repair one file -----------------------------------------------------------------------
    def repair_file(self, rel: str) -> tuple[str, str]:
        desk = Path(self.s.desktop("MUSIC"))
        dest = str(desk / rel)
        with open(dest, "rb") as f:
            lib_bytes = f.read()
        src, how = self.candidate(rel, lib_bytes)
        if not src:
            return "no source copy", ""
        if not self._source_good(src):
            return "source copy is damaged too", src
        with open(src, "rb") as f:
            built = rebuild(lib_bytes, f.read())
        if built is None:
            return "could not rebuild", src
        new, note = built
        backup = Path(self.s.local_root or self.s.logs) / "repair-backup" / rel
        backup.parent.mkdir(parents=True, exist_ok=True)
        if not backup.exists():
            shutil.copy2(dest, backup)
        if _sha(str(backup)) != _sha(dest):
            return "backup of the original failed", src
        self.guard.check_write(dest)
        tmp = dest + ".repair-tmp"
        with open(tmp, "wb") as f:
            f.write(new)
            f.flush()
            os.fsync(f.fileno())
        want = hashlib.sha256(new).hexdigest()
        if _sha(tmp) != want or not _strict_ok(tmp):
            os.remove(tmp)
            return "rebuilt file failed verification", src
        os.replace(tmp, dest)
        if not _strict_ok(dest):
            return "final check failed", src
        self.verifier.forget(dest)
        port = Path(self.s.portable("MUSIC")) / portable_rel("MUSIC", rel)
        if port.exists():
            try:
                self.guard.remove_file(str(port))
            except Exception:
                pass
        return f"repaired ({how}; {note})", src

    # ---- whole library -------------------------------------------------------------------------
    def run(self, progress=None, on_total=None, on_status=None) -> dict:
        counts: dict[str, int] = {}
        if not self.sources:
            self.log.info("repair", "no repair source folder is available; damaged music is only reported")
            return counts
        desk = Path(self.s.desktop("MUSIC"))
        rels = []
        items = []
        for dirpath, _d, files in os.walk(desk):
            for name in files:
                if name.lower().endswith(".flac") and not name.startswith("._"):
                    p = os.path.join(dirpath, name)
                    st = os.stat(p)
                    rels.append(os.path.relpath(p, desk))
                    items.append((rels[-1], p, st.st_size, st.st_mtime_ns, "audio", None))
        self.log.info("repair", f"verifying {len(items):,} desktop FLAC files")
        if on_total:
            on_total(len(items))
        res = self.verifier.check_many(items, progress=progress, stop=self.stop)
        self.verifier.flush()
        bad = [r for r in rels if r in res and not res[r][0]]
        self.log.info("repair", f"{len(bad)} damaged desktop FLAC files")
        if not bad:
            return counts
        self._index()
        for n, rel in enumerate(bad, 1):
            if self.stop is not None and self.stop.is_set():
                break
            if on_status:
                on_status(f"Repairing damaged music {n}/{len(bad)}: {os.path.basename(rel)}")
            try:
                status, src = self.repair_file(rel)
            except Exception as e:                  # one bad file must not stop the rest
                status, src = f"failed: {e}", ""
            key = status.split(" (")[0]
            counts[key] = counts.get(key, 0) + 1
            self.log.record("repair-music.csv", ["time", "file", "result", "source"],
                            [time.strftime("%F %T"), str(desk / rel), status, src])
            if status.startswith("repaired"):
                self.log.info("repair", status, str(desk / rel))
            else:
                self.log.warn("repair", f"left as is: {status} ({res[rel][1]})", str(desk / rel))
        return counts
