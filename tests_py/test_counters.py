import tempfile
import unittest
from pathlib import Path

from mediasync.logs import RunLog
from mediasync.model import Status


class IssueCounters(unittest.TestCase):
    def test_ui_counters_follow_what_is_logged(self):
        with tempfile.TemporaryDirectory() as d:
            log, st = RunLog(Path(d)), Status()
            log.status = st
            log.info("x", "fine")
            log.warn("x", "a warning", "/f1")
            log.error("x", "an error", "/f2")
            log.error("x", "another error", "/f3")
            log.collision("backup", "/w", "/e", "/k", 1, "a", 2, "b")      # logs one warning and one collision
            snap = st.snapshot()
            self.assertEqual((snap["errors"], snap["warnings"], snap["collisions"]), (2, 2, 1))
            self.assertEqual(len([r for r in log.recent_issues if r[1] == "ERROR"]), 2)
            log.close()


if __name__ == "__main__":
    unittest.main()
