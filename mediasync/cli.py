"""Command line entry point: `python3 -m mediasync` (no arguments needed)."""
from __future__ import annotations

import argparse
import fcntl
import os
import signal
import sys
import threading

from . import __version__, config
from .guard import Guard
from .logs import RunLog
from .model import Status
from .pipeline import Ctx, Pipeline
from .state import State


def build_guard(s: config.Settings) -> Guard:
    protected = [s.router_root / "CAMERA", s.ingest_from / "CAMERA"]
    readonly = []
    if s.local_root is not None:
        readonly = [s.ingest_from / "UNSORTED", s.ingest_from / "CAMERA", s.router_root / "UNSORTED", s.router_root / "CAMERA"]
    delete_roots = [s.desktop_root, s.portable_root, s.staging]
    return Guard(camera=s.camera, unsorted=s.unsorted, protected=protected, readonly=readonly,
                 delete_roots=delete_roots)


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(prog="mediasync", description="MyMedia sync: ingest → backup → desktop → portable")
    ap.add_argument("--settings", help="path to settings.toml")
    ap.add_argument("--plain", action="store_true", help="plain text progress instead of the full-screen UI")
    ap.add_argument("--dry-run", action="store_true", help="scan and verify only; change nothing")
    ap.add_argument("--verify", action="store_true", help="deep-check every output again (ignore the cache)")
    ap.add_argument("--version", action="version", version=__version__)
    args = ap.parse_args(argv)

    s = config.load(args.settings)
    if args.verify:
        s.deep_verify = True
    problems = config.validate(s)
    if problems:
        for p in problems:
            print(f"mediasync: {p}", file=sys.stderr)
        return 2

    s.logs.mkdir(parents=True, exist_ok=True)
    lock = open(s.logs / ".mediasync.lock", "w")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        print("mediasync: another run is already in progress (lock held).", file=sys.stderr)
        return 3

    state = State(s.logs / "state.db")
    log = RunLog(s.logs)
    prior = {k: r for k in ("ingest", "backup", "desktop", "portable") if (r := state.last_rate(k))}
    status = Status(prior_rates=prior)
    status.slots = max(4, min(8, max(s.n_workers, s.ingest_streams)))
    stop = threading.Event()
    ctx = Ctx(s, status, log, state, build_guard(s), stop)
    pipe = Pipeline(ctx)
    log.info("start", f"mediasync {__version__}  local_root={s.local_root}  router_root={s.router_root}  dry_run={args.dry_run}")

    def target():
        if args.dry_run:
            try:
                status.state = "running"
                pipe.phase_scan()
                status.state = "done"
            except Exception as e:
                log.error("pipeline", f"{type(e).__name__}: {e}")
                status.state = "failed"
            finally:
                status.finished = __import__("time").time()
        else:
            pipe.run()

    th = threading.Thread(target=target, name="pipeline", daemon=True)

    def request_stop(*_):
        stop.set()
        status.stop_requested = True
        status.state = "finishing"
        ctx.engine.terminate_all()

    signal.signal(signal.SIGTERM, request_stop)
    th.start()
    use_tui = sys.stdout.isatty() and not args.plain and os.environ.get("TERM", "") not in ("", "dumb")
    try:
        if use_tui:
            from .ui_tui import run_tui
            run_tui(status, log, th, stop, request_stop)
        else:
            from .ui_plain import run_plain
            signal.signal(signal.SIGINT, request_stop)
            run_plain(status, log, th)
    finally:
        stop.set()
        th.join(timeout=120)
        ctx.close()
        log.close()
        state.close()
    snap = status.snapshot()
    if use_tui:
        print(f"mediasync: {snap['state']}  (logs: {log.dir})")
        for ln in snap["summary"]:
            print("  " + ln)
    failed = sum(p[5] for p in snap["phases"])
    return 0 if snap["state"] == "done" and failed == 0 and log.counts["ERROR"] == 0 else 1
