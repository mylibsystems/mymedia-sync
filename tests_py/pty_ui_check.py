"""Run the real TUI in a pty, sample screens during the run, resize mid-run, check the layout."""
import fcntl, os, pty, select, signal, struct, sys, termios, time
import pyte

def main(settings, sizes, duration):
    rows, cols = sizes[0]
    screen = pyte.Screen(cols, rows); stream = pyte.ByteStream(screen)
    pid, fd = pty.fork()
    if pid == 0:
        os.environ.update(MEDIASYNC_SETTINGS=settings, TERM="xterm-256color", LANG="C.UTF-8", LC_ALL="C.UTF-8")
        os.execvp(sys.executable, [sys.executable, "-m", "mediasync"])
    def setsize(r, c):
        fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", r, c, 0, 0)); os.kill(pid, signal.SIGWINCH)
        screen.resize(r, c)
    setsize(rows, cols)
    t0 = time.time(); shots = []; marks = {}
    plan = list(sizes[1:]); next_resize = t0 + duration / (len(sizes))
    cur = (rows, cols); bad = []
    while time.time() - t0 < duration:
        r, _, _ = select.select([fd], [], [], 0.12)
        quiet = not r
        if r:
            try: data = os.read(fd, 65536)
            except OSError: break
            if not data: break
            stream.feed(data)
        if plan and time.time() >= next_resize:
            cur = plan.pop(0); setsize(*cur); next_resize = time.time() + duration / (len(sizes)); time.sleep(0.6)
        if not quiet:
            continue
        lines = screen.display
        txt = "\n".join(lines)
        if "MYMEDIA SYNC" in txt:
            # the header must be on the first row and the footer on the last row, always
            ok_head = "MYMEDIA SYNC" in lines[0]
            ok_foot = "q quit" in lines[-1]
            if not (ok_head and ok_foot) and time.time() - t0 > 2:
                bad.append((cur, round(time.time() - t0, 1), lines[0][:50], lines[-1][:50]))
            for m in ("OVERALL", "PHASES", "ISSUES"):
                row = next((i for i, l in enumerate(lines) if f" {m}" in l and "─" in l or l.lstrip().startswith(m)), None)
                marks.setdefault((cur, m), set()).add(row)
        if len(shots) < 4 and time.time() - t0 > 3 + len(shots) * (duration / 5):
            shots.append((cur, "\n".join(l.rstrip() for l in lines)))
    try: os.write(fd, b"q"); time.sleep(0.5); os.write(fd, b"q")
    except OSError: pass
    try: os.kill(pid, signal.SIGTERM)
    except OSError: pass
    print("header/footer misplaced frames:", len(bad), bad[:2])
    unstable = {k: v for k, v in marks.items() if len(v - {None}) > 1}
    print("section rows unstable (within one terminal size):", unstable or "none")
    print("section rows per size:", {f"{k[0][1]}x{k[0][0]} {k[1]}": sorted(x for x in v if x is not None) for k, v in sorted(marks.items())})
    for size, s in shots[:2]:
        print(f"\n===== screenshot at {size[1]}x{size[0]} =====\n{s}")

if __name__ == "__main__":
    sizes = [(30, 110), (24, 80), (40, 140), (18, 70), (30, 110)]
    main(sys.argv[1], sizes, float(sys.argv[2]))
