"""Phases done in Python itself (no shell worker): Ingest and Backup."""
from __future__ import annotations

import os

from . import fsutil
from .guard import ProtectedPathError

MANIFEST_HEADER = ["time", "source", "dest", "size", "mtime", "sha256", "verified"]


# ---------------------------------------------------------------------------
# INGEST — copy from the router to the local disk. The router is only ever READ.
# ---------------------------------------------------------------------------
def plan_ingest(ctx, stop) -> tuple[list, list[str]]:
    """Return (tasks-to-copy, notes). Uses a ledger so files that were already ingested (and
    since processed away) are not copied again."""
    s = ctx.settings
    notes: list[str] = []
    if not s.ingest_enabled or s.local_root is None:
        return [], ["ingest disabled"]
    src_root = s.ingest_from
    if not (src_root / "UNSORTED").is_dir() and not (src_root / "CAMERA").is_dir():
        return [], [f"ingest source not available: {src_root}"]
    if os.path.realpath(src_root) == os.path.realpath(s.local_root):
        return [], ["ingest source is the local disk itself"]
    ledger = ctx.state.load_ingested()
    jobs = [(src_root / "UNSORTED" / kind, s.unsorted / kind, f"UNSORTED/{kind}") for kind in
            ("DOWNLOADS", "MUSIC", "MOVIES", "TV", "PHOTOS", "VIDEO", "CAMERA")]
    jobs.append((src_root / "CAMERA", s.camera, "CAMERA"))
    tasks = []
    from .model import Task
    for src_dir, dst_dir, label in jobs:
        if stop.is_set():
            break
        for rel, size, mt in fsutil.scan_tree(src_dir):
            key = f"{label}/{rel}"
            led = ledger.get(key)
            if led and led[0] == size:
                continue
            dest = dst_dir / rel
            if os.path.lexists(dest):
                try:
                    dsize = os.stat(dest).st_size
                except OSError:
                    dsize = -1
                if dsize == size:
                    ctx.state.set_ingested(key, size, mt, "")       # already present: remember, no copy
                    continue
                tasks.append(_task(ctx, label, src_dir / rel, dest, size, mt, key, collision=True))
                continue
            tasks.append(_task(ctx, label, src_dir / rel, dest, size, mt, key))
    return tasks, notes


def _task(ctx, label, src, dest, size, mt, key, collision=False):
    from .model import Task
    return Task(ctx.next_id(), "ingest", "file", os.path.basename(str(src)), str(src), size,
                meta={"dest": str(dest), "key": key, "mtime_ns": mt, "label": label, "collision": collision})


def ingest_task(ctx, task) -> bool:
    log, guard, s = ctx.log, ctx.guard, ctx.settings
    src, dest = task.src, task.meta["dest"]
    is_camera = task.meta["label"] == "CAMERA"
    if task.meta.get("collision"):
        # A different file already has this name locally: keep it, copy nothing, record both checksums.
        try:
            a = fsutil.sha256_file(dest)
            b = fsutil.sha256_file(src)
        except OSError as e:
            log.error("ingest", f"cannot compare colliding files: {e}", src)
            return False
        if a == b:
            ctx.state.set_ingested(task.meta["key"], task.size, task.meta["mtime_ns"], b)
            return True
        log.collision("ingest", src, dest, "(not copied)", os.path.getsize(dest), a, task.size, b)
        task.note = "name collision: not copied"
        return False
    ddir = os.path.dirname(dest)
    tmp = os.path.join(ddir, f".{os.path.basename(dest)}.partial-{os.getpid()}-{task.id}")
    try:
        os.makedirs(ddir, exist_ok=True)
        (guard.check_camera_add if is_camera else guard.check_write)(dest)
        task.step = "copying"

        def prog(n):
            task.bytes_done += n
            task.pct = 100.0 * task.bytes_done / max(task.size, 1)
            with ctx.status.lock:
                ctx.status.bytes_done += n

        sha, total = fsutil.copy_verified(src, tmp, prog)
        verified = False
        if s.ingest_verify:
            task.step = "verifying"
            task.pct = None
            if fsutil.sha256_file(tmp) != sha:
                log.error("ingest", "copy does not match the source (checksum) — discarded", src)
                _drop_tmp(ctx, tmp, is_camera)
                return False
            verified = True
        if os.path.lexists(dest):
            log.warn("ingest", "destination appeared during the copy; not overwritten", dest)
            _drop_tmp(ctx, tmp, is_camera)
            return False
        if is_camera:
            guard.publish_camera_file(tmp, dest)
        else:
            os.rename(tmp, dest)
        ctx.state.set_ingested(task.meta["key"], total, task.meta["mtime_ns"], sha)
        ctx.log.record("manifest.csv", MANIFEST_HEADER,
                       [_now(), src, dest, total, task.meta["mtime_ns"], sha, int(verified)])
        return True
    except ProtectedPathError as e:
        log.error("ingest", str(e), src)
        return False
    except OSError as e:
        log.error("ingest", f"copy failed: {e}", src)
        _drop_tmp(ctx, tmp, is_camera)
        return False


def _drop_tmp(ctx, tmp, is_camera):
    try:
        if is_camera:
            ctx.guard.remove_temp_in_camera(tmp)
        elif os.path.lexists(tmp):
            ctx.guard.remove_file(tmp)
    except (OSError, ProtectedPathError):
        pass


def _now():
    import time
    return time.strftime("%F %T")


# ---------------------------------------------------------------------------
# BACKUP — UNSORTED/CAMERA -> CAMERA (the protected archive). Never overwrites.
# ---------------------------------------------------------------------------
def plan_backup(ctx, inv) -> list:
    from .model import Task
    tasks = []
    root = ctx.settings.source_dir("CAMERA")
    for rel, size, mt in inv.unsorted.get("CAMERA", []):
        if fsutil.classify(os.path.basename(rel)) not in ("photo", "video"):
            continue
        tasks.append(Task(ctx.next_id(), "backup", "file", os.path.basename(rel), str(root / rel), size,
                          meta={"rel": rel, "mtime_ns": mt}))
    return tasks


def backup_task(ctx, task) -> bool:
    from .probe import capture_date
    log, guard, s = ctx.log, ctx.guard, ctx.settings
    src = task.src
    task.step = "dating"
    d = capture_date(src, ctx.exif())
    if d is None:
        log.warn("backup", "cannot determine the capture date; left in the inbox", src)
        task.note = "no capture date"
        return False
    y, m, dd, how = d
    ddir = s.camera / y / m / dd
    name = os.path.basename(src)
    base, ext = os.path.splitext(name)
    task.step = "archiving"
    with ctx.camera_lock:                       # names are allocated one at a time
        try:
            dest, status = _allocate(ctx, src, ddir, base, ext, task.size)
        except OSError as e:
            log.error("backup", f"cannot inspect the archive: {e}", src)
            return False
        if status == "identical":
            try:
                guard.remove_file(src)
            except (OSError, ProtectedPathError) as e:
                log.error("backup", f"already archived, but cannot remove the inbox copy: {e}", src)
                return False
            task.note = "already archived (identical)"
            return True
        os.makedirs(ddir, exist_ok=True)
        try:
            if fsutil.same_filesystem(src, ddir):
                guard.move_into_camera(src, dest)
            else:
                tmp = os.path.join(ddir, f".{os.path.basename(dest)}.partial-{os.getpid()}-{task.id}")
                guard.new_file_in_camera(dest)

                def prog(n):
                    task.bytes_done += n
                    task.pct = 100.0 * task.bytes_done / max(task.size, 1)

                sha, total = fsutil.copy_verified(src, tmp, prog)
                if fsutil.sha256_file(tmp) != sha or total != task.size:
                    guard.remove_temp_in_camera(tmp)
                    log.error("backup", "archive copy does not match the original — discarded", src)
                    return False
                guard.publish_camera_file(tmp, dest)
                guard.remove_file(src)
        except (OSError, ProtectedPathError) as e:
            log.error("backup", f"archiving failed: {e}", src)
            return False
    rel = os.path.relpath(dest, s.camera)
    try:
        st = os.stat(dest)
        ctx.state.set_dates([(rel, st.st_size, st.st_mtime_ns, y, m, dd, how)])
    except OSError:
        pass
    task.meta["dest"] = str(dest)
    return True


def _allocate(ctx, src, ddir, base, ext, size):
    """First free name (name, name_1, ...). If a file with the same bytes is already there the
    original is considered archived; a different file with the same name is a collision:
    nothing is overwritten, the original is stored under the next free name and both
    checksums are logged."""
    i = 0
    collided_with = None
    while True:
        cand = os.path.join(ddir, f"{base}{ext}" if i == 0 else f"{base}_{i}{ext}")
        if not os.path.lexists(cand):
            if collided_with:
                a = fsutil.sha256_file(collided_with)
                b = fsutil.sha256_file(src)
                ctx.log.collision("backup", src, collided_with, cand, os.path.getsize(collided_with), a, size, b)
            return cand, "new"
        try:
            same = os.path.getsize(cand) == size and fsutil.sha256_file(cand) == fsutil.sha256_file(src)
        except OSError:
            same = False
        if same:
            return cand, "identical"
        collided_with = collided_with or cand
        i += 1
