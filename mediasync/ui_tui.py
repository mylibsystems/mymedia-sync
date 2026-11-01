"""Full-screen terminal UI.

Design rules
  * The layout is computed from the real terminal size on EVERY frame: nothing ever wraps or
    scrolls the terminal; only the "UP NEXT" list scrolls, inside its own area, and it follows
    the live queue.
  * compose() is a pure function (snapshot + size -> rows of styled text) so the layout can be
    tested without a terminal; the curses layer only paints what compose() returns.
"""
from __future__ import annotations

import curses
import locale
import os
import time
import unicodedata

from .fsutil import human_bytes, human_duration

MIN_ROWS, MIN_COLS = 14, 60
SPINNER = "⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏"
PARTIAL = " ▏▎▍▌▋▊▉"
KIND_TAG = {"photo": "PHO", "video": "VID", "audio": "AUD", "file": "FIL"}
PHASE_ORDER = ["scan", "ingest", "backup", "desktop", "portable", "finalize"]
PHASE_NO = {k: i for i, k in enumerate(PHASE_ORDER)}


# ---------------------------------------------------------------------------
# text measurement / fitting (cell width, so wide characters never break the layout)
# ---------------------------------------------------------------------------
def cw(ch: str) -> int:
    if unicodedata.combining(ch):
        return 0
    return 2 if unicodedata.east_asian_width(ch) in ("W", "F") else 1


def width(s: str) -> int:
    return sum(cw(c) for c in s)


def clean(s: str) -> str:
    return "".join(c if c.isprintable() else " " for c in s)


def fit(s: str, w: int, pad: bool = True) -> str:
    """Exactly w cells (truncated with … or padded)."""
    s = clean(s)
    if w <= 0:
        return ""
    if width(s) <= w:
        return s + " " * (w - width(s)) if pad else s
    out, used = "", 0
    for c in s:
        c_w = cw(c)
        if used + c_w > w - 1:
            break
        out += c
        used += c_w
    return out + "…" + " " * max(0, w - used - 1) if pad else out + "…"


def bar(frac: float | None, w: int, ascii_only: bool = False, spin: int | None = None) -> str:
    if w <= 0:
        return ""
    if frac is None:                      # progress unknown: a moving block shows the file is being worked on
        seg = max(2, w // 5)
        pos = (spin or 0) % (w + seg) - seg
        track = ["-" if ascii_only else "░"] * w
        for i in range(max(0, pos), min(w, pos + seg)):
            track[i] = "=" if ascii_only else "▒"
        return "".join(track)
    frac = max(0.0, min(1.0, frac))
    if ascii_only:
        n = int(round(frac * w))
        return "#" * n + "-" * (w - n)
    cells = frac * w
    full = int(cells)
    part = int((cells - full) * 8)
    s = "█" * full
    if full < w:
        s += PARTIAL[part] if part else ""
        s += "░" * (w - len(s))
    return s[:w]


def thousands(n) -> str:
    return f"{int(n):,}"


# ---------------------------------------------------------------------------
# composition
# ---------------------------------------------------------------------------
Span = tuple  # (text, style)


def _row(*spans: Span, cols: int) -> list[Span]:
    """Clip a row of spans to exactly `cols` cells."""
    out: list[Span] = []
    used = 0
    for text, style in spans:
        if used >= cols:
            break
        w = width(text)
        if used + w > cols:
            text = fit(text, cols - used, pad=False)
            w = width(text)
        out.append((text, style))
        used += w
    if used < cols:
        out.append((" " * (cols - used), "plain"))
    return out


def _section(title: str, right: str, cols: int) -> list[Span]:
    left = f" {title} "
    right = f" {right} " if right else ""
    mid = cols - width(left) - width(right)
    return _row((left, "hdr"), ("─" * max(0, mid), "rule"), (right, "dim"), cols=cols)


def allocate(rows: int, slots: int) -> dict[str, int]:
    """Row budget per section for this terminal height (always sums to `rows`)."""
    spec = [("header", 1, 1), ("overall", 3, 3), ("phases", 3, 7), ("workers", 2, 1 + max(1, min(slots, 8))),
            ("issues", 1, 3), ("queue", 2, None), ("footer", 1, 1)]
    h = {n: mn for n, mn, _ in spec}
    extra = rows - sum(h.values())
    for name, mn, want in spec:
        if want is None or extra <= 0:
            continue
        grow = min(extra, want - mn)
        h[name] += grow
        extra -= grow
    h["queue"] += max(0, extra)
    return h


def compose(snap: dict, rows: int, cols: int, now: float, *, q_offset: int = 0, spin: int = 0,
            log_dir: str = "", ascii_only: bool = False, mbps: float | None = None) -> list[list[Span]]:
    if rows < MIN_ROWS or cols < MIN_COLS:
        msg = f"Terminal too small: need {MIN_COLS}x{MIN_ROWS}, have {cols}x{rows}"
        out = [_row((fit(msg, cols, pad=False), "warn"), cols=cols)]
        return out + [_row(cols=cols) for _ in range(rows - 1)]
    h = allocate(rows, snap["slots"])
    out: list[list[Span]] = []
    out += _header(snap, cols, now, spin)
    out += _overall(snap, cols, now, mbps, ascii_only)
    out += _phases(snap, h["phases"], cols, spin, ascii_only)
    out += _workers(snap, h["workers"], cols, spin, ascii_only)
    out += _issues(snap, h["issues"], cols)
    out += _queue(snap, h["queue"], cols, q_offset)
    out += _footer(snap, cols, log_dir)
    assert len(out) == rows, (len(out), rows, h)
    return out


def _state_label(snap) -> tuple[str, str]:
    s = snap["state"]
    if snap["paused"]:
        return "❚❚ PAUSED", "warn"
    return {"running": ("● RUNNING", "ok"), "starting": ("◌ STARTING", "dim"), "finishing": ("◌ STOPPING…", "warn"),
            "done": ("✔ DONE", "ok"), "stopped": ("■ STOPPED", "warn"), "failed": ("✖ FAILED", "err")}.get(s, (s, "dim"))


def _header(snap, cols, now, spin):
    label, style = _state_label(snap)
    ov = snap["overall"]
    clock = time.strftime("%H:%M:%S", time.localtime(now))
    parts = [(" MYMEDIA SYNC ", "title"), (f" {label} ", style),
             (f"  elapsed {human_duration(ov['elapsed'])}", "plain")]
    if snap["state"] in ("running", "starting") and ov["eta"] is not None:
        parts.append((f"   ETA {'~' if ov.get('eta_approx') else ''}{human_duration(ov['eta'])}", "bold"))
    right = f" {clock} "
    left_w = sum(width(t) for t, _ in parts)
    pad = max(1, cols - left_w - width(right))
    return [_row(*parts, (" " * pad, "plain"), (right, "dim"), cols=cols)]


def _overall(snap, cols, now, mbps, ascii_only):
    ov = snap["overall"]
    pct = ov["pct"]
    cnt = f"{thousands(ov['done'])} / {thousands(ov['total'])} files"
    title = " OVERALL  UNSORTED → DESKTOP → PORTABLE"
    r1 = _row((title, "hdr"), (" " * max(1, cols - width(title) - width(cnt) - width(f"  {pct:3.0f}% ") - 1), "hdr"),
              (cnt, "bold"), (f"  {pct:3.0f}% ", "accent"), cols=cols)
    r2 = _row((" ", "plain"), (bar(pct / 100.0, cols - 2, ascii_only), "bar"), (" ", "plain"), cols=cols)
    eta = ov["eta"]
    rate = _current_rate(snap)
    bits = []
    if rate:
        bits.append(f"{rate * 3600:,.0f} files/h")
    if mbps:
        bits.append(f"{mbps:.1f} MB/s")
    if eta is not None and snap["state"] in ("running", "starting"):
        approx = "~" if ov.get("eta_approx") else ""
        bits.append(f"ETA {approx}{human_duration(eta)}  (done ≈ {time.strftime('%a %H:%M', time.localtime(now + eta))})"
                    + ("  · estimate improves as work is measured" if approx else ""))
    elif snap["state"] == "done":
        bits.append("finished")
    r3 = _row((" " + "  ·  ".join(bits), "dim"), cols=cols)
    return [r1, r2, r3]


def _current_rate(snap):
    for p in snap["phases"]:
        if p[0] == snap["current"] and p[7]:
            return p[7]
    return None


def _phases(snap, h, cols, spin, ascii_only):
    rows = [_section("PHASES", "", cols)]
    order = {p[0]: p for p in snap["phases"]}
    seq = [order[k] for k in PHASE_ORDER if k in order]
    cur = next((i for i, p in enumerate(seq) if p[0] == snap["current"]), 0)
    want = h - 1
    start = 0 if want >= len(seq) else max(0, min(cur - 1, len(seq) - want))
    for p in seq[start:start + want]:
        rows.append(_phase_row(p, cols, spin, ascii_only))
    while len(rows) < h:
        rows.append(_row(cols=cols))
    return rows


def _phase_row(p, cols, spin, ascii_only):
    key, label, state, total, done, failed, skipped, rate, eta, detail, active = p
    no = PHASE_NO[key]
    if state == "done":
        icon, st = "✔", "ok"
    elif state == "running":
        icon, st = SPINNER[spin % len(SPINNER)], "accent"
    elif state == "skipped":
        icon, st = "⊘", "dim"
    else:
        icon, st = "·", "dim"
    name = f" {icon} {no} {label:<14}"
    completed = min(total, done + failed + skipped)
    if key in ("scan", "finalize"):
        if state == "running":
            frac = (completed / total) if total > 1 else None
            right = f"{thousands(completed)}/{thousands(total)}" if total > 1 else ""
            body_w = max(6, cols - width(name) - width(right) - 3)
            return _row((name, st), (bar(frac, body_w, ascii_only, spin), "bar"), (f" {right}", "bold"), cols=cols)
        text = _truncate(detail, cols - width(name) - 10) if state != "pending" else ""
        t = f"  {human_duration(active)}" if state == "done" else ""
        return _row((name, st), (text, "dim"), (t, "dim"), cols=cols)
    if state == "pending" and total == 0:
        return _row((name, st), ("nothing to do", "dim"), cols=cols)
    if state == "skipped":
        return _row((name, st), ("nothing to do — confirmed complete", "dim"), cols=cols)
    cnt = f"{thousands(completed)}/{thousands(total)}"
    extra = ""
    if failed:
        extra = f"  ✖{failed}"
    pct = f"{(100 * completed // total) if total else 100:3d}%"
    tail = ""
    if state == "running":
        if rate:
            tail = f"  {rate * 3600:,.0f}/h"
        if eta is not None:
            tail += f"  ETA {human_duration(eta)}"
    elif state == "done":
        tail = f"  {human_duration(active)}"
    fixed = width(name) + width(cnt) + width(pct) + width(extra) + width(tail) + 4
    body_w = max(4, min(40, cols - fixed))
    frac = (completed / total) if total else 1.0
    return _row((name, st), (bar(frac, body_w, ascii_only), "bar"), (f" {pct} ", "accent"), (cnt, "bold"),
                (extra, "err"), (tail, "dim"), cols=cols)


def _truncate(s: str, w: int) -> str:
    return fit(s, max(0, w), pad=False)


def _workers(snap, h, cols, spin, ascii_only):
    act = snap["active"]
    title = f"NOW — {len(act)} active"
    rows = [_section(title, f"{snap.get('workers_now') or snap['slots']} workers", cols)]
    slots = h - 1
    show = act[:slots]
    more = len(act) - len(show)
    for i in range(slots):
        if i < len(show):
            rows.append(_worker_row(show[i], cols, spin, ascii_only, more if i == slots - 1 else 0))
        else:
            rows.append(_row(("   · idle", "dim"), cols=cols))
    return rows


def _worker_row(t, cols, spin, ascii_only, more):
    tag = KIND_TAG.get(t["kind"], "FIL")
    step = fit(t["step"] or t["phase"], 17)
    el = human_duration(t["elapsed"])
    pct = t["pct"]
    wide = cols >= 100
    barw = 14 if cols >= 80 else 0
    right_w = (barw + 1 if barw else 0) + 5 + 7 + (8 if wide else 0)
    name_w = max(8, cols - 3 - 4 - 18 - right_w - 2)
    name = fit(t["name"], name_w)
    parts = [(" ", "plain"), (SPINNER[(spin + len(t["name"])) % len(SPINNER)], "accent"), (f" {tag} ", "dim"),
             (name, "bold"), (" ", "plain"), (step, "plain")]
    if barw:
        parts += [(bar(None if pct is None else pct / 100.0, barw, ascii_only, spin), "bar"), (" ", "plain")]
    parts += [(fit(f"{pct:3.0f}%" if pct is not None else "", 5), "accent"), (fit(el, 7), "dim")]
    if wide:
        parts.append((fit(t["speed"], 8), "dim"))
    if more:
        parts.append((f" +{more}", "warn"))
    return _row(*parts, cols=cols)


def _issues(snap, h, cols):
    right = ""
    rows = [_section("ISSUES", right, cols)]
    summary = f" ⚠ {snap['warnings']} warnings   ✖ {snap['errors']} errors   ⇄ {snap['collisions']} name collisions (never overwritten)"
    st = "err" if snap["errors"] else ("warn" if snap["warnings"] else "ok")
    rows[0] = _row((" ISSUES ", "hdr"), (summary, st), cols=cols)
    recent = snap.get("recent", [])
    for i in range(h - 1):
        if i < len(recent):
            ts, level, phase, msg, f = recent[-(i + 1)]
            base = os.path.basename(f) if f else ""
            line = f"  {time.strftime('%H:%M:%S', time.localtime(ts))} {level[:4]} [{phase}] {msg}" + (f"  ({base})" if base else "")
            rows.append(_row((fit(line, cols, pad=False), "err" if level == "ERROR" else "warn"), cols=cols))
        else:
            rows.append(_row(cols=cols))
    return rows


def _queue(snap, h, cols, offset):
    finished = snap["state"] in ("done", "stopped", "failed")
    if finished:
        rows = [_row((" RESULT ", "hdr"), ("─" * (cols - 8), "rule"), cols=cols)]
        lines = snap["summary"] or [snap["message"] or snap["state"]]
        for ln in lines[: h - 1]:
            st = "ok" if "CONFIRMED" in ln else "plain"
            rows.append(_row(("  " + ln, st), cols=cols))
        while len(rows) < h:
            rows.append(_row(cols=cols))
        return rows
    q = snap["queue"]
    qlen = snap["queue_len"]
    if not q:
        rows = [_row((" WORKING ", "hdr"), ("─" * (cols - 9), "rule"), cols=cols)]
        rows.append(_row(("  " + (snap["message"] or "…"), "accent"), cols=cols))
        while len(rows) < h:
            rows.append(_row(cols=cols))
        return rows
    visible = h - 1
    off = max(0, min(offset, max(0, len(q) - visible)))
    follow = "following the queue" if off == 0 else f"scrolled +{off}"
    title = f" UP NEXT — {thousands(qlen)} waiting "
    hint = f" ↑↓ PgUp/PgDn scroll · End = follow ({follow}) "
    rows = [_row((title, "hdr"), ("─" * max(0, cols - width(title) - width(hint)), "rule"), (hint, "dim"), cols=cols)]
    for i in range(visible):
        idx = off + i
        if idx >= len(q):
            rows.append(_row(cols=cols))
            continue
        name, phase, kind, size = q[idx]
        sz = human_bytes(size) if size else ""
        left = f" {idx + 1:>6}  {phase:<8} {KIND_TAG.get(kind, 'FIL')}  "
        name_w = max(8, cols - width(left) - 11)
        rows.append(_row((left, "dim"), (fit(name, name_w), "plain"), (f"{sz:>10}", "dim"), cols=cols))
    return rows


def _footer(snap, cols, log_dir):
    keys = " q quit   p pause/resume   ↑↓ PgUp PgDn End  scroll queue "
    right = f" logs: {log_dir} " if log_dir else ""
    mid = max(0, cols - width(keys) - width(right))
    return [_row((keys, "foot"), (" " * mid, "foot"), (fit(right, min(width(right), cols - width(keys)), pad=False), "foot"),
                 cols=cols)]


# ---------------------------------------------------------------------------
# curses layer
# ---------------------------------------------------------------------------
def _styles(use_color: bool) -> dict:
    d = {k: 0 for k in ("plain", "dim", "bold", "ok", "warn", "err", "accent", "title", "hdr", "rule", "bar", "foot")}
    d["bold"] = curses.A_BOLD
    d["dim"] = curses.A_DIM
    d["hdr"] = curses.A_REVERSE
    d["foot"] = curses.A_REVERSE
    d["title"] = curses.A_BOLD | curses.A_REVERSE
    if use_color:
        pairs = {"ok": curses.COLOR_GREEN, "warn": curses.COLOR_YELLOW, "err": curses.COLOR_RED,
                 "accent": curses.COLOR_CYAN, "bar": curses.COLOR_GREEN, "rule": curses.COLOR_BLUE}
        for i, (name, col) in enumerate(pairs.items(), start=1):
            curses.init_pair(i, col, -1)
            d[name] = curses.color_pair(i) | (curses.A_BOLD if name in ("ok", "err", "accent") else 0)
        curses.init_pair(10, curses.COLOR_WHITE, curses.COLOR_BLUE)
        d["hdr"] = curses.color_pair(10) | curses.A_BOLD
        d["title"] = curses.color_pair(10) | curses.A_BOLD
        curses.init_pair(11, curses.COLOR_BLACK, curses.COLOR_WHITE)
        d["foot"] = curses.color_pair(11)
    return d


def run_tui(status, log, thread, stop, request_stop) -> None:
    locale.setlocale(locale.LC_ALL, "")
    ascii_only = "UTF" not in (locale.getpreferredencoding(False) or "").upper()

    def main(stdscr):
        try:
            curses.curs_set(0)
        except curses.error:
            pass
        use_color = False
        try:
            curses.start_color()
            curses.use_default_colors()
            use_color = curses.has_colors()
        except curses.error:
            pass
        styles = _styles(use_color)
        stdscr.timeout(200)
        stdscr.keypad(True)
        q_off = 0
        last_bytes = (time.time(), 0)
        mbps = None
        quit_count = 0
        while True:
            now = time.time()
            snap = status.snapshot()
            snap["recent"] = list(log.recent_issues)[-6:]
            if now - last_bytes[0] >= 2:
                b = snap_bytes(status)
                mbps = max(0.0, (b - last_bytes[1]) / 1048576 / (now - last_bytes[0])) or None
                last_bytes = (now, b)
            rows, cols = stdscr.getmaxyx()
            frame = compose(snap, rows, cols, now, q_offset=q_off, spin=int(now * 8), log_dir=str(log.dir),
                            ascii_only=ascii_only, mbps=mbps if snap["current"] == "ingest" else None)
            stdscr.erase()
            for y, spans in enumerate(frame):
                x = 0
                for text, style in spans:
                    try:
                        stdscr.addstr(y, x, text, styles.get(style, 0))
                    except curses.error:
                        pass          # writing the very last cell raises; harmless
                    x += width(text)
            stdscr.refresh()
            key = stdscr.getch()
            if key in (ord("q"), ord("Q")):
                quit_count += 1
                if thread.is_alive():
                    request_stop()
                    status.message = "Stopping: finishing the files being processed (press q again to quit at once)…"
                    if quit_count >= 2:
                        return
                else:
                    return
            elif key in (ord("p"), ord("P")):
                status.paused = not status.paused
            elif key == curses.KEY_DOWN:
                q_off += 1
            elif key == curses.KEY_UP:
                q_off = max(0, q_off - 1)
            elif key == curses.KEY_NPAGE:
                q_off += max(1, rows - 12)
            elif key == curses.KEY_PPAGE:
                q_off = max(0, q_off - max(1, rows - 12))
            elif key in (curses.KEY_END, ord("G")):
                q_off = 0
            elif key == curses.KEY_HOME:
                q_off = 0
            if not thread.is_alive() and snap["state"] in ("done", "stopped", "failed"):
                pass                      # keep the result on screen until the user presses q

    curses.wrapper(main)


def snap_bytes(status) -> int:
    with status.lock:
        return status.bytes_done
