"""Plain-text progress (no terminal needed): one line every few seconds, plus issues as they happen."""
from __future__ import annotations

import sys
import time

from .fsutil import human_duration


def run_plain(status, log, thread, interval: float = 5.0, out=sys.stdout) -> None:
    last_issue = 0
    last_print = 0.0
    while thread.is_alive():
        time.sleep(0.5)
        now = time.time()
        # new warnings/errors
        issues = list(log.recent_issues)
        for ts, level, phase, msg, f in issues:
            if ts > last_issue:
                out.write(f"  {level:5s} [{phase}] {msg}" + (f"  | {f}" if f else "") + "\n")
                last_issue = max(last_issue, ts)
        if now - last_print >= interval:
            last_print = now
            snap = status.snapshot()
            ov = snap["overall"]
            cur = snap["current"] or "-"
            ph = next((p for p in snap["phases"] if p[0] == cur), None)
            part = ""
            if ph:
                part = f" {ph[1]} {ph[4]}/{ph[3]}" + (f" failed={ph[5]}" if ph[5] else "")
            out.write(f"[{time.strftime('%H:%M:%S')}] overall {ov['done']}/{ov['total']} {ov['pct']:.0f}% "
                      f"ETA {human_duration(ov['eta'])} |{part} | active {len(snap['active'])}"
                      f" | warn {log.counts['WARN']} err {log.counts['ERROR']}\n")
            out.flush()
    snap = status.snapshot()
    out.write(f"finished: {snap['state']}\n")
    for ln in snap["summary"]:
        out.write(f"  {ln}\n")
    out.flush()
