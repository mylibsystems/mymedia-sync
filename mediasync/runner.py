"""Runs a list of tasks with worker threads, concurrency classes, pause/stop and a retry pass."""
from __future__ import annotations

import threading
import time
from collections import deque
from typing import Callable

from .model import Task


class TaskRunner:
    def __init__(self, status, stop: threading.Event, *, workers: int, video_workers: int = 1):
        self.status = status
        self.stop = stop
        self.workers = max(1, workers)
        self.video_workers = max(1, video_workers)

    def run(self, tasks: list[Task], handler: Callable[[Task], bool], *, retries: int = 0,
            on_retry: Callable[[Task], None] | None = None) -> list[Task]:
        """Execute tasks; handler returns True on success. Returns the tasks that still failed."""
        failed = self._pass(tasks, handler, self.workers)
        attempt = 0
        while failed and attempt < retries and not self.stop.is_set():
            attempt += 1
            time.sleep(2)
            batch = failed
            for t in batch:
                t.state = "queued"
                t.note = f"retry {attempt}"
                if on_retry:
                    on_retry(t)
            failed = self._pass(batch, handler, 1)       # sequential: no contention on retry
        return failed

    # ------------------------------------------------------------------
    def _pass(self, tasks: list[Task], handler, nthreads: int) -> list[Task]:
        st = self.status
        queue = deque(tasks)
        failed: list[Task] = []
        lock = st.lock
        video_running = [0]
        with lock:
            st.queue = queue
            st.workers_now = nthreads

        def pick():
            """(task, wait): the next runnable task honouring the video limit; wait=True when tasks
            remain but none may start yet; (None, False) when the queue is finished."""
            with lock:
                if st.stop_requested or self.stop.is_set():
                    return None, False
                scanned = 0
                for i, t in enumerate(queue):
                    if t.kind == "video" and video_running[0] >= self.video_workers:
                        scanned += 1
                        if scanned > 400:
                            break
                        continue
                    del queue[i]
                    if t.kind == "video":
                        video_running[0] += 1
                    t.state = "running"
                    t.started = time.time()
                    t.finished = 0.0
                    t.attempts += 1
                    st.active[t.id] = t
                    return t, False
                return None, bool(queue)

        def worker():
            while True:
                while st.paused and not self.stop.is_set():
                    time.sleep(0.3)
                t, wait = pick()
                if t is None:
                    if wait:
                        time.sleep(0.3)
                        continue
                    return
                ok = False
                try:
                    ok = bool(handler(t))
                except Exception as e:           # a bug must never take the whole run down
                    t.note = f"internal error: {e}"
                    ok = False
                finally:
                    with lock:
                        t.finished = time.time()
                        st.active.pop(t.id, None)
                        if t.kind == "video":
                            video_running[0] -= 1
                        if t.state == "running":
                            t.state = "done" if ok else "failed"
                if not ok and t.state == "failed":
                    with lock:
                        failed.append(t)

        threads = [threading.Thread(target=worker, daemon=True, name=f"worker-{i}") for i in range(nthreads)]
        for th in threads:
            th.start()
        for th in threads:
            th.join()
        with lock:
            st.queue = deque()
        return failed
