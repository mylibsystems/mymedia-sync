import random
import sys
import time
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from mediasync.model import Status, Task  # noqa: E402
from mediasync.ui_tui import MIN_COLS, MIN_ROWS, allocate, bar, compose, fit, width  # noqa: E402


def make_snapshot(kind="mid", n_active=3, n_queue=500, state="running"):
    st = Status(prior_rates={"desktop": 0.2})
    st.plan_phase("ingest", 12345)
    st.plan_phase("backup", 600)
    st.plan_phase("desktop", 46072)
    st.plan_phase("portable", 64789)
    st.slots = 8
    st.workers_now = 3
    st.state = state
    st.message = "Reading capture dates (65,054 files)…"
    names = ["IMG_0001.jpg", "日本語の長いファイル名テスト_ABCDEFGHIJKLMNOPQRSTUVWXYZ_0123456789.RW2",
             "a" * 300 + ".mp4", "tab\tname\nnewline.jpg", "ünïcödé ñame.heic", "😀emoji🎞.mov"]
    if kind == "start":
        st.phases["scan"].state = "running"
        st.current_phase = "scan"
        st.set_total("scan", 65054)
    elif kind in ("mid", "late"):
        st.begin_phase("desktop", 46072)
        st.advance("desktop", done=1234, failed=3)
        st.phases["scan"].state = "done"
        st.phases["ingest"].state = "done"
        st.phases["backup"].state = "skipped"
        for i in range(n_active):
            t = Task(i, "desktop", ["photo", "video", "audio", "file"][i % 4], names[i % len(names)], "x", 1000 + i)
            t.step, t.pct, t.started, t.speed = "converting image", (None if i % 2 else 41.5), time.time() - 75 * i, "3.2x"
            st.active[i] = t
        for i in range(n_queue):
            st.queue.append(Task(100 + i, "desktop", "photo", names[i % len(names)], "x", 123456 * (i % 50)))
    elif kind == "done":
        st.state = "done"
        st.summary = ["camera archive: 65,054 media files", "desktop confirmed: 65,054   not complete: 0",
                      "EVERYTHING CONFIRMED COMPLETE"]
        for k in ("scan", "ingest", "backup", "desktop", "portable", "finalize"):
            st.phases[k].state = "done"
    snap = st.snapshot()
    snap["recent"] = [(time.time(), "WARN", "desktop", "ünï\tcode warning " + "x" * 400, "/a/b/" + names[1]),
                      (time.time(), "ERROR", "portable", "something failed", "/a/b/IMG.jpg")]
    return snap


class LayoutTests(unittest.TestCase):
    def check(self, snap, rows, cols, **kw):
        frame = compose(snap, rows, cols, time.time(), spin=random.randint(0, 99), **kw)
        self.assertEqual(len(frame), rows, f"{cols}x{rows}: wrong row count")
        for y, spans in enumerate(frame):
            w = sum(width(t) for t, _ in spans)
            self.assertEqual(w, cols, f"{cols}x{rows} row {y}: width {w} != {cols}: {[t for t, _ in spans]}")
            for t, _ in spans:
                self.assertNotIn("\n", t)
                self.assertNotIn("\t", t)

    def test_all_sizes_all_states(self):
        sizes = [(r, c) for r in (14, 16, 18, 20, 22, 24, 26, 30, 40, 55, 80) for c in (60, 64, 70, 80, 100, 120, 160, 220)]
        for kind in ("start", "mid", "done"):
            for n_active in (0, 1, 4, 12):
                for n_queue in (0, 3, 5000):
                    snap = make_snapshot(kind, n_active, n_queue)
                    for rows, cols in sizes:
                        for off in (0, 7, 10_000):
                            self.check(snap, rows, cols, q_offset=off, log_dir="/mnt/local/logs", mbps=12.5)

    def test_ascii_fallback(self):
        snap = make_snapshot("mid", 4, 50)
        for rows, cols in ((24, 80), (30, 120)):
            self.check(snap, rows, cols, ascii_only=True)

    def test_too_small_terminal(self):
        snap = make_snapshot("mid")
        for rows, cols in ((10, 80), (30, 40), (5, 20), (1, 1)):
            frame = compose(snap, rows, cols, time.time())
            self.assertEqual(len(frame), rows)

    def test_allocation_always_sums_to_rows(self):
        for rows in range(MIN_ROWS, 120):
            for slots in (1, 2, 4, 8, 16):
                h = allocate(rows, slots)
                self.assertEqual(sum(h.values()), rows)
                self.assertGreaterEqual(h["queue"], 2)

    def test_queue_is_the_only_flexible_section(self):
        a = allocate(40, 4)
        b = allocate(80, 4)
        for k in ("header", "overall", "phases", "workers", "issues", "footer"):
            self.assertEqual(a[k], b[k], k)          # fixed-size widgets do not grow with the terminal
        self.assertGreater(b["queue"], a["queue"])

    def test_bar_and_fit(self):
        for w in (1, 5, 40):
            for f in (None, 0, 0.3333, 1, 1.5, -1):
                self.assertEqual(width(bar(f, w)), w)
        self.assertEqual(width(fit("日本語日本語日本語", 7)), 7)
        self.assertEqual(width(fit("abc", 10)), 10)


if __name__ == "__main__":
    unittest.main()
