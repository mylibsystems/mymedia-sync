"""The pipeline: plan -> ingest -> backup -> desktop -> portable -> finalize (+ confirmation)."""
from __future__ import annotations

import itertools
import os
import shutil
import subprocess
import threading
import time
from collections import deque
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
from pathlib import Path

from . import fsutil, native
from .config import REPO, SOURCE_TYPES
from .engine import Engine
from .guard import Guard, ProtectedPathError
from .inventory import Verifier, is_output_media, portable_rel, scan_inventory, Inventory
from .logs import RunLog
from .model import Status, Task
from .probe import ExifPool, capture_date
from .runner import TaskRunner
from .state import State

# Source folder -> (library, worker label rule). Same mapping as the stages in sync.sh.
SOURCE_STAGES = [("DOWNLOADS", "MOVIES"), ("MUSIC", "MUSIC"), ("MOVIES", "MOVIES"), ("TV", "TV"), ("PHOTOS", "PHOTOS")]


def script(name: str) -> str:
    return str(REPO / name)


class Ctx:
    """Everything the phases share."""

    def __init__(self, settings, status: Status, log: RunLog, state: State, guard: Guard, stop: threading.Event):
        self.settings, self.status, self.log, self.state, self.guard, self.stop = settings, status, log, state, guard, stop
        self.engine = Engine(status, log, stop)
        self.verifier = Verifier(state, log, deep_all=settings.deep_verify, threads=16)
        self.camera_lock = threading.Lock()
        self._ids = itertools.count(1)
        self._exif: ExifPool | None = None
        self._exif_lock = threading.Lock()

    def next_id(self) -> int:
        return next(self._ids)

    def exif(self) -> ExifPool:
        with self._exif_lock:
            if self._exif is None:
                self._exif = ExifPool(4)
            return self._exif

    def close(self):
        if self._exif:
            self._exif.close()


@dataclass
class CamItem:
    rel: str
    size: int
    mtime: int
    kind: str
    y: str
    m: str
    d: str
    out_rel: str = ""
    plain_rel: str = ""
    d_state: str = "missing"        # ok | missing | bad
    d_detail: str = ""
    note: str = ""


class Pipeline:
    def __init__(self, ctx: Ctx):
        self.ctx = ctx
        self.s = ctx.settings
        self.st = ctx.status
        self.log = ctx.log
        self.stop = ctx.stop
        self.runner = TaskRunner(self.st, self.stop, workers=self.s.n_workers, video_workers=self.s.video_workers)
        self.inv: Inventory | None = None
        self.cam_items: list[CamItem] = []
        self.ingest_tasks: list[Task] = []
        self.combined_music_ctx: dict[str, str] = {}
        self.music_touched = False

    # ======================================================================
    def run(self) -> None:
        st = self.st
        try:
            st.state = "running"
            os.makedirs(self.s.staging / "tmp", exist_ok=True)
            os.makedirs(self.s.logs / "engine", exist_ok=True)
            self._import_engine_index()
            for name in ("scan", "ingest", "backup", "desktop", "portable", "finalize"):
                if self.stop.is_set():
                    break
                getattr(self, f"phase_{name}")()
            st.state = "stopped" if self.stop.is_set() else "done"
        except Exception as e:                          # report, never crash silently
            import traceback
            self.log.error("pipeline", f"{type(e).__name__}: {e}")
            self.log.error("pipeline", traceback.format_exc().replace("\n", " | ")[:1500])
            st.state = "failed"
            st.message = f"{type(e).__name__}: {e}"
        finally:
            self.ctx.engine.terminate_all()
            self.ctx.verifier.flush()
            st.finished = time.time()
            self._write_history()

    def _write_history(self):
        for key in ("ingest", "backup", "desktop", "portable"):
            ph = self.st.phases[key]
            if ph.state == "done" and ph.done > 0:
                self.ctx.state.add_history(key, ph.done, ph.active_seconds)

    def _import_engine_index(self) -> None:
        """The shell workers record archive -> output in a TSV; keep it in the database."""
        idx = self.s.logs / "camera-built.tsv"
        for path in (idx, REPO / "logs" / ".camera-built.tsv"):
            if not path.is_file():
                continue
            rows = {}
            try:
                for line in path.read_text(errors="replace").splitlines():
                    a = line.split("\t")
                    if len(a) >= 2 and a[0] and a[1]:
                        rows[a[0]] = a[1]
            except OSError:
                continue
            if rows:
                self.ctx.state.set_built(list(rows.items()))

    # ======================================================================
    # PHASE 0 — scan & verify
    # ======================================================================
    def phase_scan(self):
        ctx, st = self.ctx, self.st
        st.begin_phase("scan", 1, "listing folders")
        st.message = "Listing every input and output folder…"
        self.inv = scan_inventory(self.s, st, self.log, self.stop)
        if self.stop.is_set():
            return
        # ingest plan (router listing)
        st.message = "Planning ingest from the router…"
        self.ingest_tasks, notes = native.plan_ingest(ctx, self.stop)
        for n in notes:
            self.log.info("scan", n)
        ing_bytes = sum(t.size for t in self.ingest_tasks)
        st.bytes_total = ing_bytes
        if self.ingest_tasks and self.s.local_root is not None:
            free = shutil.disk_usage(self.s.local_root).free
            if ing_bytes > free:
                raise RuntimeError(f"not enough free space on the local disk for the ingest: need "
                                   f"{fsutil.human_bytes(ing_bytes)}, free {fsutil.human_bytes(free)}")
        # camera: dates + desktop verification
        self.cam_items = self.plan_camera(self.inv, scan_phase=True)
        todo_desktop = [c for c in self.cam_items if c.d_state != "ok"]
        # portable (all libraries)
        port = self.plan_portable(self.inv, scan_phase=True)
        backup_tasks = native.plan_backup(ctx, self.inv)
        combined = self.plan_combined(self.inv, dry=True)
        # files that will only arrive through the ingest still need backup / desktop / portable
        in_cam = in_comb = 0
        for t in self.ingest_tasks:
            label = t.meta.get("label", "")
            c = fsutil.classify(t.name)
            if label == "UNSORTED/CAMERA":
                in_cam += c in ("photo", "video")
            elif label == "UNSORTED/MUSIC":
                in_comb += c == "audio"
            elif label.startswith("UNSORTED/") and label != "UNSORTED/VIDEO":
                in_comb += c in ("video", "photo")
        n_new = len(backup_tasks) + in_cam
        n_comb = len(combined) + in_comb
        st.plan_phase("ingest", len(self.ingest_tasks), "files to copy")
        st.plan_phase("backup", n_new, "files to archive")
        st.plan_phase("desktop", len(todo_desktop) + n_new + n_comb, "outputs to build")
        st.plan_phase("portable", len(port["todo"]) + len(todo_desktop) + n_new + n_comb, "outputs to derive")
        confirmed = sum(1 for c in self.cam_items if c.d_state == "ok")
        st.end_phase("scan")
        st.summary = [f"confirmed complete: {confirmed:,} camera files have a valid desktop copy, "
                      f"{port['ok']:,} valid portable copies"]
        self.log.info("scan", f"confirmed: {confirmed} camera files with valid desktop output; "
                              f"{port['ok']} valid portable outputs; to do: ingest {len(self.ingest_tasks)}, "
                              f"backup {n_new}, desktop {len(todo_desktop) + n_new + n_comb}, "
                              f"portable {len(port['todo']) + len(todo_desktop) + n_new + n_comb}")

    # ---------------------------------------------------------------- camera
    def plan_camera(self, inv: Inventory, *, scan_phase: bool = False) -> list[CamItem]:
        ctx, st = self.ctx, self.st
        dates = ctx.state.load_dates()
        built = ctx.state.load_built()
        items: list[CamItem] = []
        need = []
        for rel, size, mt in inv.camera:
            base = os.path.basename(rel)
            kind = fsutil.classify(base)
            if kind not in ("photo", "video"):
                continue
            c = dates.get(rel)
            if c and c[0] == size and c[1] == mt:
                items.append(CamItem(rel, size, mt, kind, c[2], c[3], c[4]))
            else:
                need.append((rel, size, mt, kind))
        if need:
            st.message = f"Reading capture dates ({len(need):,} files)…"
            if scan_phase:
                st.set_total("scan", len(need))
            pool = ctx.exif()
            root = str(self.s.camera)

            def one(n):
                rel, size, mt, kind = n
                try:
                    return n, capture_date(os.path.join(root, rel), pool)
                except Exception:
                    return n, None

            rows = []
            with ThreadPoolExecutor(4) as ex:
                for i, (n, d) in enumerate(ex.map(one, need), 1):
                    rel, size, mt, kind = n
                    if d is None:
                        self.log.warn("scan", "no capture date; cannot be placed in the library", rel)
                        continue
                    items.append(CamItem(rel, size, mt, kind, d[0], d[1], d[2]))
                    rows.append((rel, size, mt, d[0], d[1], d[2], d[3]))
                    if scan_phase and i % 100 == 0:
                        st.advance("scan", done=100)
                    if self.stop.is_set():
                        break
            ctx.state.set_dates(rows)
        # expected desktop output + existence
        desk = inv.desktop.get("PHOTOS", {})
        check = []
        for it in items:
            stem = os.path.splitext(os.path.basename(it.rel))[0]
            ext = "m4v" if it.kind == "video" else "jpg"
            it.plain_rel = f"{it.y}-{it.m}-{it.d}/{stem}.{ext}"
            out = built.get(it.rel) or it.plain_rel
            if out not in desk and it.plain_rel in desk:
                out = it.plain_rel
            if out not in desk:
                variants = [f"{it.y}-{it.m}-{it.d}/{stem}_{n}.{ext}" for n in range(1, 10)]
                hit = next((v for v in variants if v in desk), None)
                if hit and it.rel not in built:
                    out, it.note = hit, "variant name"
            it.out_rel = out
            if out in desk:
                size, mt = desk[out]
                ref = None
                if it.kind == "video":
                    ref = (str(self.s.camera / it.rel), it.size, it.mtime)
                check.append((it.rel, str(self.s.desktop("PHOTOS") / out), size, mt, it.kind, ref))
            else:
                it.d_state = "missing"
        if check:
            st.message = f"Verifying {len(check):,} desktop outputs…"
            if scan_phase:
                st.set_total("scan", len(need) + len(check))
            base_done = len(need)

            def prog(n):
                if scan_phase:
                    with st.lock:
                        ph = st.phases["scan"]
                        ph.done = base_done + n

            res = ctx.verifier.check_many(check, progress=prog, stop=self.stop)
            by_rel = {it.rel: it for it in items}
            for key, (ok, detail) in res.items():
                it = by_rel[key]
                it.d_state = "ok" if ok else "bad"
                it.d_detail = detail
        return items

    # -------------------------------------------------------------- portable
    def plan_portable(self, inv: Inventory, *, scan_phase: bool = False) -> dict:
        """Which desktop outputs lack a valid portable copy (all four libraries)."""
        ctx, st = self.ctx, self.st
        todo: list[dict] = []
        ok_count = 0
        blocked = 0
        for lib in ("PHOTOS", "MUSIC", "MOVIES", "TV"):
            desk = inv.desktop.get(lib, {})
            port = inv.portable.get(lib, {})
            entries = []
            for rel, (size, mt) in desk.items():
                kind = self._output_kind(lib, rel)
                if not kind:
                    continue
                prel = portable_rel(lib, rel)
                entries.append((rel, size, mt, kind, prel))
            # 1) existing portable copies
            checks = []
            for rel, size, mt, kind, prel in entries:
                if prel in port:
                    psize, pmt = port[prel]
                    ref = (str(self.s.desktop(lib) / rel), size, mt) if kind != "photo" else None
                    checks.append((rel, str(self.s.portable(lib) / prel), psize, pmt, kind, ref))
            res = ctx.verifier.check_many(checks, stop=self.stop) if checks else {}
            need_desktop_check = []
            for rel, size, mt, kind, prel in entries:
                r = res.get(rel)
                if r is not None and r[0]:
                    ok_count += 1
                    continue
                need_desktop_check.append((rel, str(self.s.desktop(lib) / rel), size, mt, kind, None))
                if r is not None:
                    todo_reason = f"damaged portable: {r[1]}"
                else:
                    todo_reason = "missing"
                todo.append({"lib": lib, "rel": rel, "prel": prel, "kind": kind, "size": size,
                             "reason": todo_reason, "desktop_ok": True})
            # 2) a portable copy can only be derived from a valid desktop file
            if need_desktop_check:
                dres = ctx.verifier.check_many(need_desktop_check, stop=self.stop)
                for t in todo:
                    if t["lib"] == lib and t["desktop_ok"]:
                        okd = dres.get(t["rel"], (True, ""))
                        t["desktop_ok"] = okd[0]
                        t["desktop_detail"] = okd[1]
        buildable = [t for t in todo if t["desktop_ok"]]
        blocked = len(todo) - len(buildable)
        return {"todo": buildable, "blocked": [t for t in todo if not t["desktop_ok"]], "ok": ok_count}

    def _output_kind(self, lib: str, rel: str) -> str | None:
        base = os.path.basename(rel)
        if lib == "PHOTOS":
            return is_output_media(rel)
        if fsutil.is_hidden(base):
            return None
        e = fsutil.ext_of(base)
        if lib == "MUSIC":
            return "audio" if e == "flac" else None
        return "video" if e == "m4v" else None

    # ------------------------------------------------- non-camera sources
    def plan_combined(self, inv: Inventory, dry: bool = False) -> list[Task]:
        """UNSORTED music/movies/tv/photos/downloads: one worker builds desktop then portable."""
        tasks: list[Task] = []
        for kind, lib in SOURCE_STAGES:
            rows = inv.unsorted.get(kind, [])
            by_top: dict[str, list] = {}
            for rel, size, mt in rows:
                if "/" not in rel:
                    continue                       # stray files directly in the folder are ignored
                by_top.setdefault(rel.split("/", 1)[0], []).append((rel, size))
            for top, files in sorted(by_top.items()):
                srcdir = str(self.s.source_dir(kind) / top) + "/"      # trailing slash, as sync.sh passes it
                for rel, size in sorted(files):
                    c = fsutil.classify(os.path.basename(rel))
                    ok = (c == "audio") if kind == "MUSIC" else (c in ("video", "photo"))
                    if not ok:
                        continue
                    full = str(self.s.source_dir(kind) / rel)
                    t = Task(self.ctx.next_id(), "desktop", "video" if c == "video" else ("audio" if c == "audio" else "photo"),
                             os.path.basename(rel), full, size, units=2,
                             meta={"combined": True, "stage": kind, "lib": lib, "top": top, "srcdir": srcdir})
                    tasks.append(t)
        return tasks

    # ======================================================================
    # PHASE — ingest
    # ======================================================================
    def phase_ingest(self):
        st = self.st
        tasks = self.ingest_tasks
        if not tasks:
            st.begin_phase("ingest", 0)
            st.end_phase("ingest", "skipped")
            return
        st.begin_phase("ingest", len(tasks), "copying router → local disk (router is never modified)")
        self.log.info("ingest", f"{len(tasks)} files, {fsutil.human_bytes(sum(t.size for t in tasks))}")
        runner = TaskRunner(st, self.stop, workers=self.s.ingest_streams)

        def handler(t):
            ok = native.ingest_task(self.ctx, t)
            if ok:
                st.advance("ingest", done=1)
            return ok

        failed = runner.run(tasks, handler, retries=self.s.retry)
        if failed:
            st.advance("ingest", failed=len(failed))
            for t in failed:
                self.log.error("ingest", f"not copied: {t.note or 'failed'}", t.src)
        st.end_phase("ingest")
        # the local trees changed
        self._refresh_local()

    def _refresh_local(self):
        inv = self.inv
        s = self.s
        for kind in SOURCE_TYPES:
            inv.unsorted[kind] = list(fsutil.scan_tree(s.source_dir(kind)))
        inv.camera = list(fsutil.scan_tree(s.camera))

    # ======================================================================
    # PHASE — backup (UNSORTED/CAMERA -> CAMERA)
    # ======================================================================
    def phase_backup(self):
        st = self.st
        tasks = native.plan_backup(self.ctx, self.inv)
        if not tasks:
            st.begin_phase("backup", 0)
            st.end_phase("backup", "skipped")
            return
        st.begin_phase("backup", len(tasks), "moving originals into the camera archive")
        runner = TaskRunner(st, self.stop, workers=4)

        def handler(t):
            ok = native.backup_task(self.ctx, t)
            if ok:
                st.advance("backup", done=1)
            return ok

        failed = runner.run(tasks, handler, retries=0)
        if failed:
            st.advance("backup", failed=len(failed))
        st.end_phase("backup")
        self.inv.camera = list(fsutil.scan_tree(self.s.camera))
        self.inv.unsorted["CAMERA"] = list(fsutil.scan_tree(self.s.source_dir("CAMERA")))

    # ======================================================================
    # PHASE — desktop
    # ======================================================================
    def phase_desktop(self):
        st = self.st
        # fresh plan: archive may have grown, desktop listing may have changed
        self.inv.desktop["PHOTOS"] = {r: (sz, mt) for r, sz, mt in fsutil.scan_tree(self.s.desktop("PHOTOS"))}
        items = [c for c in self.plan_camera(self.inv) if c.d_state != "ok"]
        tasks: list[Task] = []
        for c in items:
            src = str(self.s.camera / c.rel)
            expected = str(self.s.desktop("PHOTOS") / (c.out_rel if c.d_state == "bad" else c.plain_rel))
            t = Task(self.ctx.next_id(), "desktop", c.kind, os.path.basename(c.rel), src, c.size,
                     argv=[script("orginize.sh"), src, "camera", str(self.s.desktop("PHOTOS")), str(self.s.camera)],
                     env=self.s.engine_env({"CAMERA_PHASE": "build", "ENABLE_PORTABLE": "0"}),
                     meta={"camera": True, "rel": c.rel, "expected": expected, "plain_rel": c.plain_rel,
                           "remove_first": [expected] if c.d_state == "bad" else [],
                           "reason": c.d_detail})
            tasks.append(t)
        combined = self.plan_combined(self.inv)
        self._prepare_combined(combined)
        tasks += combined
        tasks.sort(key=lambda t: (0 if t.kind == "video" else 1, -t.size))
        st.begin_phase("desktop", len(tasks), "building LIBRARY.DESKTOP")
        self.log.info("desktop", f"{len(tasks)} outputs to build")
        if not tasks:
            st.end_phase("desktop", "done")
            return

        def handler(t):
            ok = self._engine_task(t)
            if ok:
                st.advance("desktop", done=1)
                if t.meta.get("combined"):
                    st.advance("portable", done=1)       # the same worker also built the portable copy
            return ok

        failed = self.runner.run(tasks, handler, retries=self.s.retry,
                                 on_retry=lambda t: self.log.info("desktop", "retrying", t.src))
        if failed:
            st.advance("desktop", failed=len(failed))
            for t in failed:
                if t.meta.get("combined"):
                    st.advance("portable", failed=1)
        st.end_phase("desktop")

    def _prepare_combined(self, tasks: list[Task]) -> None:
        """Music needs the per-album context first; build commands for every combined task."""
        by_dir: dict[str, list[Task]] = {}
        for t in tasks:
            by_dir.setdefault(t.meta["srcdir"], []).append(t)
        for srcdir, ts in by_dir.items():
            stage = ts[0].meta["stage"]
            env_extra = {}
            if stage == "MUSIC":
                if self.stop.is_set():
                    break
                ctxdir = str(self.s.staging / "albumctx" / str(abs(hash(srcdir)) % 10**9))
                self._album_context(srcdir, ctxdir)
                env_extra["ALBUM_CTX_DIR"] = ctxdir
                self.music_touched = True
            for t in ts:
                lib = t.meta["lib"]
                t.argv = [script("orginize.sh"), t.src, t.meta["top"], str(self.s.desktop(lib)), t.meta["srcdir"]]
                t.env = self.s.engine_env(env_extra)

    def _album_context(self, srcdir: str, ctxdir: str) -> None:
        t = Task(self.ctx.next_id(), "desktop", "audio", f"album context: {os.path.basename(srcdir)}", srcdir, 0,
                 argv=[script("album_ctx.sh"), ctxdir, srcdir], env=self.s.engine_env())
        t.state, t.started = "running", time.time()
        with self.st.lock:
            self.st.active[t.id] = t
        try:
            res = self.ctx.engine.run(t)
            if res.rc != 0:
                self.log.warn("desktop", f"album context step exited {res.rc}; embedded tags will be used", srcdir)
        finally:
            with self.st.lock:
                self.st.active.pop(t.id, None)

    # ---------------------------------------------------------- engine tasks
    def _engine_task(self, t: Task) -> bool:
        ctx, log = self.ctx, self.log
        for path in t.meta.get("remove_first", []):
            self._remove_damaged(path, t.meta.get("reason", "damaged"))
        res = ctx.engine.run(t)
        for lvl, msg in res.problems:
            (log.error if lvl == "ERROR" else log.warn)(t.phase, msg[:300], t.src)
        if res.rc != 0:
            tail = " | ".join(res.tail[-3:])[:300]
            log.error(t.phase, f"worker failed (exit {res.rc}): {tail}", t.src)
            t.note = f"exit {res.rc}"
            return False
        return self._post_verify(t, res)

    def _remove_damaged(self, path: str, why: str) -> None:
        try:
            self.ctx.guard.remove_file(path)
            self.ctx.verifier.forget(path)
            self.log.warn("verify", f"damaged output removed so it is rebuilt ({why})", path)
            self.log.record("removed-damaged.csv", ["time", "path", "reason"], [time.strftime("%F %T"), path, why])
        except FileNotFoundError:
            pass
        except (OSError, ProtectedPathError) as e:
            self.log.error("verify", f"cannot remove damaged output: {e}", path)

    def _post_verify(self, t: Task, res) -> bool:
        v = self.ctx.verifier
        if t.meta.get("camera"):
            desk_root = str(self.s.desktop("PHOTOS"))
            outs = [p for p in res.outputs if p.startswith(desk_root + "/")]
            path = outs[-1] if outs else t.meta["expected"]
            try:
                stt = os.stat(path)
            except OSError:
                self.log.error("desktop", "worker reported success but the output does not exist", t.src)
                return False
            ref = (t.src, t.size, os.stat(t.src).st_mtime_ns) if t.kind == "video" else None
            ok, detail = v.check(path, stt.st_size, stt.st_mtime_ns, t.kind, ref)
            v.flush()
            if not ok:
                self.log.error("desktop", f"output failed verification ({detail}); kept for inspection, "
                                          f"it is rebuilt on the next run", path)
                return False
            out_rel = os.path.relpath(path, desk_root)
            self.ctx.state.set_built([(t.meta["rel"], out_rel)])
            if out_rel != t.meta["plain_rel"]:
                self.log.record("name-variants.csv", ["time", "archive_file", "stored_as", "size"],
                                [time.strftime("%F %T"), t.meta["rel"], out_rel, stt.st_size])
            return True
        if t.meta.get("portable"):
            path = t.meta["expected"]
            try:
                stt = os.stat(path)
            except OSError:
                self.log.error("portable", "worker reported success but the output does not exist", t.src)
                return False
            ref = None
            if t.kind != "photo":
                ds = os.stat(t.src)
                ref = (t.src, ds.st_size, ds.st_mtime_ns)
            ok, detail = v.check(path, stt.st_size, stt.st_mtime_ns, t.kind, ref)
            v.flush()
            if not ok:
                self.log.error("portable", f"output failed verification ({detail}); kept for inspection, "
                                           f"it is rebuilt on the next run", path)
                return False
            return True
        # combined worker: verify whatever it reported
        bad = False
        for p in res.outputs:
            e = fsutil.ext_of(p)
            kind = "audio" if e in ("flac", "m4a") else "video" if e in ("m4v", "mp4") else "photo" if e in ("jpg", "jpeg") else None
            if not kind or fsutil.is_hidden(os.path.basename(p)):
                continue
            try:
                stt = os.stat(p)
            except OSError:
                continue
            ok, detail = v.check(p, stt.st_size, stt.st_mtime_ns, kind, None)
            if not ok:
                self.log.error(t.phase, f"output failed verification ({detail}); kept for inspection, "
                                        f"it is rebuilt on the next run", p)
                bad = True
        v.flush()
        return not bad

    # ======================================================================
    # PHASE — portable
    # ======================================================================
    def phase_portable(self):
        st = self.st
        inv = self.inv
        for lib in ("PHOTOS", "MUSIC", "MOVIES", "TV"):
            inv.desktop[lib] = {r: (sz, mt) for r, sz, mt in fsutil.scan_tree(self.s.desktop(lib))}
            inv.portable[lib] = {r: (sz, mt) for r, sz, mt in fsutil.scan_tree(self.s.portable(lib))}
        st.message = "Verifying what is already in LIBRARY.PORTABLE…"
        plan = self.plan_portable(inv)
        tasks: list[Task] = []
        for it in plan["todo"]:
            lib, rel, prel, kind = it["lib"], it["rel"], it["prel"], it["kind"]
            dfile = str(self.s.desktop(lib) / rel)
            pfile = str(self.s.portable(lib) / prel)
            wkind = "audio" if lib == "MUSIC" else "video" if lib in ("MOVIES", "TV") else "photo"
            tasks.append(Task(self.ctx.next_id(), "portable", "video" if kind == "video" else kind, os.path.basename(rel), dfile,
                              it["size"],
                              argv=[script("portablize.sh"), "one", wkind, dfile, str(self.s.desktop(lib)), str(self.s.portable(lib))],
                              env=self.s.engine_env(),
                              meta={"portable": True, "expected": pfile, "lib": lib,
                                    "remove_first": [pfile] if it["reason"].startswith("damaged") else [],
                                    "reason": it["reason"]}))
        for b in plan["blocked"]:
            self.log.warn("portable", f"cannot derive: desktop copy is damaged ({b.get('desktop_detail', '')})",
                          str(self.s.desktop(b["lib"]) / b["rel"]))
        tasks.sort(key=lambda t: (0 if t.kind == "video" else 1, -t.size))
        st.begin_phase("portable", len(tasks), "deriving LIBRARY.PORTABLE from LIBRARY.DESKTOP")
        self.log.info("portable", f"{len(tasks)} outputs to derive ({len(plan['blocked'])} blocked by damaged desktop files)")
        if not tasks:
            st.end_phase("portable")
            return

        def handler(t):
            ok = self._engine_task(t)
            if ok:
                st.advance("portable", done=1)
                if t.meta["lib"] == "MUSIC":
                    self.music_touched = True
            return ok

        failed = self.runner.run(tasks, handler, retries=self.s.retry,
                                 on_retry=lambda t: self.log.info("portable", "retrying", t.src))
        if failed:
            st.advance("portable", failed=len(failed))
        st.end_phase("portable")

    # ======================================================================
    # PHASE — finalize (cleanup, playlists, confirmation)
    # ======================================================================
    def phase_finalize(self):
        st = self.st
        st.begin_phase("finalize", 1, "cleanup and final confirmation")
        st.message = "Cleaning up…"
        self.sweep_staging()
        self.cleanup_inbox()
        if self.music_touched and not self.stop.is_set():
            self.make_playlists()
        if not self.stop.is_set():
            self.confirm()
        st.advance("finalize", done=1)
        st.end_phase("finalize")

    def sweep_staging(self) -> None:
        n = 0
        for root in (self.s.desktop_root, self.s.portable_root, self.s.staging):
            if not root.is_dir():
                continue
            try:
                out = subprocess.run(["find", str(root), "-maxdepth", "5", "-type", "d", "-name", ".media-sync-staging-*"],
                                     capture_output=True, text=True, timeout=600).stdout.split("\n")
            except (OSError, subprocess.SubprocessError):
                continue
            for d in filter(None, out):
                pid = d.rsplit("-", 1)[-1]
                if pid.isdigit() and os.path.isdir(f"/proc/{pid}"):
                    continue
                try:
                    shutil.rmtree(d)
                    n += 1
                except OSError:
                    pass
        self.log.info("finalize", f"removed {n} stale staging folder(s)")

    def cleanup_inbox(self) -> None:
        """Remove emptied folders in the local inbox (never the type folders, never the camera archive)."""
        removed = 0
        for kind in SOURCE_TYPES:
            root = self.s.source_dir(kind)
            if not root.is_dir():
                continue
            for dirpath, dirnames, filenames in os.walk(root, topdown=False):
                if Path(dirpath) == root:
                    continue
                real = [f for f in filenames if f.lower() not in fsutil.NOISE_NAMES and not f.startswith("._")]
                if real or [d for d in dirnames if os.path.isdir(os.path.join(dirpath, d))]:
                    continue
                try:
                    for f in filenames:
                        self.ctx.guard.remove_file(os.path.join(dirpath, f))
                    if self.ctx.guard.remove_empty_dir(dirpath):
                        removed += 1
                except (OSError, ProtectedPathError):
                    pass
        self.log.info("finalize", f"removed {removed} empty inbox folder(s)")

    def make_playlists(self) -> None:
        self.st.message = "Generating music playlists…"
        env = self.s.engine_env()
        cmd = ('source "$0/config.sh" >/dev/null 2>&1; source "$0/playlist.sh"; '
               'generate_music_playlists "$DESKTOP_MUSIC_ROOT" flac; generate_music_playlists "$PORTABLE_MUSIC_ROOT" m4a')
        r = subprocess.run(["bash", "-c", cmd, str(REPO)], env=env, capture_output=True, text=True)
        self.log.info("finalize", f"playlists generated (exit {r.returncode})")

    def confirm(self) -> None:
        """Re-scan everything and report what is confirmed complete and what is not."""
        st = self.st
        st.message = "Final confirmation: scanning everything once more…"
        inv = scan_inventory(self.s, st, self.log, self.stop)
        self.inv = inv
        items = self.plan_camera(inv)
        bad = [c for c in items if c.d_state != "ok"]
        port = self.plan_portable(inv)
        undated = 0
        lines = [
            f"camera archive: {len(items):,} media files",
            f"desktop confirmed: {len(items) - len(bad):,}   not complete: {len(bad):,}",
            f"portable confirmed: {port['ok']:,}   not complete: {len(port['todo']) + len(port['blocked']):,}",
        ]
        left = sum(len(v) for k, v in inv.unsorted.items() if k != "CAMERA")
        lines.append(f"inbox: {sum(len(v) for v in inv.unsorted.values()):,} file(s) left")
        for c in bad[:200]:
            self.log.record("final-report.csv", ["time", "what", "file", "state", "detail"],
                            [time.strftime("%F %T"), "desktop", c.rel, c.d_state, c.d_detail])
        for it in (port["todo"] + port["blocked"])[:2000]:
            self.log.record("final-report.csv", ["time", "what", "file", "state", "detail"],
                            [time.strftime("%F %T"), "portable", it["rel"], it["reason"], it.get("desktop_detail", "")])
        st.summary = lines
        for ln in lines:
            self.log.info("confirm", ln)
        if not bad and not port["todo"] and not port["blocked"]:
            st.summary.append("EVERYTHING CONFIRMED COMPLETE")
            self.log.info("confirm", "everything confirmed complete")
