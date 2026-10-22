#!/usr/bin/env bash
# brokencheck.sh — list damaged OUTPUT files under a library root.
#
# Usage:  brokencheck.sh <root> [stampFile]
#
# Prints (one per line) every file under <root> that is
#   * empty (0 bytes), or
#   * a JPEG with no end-of-image marker near its end (truncated), or
#   * an .m4v that ffprobe cannot read.
# Callers treat these as MISSING: they delete them and rebuild from the source
# (desktop photos from the camera library, portable from desktop).
#
# With a stampFile only files newer than the last COMPLETE scan are checked, so a
# normal sync does not re-read the whole library; SYNC_VERIFY=1 forces a full scan.
# The stamp is only advanced after a scan that ran to the end.
#
# This script only READS and prints; it never deletes anything.

set -uo pipefail

ROOT="${1:?usage: brokencheck.sh <root> [stampFile]}"
STAMP="${2:-}"
[[ -d "$ROOT" ]] || exit 0

newer=()
if [[ -n "$STAMP" && -f "$STAMP" && "${SYNC_VERIFY:-0}" != "1" ]]; then
    newer=( -newer "$STAMP" )
fi

# Marker taken BEFORE the scan: files written while we scan are re-checked next time.
mark="$(mktemp /tmp/brokencheck_XXXXXX)"
trap 'rm -f "$mark"' EXIT

# 1) empty files (hidden temp files are ignored)
find "$ROOT" -type f ${newer[@]+"${newer[@]}"} -size 0 ! -name '.*' -print 2>/dev/null

# 2) JPEGs whose last 64 bytes contain no FFD9 end-of-image marker.
#    One process reads all the file endings (8 threads); the per-file shell
#    fallback below is only used when python3 is not available.
if command -v python3 >/dev/null 2>&1; then
    find "$ROOT" -type f ${newer[@]+"${newer[@]}"} -size +0 \( -iname '*.jpg' -o -iname '*.jpeg' \) ! -name '.*' -print0 2>/dev/null \
      | python3 -c '
import sys
from concurrent.futures import ThreadPoolExecutor
def damaged(p):
    try:
        with open(p, "rb") as f:
            f.seek(0, 2)
            f.seek(max(0, f.tell() - 64))
            return b"\xff\xd9" not in f.read(64)
    except OSError:
        return True
paths = [p for p in sys.stdin.buffer.read().split(b"\0") if p]
with ThreadPoolExecutor(8) as ex:
    for p, bad in zip(paths, ex.map(damaged, paths)):
        if bad:
            sys.stdout.buffer.write(p + b"\n")
'
else
    find "$ROOT" -type f ${newer[@]+"${newer[@]}"} -size +0 \( -iname '*.jpg' -o -iname '*.jpeg' \) ! -name '.*' -print0 2>/dev/null \
      | xargs -0 -r -P 4 -n 40 bash -c '
            for f; do
                tail -c 64 "$f" 2>/dev/null | od -An -tx1 | tr -d " \n" | grep -q "ffd9" || printf "%s\n" "$f"
            done' _
fi

# 3) videos ffprobe cannot read (few files, so a real probe is affordable)
if command -v ffprobe >/dev/null 2>&1; then
    find "$ROOT" -type f ${newer[@]+"${newer[@]}"} -size +0 -iname '*.m4v' ! -name '.*' -print0 2>/dev/null \
      | xargs -0 -r -P 2 -n 10 bash -c '
            for f; do
                ffprobe -v error -show_entries format=duration -of default=nw=1 "$f" >/dev/null 2>&1 || printf "%s\n" "$f"
            done' _
fi

[[ -n "$STAMP" ]] && touch -r "$mark" "$STAMP" 2>/dev/null
exit 0
