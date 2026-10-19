#!/usr/bin/env bash
# syncui.sh — live terminal dashboard for the media sync pipeline.
#
# Two modes:
#   Wrapper:  ./syncui.sh [camera downloads music movies tv photos | all]
#               starts ./sync.sh with those stages, then visualizes it live.
#   Attach:   ./syncui.sh            (or: ./syncui.sh attach)
#               visualizes whatever sync / portable-remake is already running.
#
# Shows: the item being processed right now (with a live progress bar), the
# current group's episode/track progress, per-category library bars, and the
# pending queue. Auto-refreshes; press q to quit (the sync keeps running).
#
# Env: SYNC_UI_REFRESH (seconds between frames, default 2)
#      SYNC_UI_COUNT_TTL (seconds between library re-counts, default 20)

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/config.sh" >/dev/null 2>&1 || true

REFRESH="${SYNC_UI_REFRESH:-2}"
COUNT_TTL="${SYNC_UI_COUNT_TTL:-20}"
FFPROBE_BIN="${SCRIPT_DIR}/.ffmpeg/bin/ffprobe"

# ---- palette ---------------------------------------------------------------
ESC=$'\033'; RST="${ESC}[0m"; B="${ESC}[1m"; DIM="${ESC}[2m"
C_TITLE="${ESC}[38;5;51m"; C_OK="${ESC}[38;5;46m"; C_WARN="${ESC}[38;5;220m"
C_MUSIC="${ESC}[38;5;213m"; C_MOV="${ESC}[38;5;39m"; C_TV="${ESC}[38;5;208m"
C_PH="${ESC}[38;5;120m"; C_NOW="${ESC}[38;5;226m"; C_LINE="${ESC}[38;5;240m"
C_BARBG="${ESC}[38;5;236m"
SPIN='⣾⣽⣻⢿⡿⣟⣯⣷'

# ---- mode selection --------------------------------------------------------
SYNC_PID=""
LOG=""
UI_THRESHOLD=0
arg1="${1:-attach}"
case "$(echo "$arg1" | tr '[:upper:]' '[:lower:]')" in
    attach|watch|"") MODE="attach" ;;
    camera|downloads|music|movies|tv|photos|all) MODE="wrapper" ;;
    *) MODE="attach" ;;
esac

pick_log() {
    local f cands=()
    for f in "${SCRIPT_DIR}"/logs/sync-*.log "${SCRIPT_DIR}"/logs/sync-ui-*.log /var/tmp/remake_portables.log; do
        [[ -f "$f" ]] && cands+=("$f")
    done
    [[ ${#cands[@]} -eq 0 ]] && return 0
    ls -1t "${cands[@]}" 2>/dev/null | head -1
}

if [[ "$MODE" == "wrapper" ]]; then
    mkdir -p "${SCRIPT_DIR}/logs"
    LOG="${SCRIPT_DIR}/logs/sync-ui-$(date +%Y%m%d-%H%M%S).log"
    UI_THRESHOLD=$(date +%s)
    _stages=( "$@" ); [[ "${_stages[0]:-}" == "all" ]] && _stages=()
    # ffmpeg's stderr progress is unbuffered, so live time= reaches the file
    # even without a pty; disable sync's own auto-tee to keep one clean log.
    SYNC_AUTOTEE=0 nohup "${SCRIPT_DIR}/sync.sh" "${_stages[@]}" >"$LOG" 2>&1 &
    SYNC_PID=$!
else
    LOG="$(pick_log)"
    if [[ -n "$LOG" ]]; then
        _sl=$(grep -m1 'remake started' "$LOG" 2>/dev/null | grep -oE '[0-9T:+-]{20,}')
        [[ -n "$_sl" ]] && UI_THRESHOLD=$(date -d "$_sl" +%s 2>/dev/null || echo 0)
    fi
fi

# ---- helpers ---------------------------------------------------------------
hms_to_s() { awk -F: '{s=0; for(i=1;i<=NF;i++) s=s*60+$i; printf "%d", s}' <<<"${1:-0}"; }

roots_for() {
    case "$1" in
        MUSIC)  DROOT="$DESKTOP_MUSIC_ROOT";  PROOT="$PORTABLE_MUSIC_ROOT";  DGLOB='*.flac'; PGLOB='*.m4a'; ICON='🎵'; COL="$C_MUSIC" ;;
        MOVIES) DROOT="$DESKTOP_MOVIES_ROOT"; PROOT="$PORTABLE_MOVIES_ROOT"; DGLOB='*.m4v';  PGLOB='*.m4v'; ICON='🎬'; COL="$C_MOV" ;;
        TV)     DROOT="$DESKTOP_TV_ROOT";     PROOT="$PORTABLE_TV_ROOT";     DGLOB='*.m4v';  PGLOB='*.m4v'; ICON='📺'; COL="$C_TV" ;;
        PHOTOS) DROOT="$DESKTOP_PHOTOS_ROOT"; PROOT="$PORTABLE_PHOTOS_ROOT"; DGLOB='*.jpg';  PGLOB='*.jpg'; ICON='🖼'; COL="$C_PH" ;;
    esac
}
CATS=(MUSIC MOVIES TV PHOTOS)

bar() { # done total width color
    local d=$1 t=$2 w=$3 col=$4 fill=0 i s=""
    (( t > 0 )) && fill=$(( d * w / t )); (( fill > w )) && fill=$w
    for ((i=0;i<fill;i++)); do s+="█"; done
    printf '%s%s%s%s' "$col" "$s" "$C_BARBG"
    s=""; for ((i=fill;i<w;i++)); do s+="░"; done
    printf '%s%s' "$s" "$RST"
}
pct() { local d=$1 t=$2; (( t > 0 )) && echo $(( d*100/t )) || echo 0; }

# current processing state (parsed from LOG + live process table)
cur_file=""; cur_cat=""; cur_group=""; cur_pct=0; cur_tpos=""; cur_tdur=""
read_now() {
    local running=0
    pgrep -f '[f]fmpeg' >/dev/null 2>&1 && running=1
    NOW_RUNNING=$running
    [[ -f "$LOG" ]] || { cur_file=""; return; }
    # ffmpeg closes the source path with ': — match to that so apostrophes in
    # filenames (e.g. "New Year's Eve") don't truncate the path.
    cur_file=$(grep -aoE "Input #0.*from '.+':" "$LOG" 2>/dev/null | tail -1 | sed -E "s/.*from '(.+)':.*/\1/")
    [[ -z "$cur_file" ]] && return
    case "$cur_file" in
        */MOVIES/*) cur_cat=MOVIES ;; */TV/*) cur_cat=TV ;;
        */MUSIC/*) cur_cat=MUSIC ;; */PHOTOS/*|*/CAMERA/*) cur_cat=PHOTOS ;;
        *) cur_cat="" ;;
    esac
    cur_group=""
    [[ -n "$cur_cat" ]] && cur_group=$(sed -E "s#.*/$cur_cat/([^/]+)/.*#\1#" <<<"$cur_file")
    local dur pos
    dur=$(grep -a 'Duration:' "$LOG" 2>/dev/null | tail -1 | sed -E 's/.*Duration: ([0-9:.]+).*/\1/')
    pos=$(tr '\r' '\n' < "$LOG" 2>/dev/null | grep -aoE 'time=[0-9:.]+' | tail -1 | cut -d= -f2)
    cur_tdur="$dur"; cur_tpos="$pos"
    local ds ps; ds=$(hms_to_s "${dur:-0}"); ps=$(hms_to_s "${pos:-0}")
    (( ds > 0 )) && cur_pct=$(( ps*100/ds )) || cur_pct=0
    (( cur_pct > 100 )) && cur_pct=100
}

# cached library counts + pending (computed by a background producer so slow
# SMB scans never block the render loop)
declare -A DONE TOT
PEND_LINES=(); _last_count_ts=0; _last_cat=""
PEND_OFFSET=0; MANUAL_UNTIL=0
COUNTS_READY=0; _counter_pid=""; _results_mtime=0
RESULT_FILE="$(mktemp -t syncui.res.XXXXXX 2>/dev/null || echo /tmp/syncui.res.$$)"
RESULT_TMP="${RESULT_FILE}.tmp"

# Runs in the background; discovers counts + the current category's pending queue
# incrementally, republishing an atomic snapshot after each step so the UI fills
# in from 0 as results arrive (fast categories first, slow SMB scans last).
spawn_counter() {
    local ccat="$1" cgroup="$2"
    local snap="" pend="PEND_LINES=()" c t d g gp dc pc name
    _publish() { { printf '%s' "$snap"; printf '%s\n' "$pend"; } > "$RESULT_TMP" 2>/dev/null \
                 && mv -f "$RESULT_TMP" "$RESULT_FILE" 2>/dev/null; }
    # current category's pending queue first (most relevant, usually cheap)
    if [[ -n "$ccat" ]]; then
        roots_for "$ccat"; pend="PEND_LINES=("
        while IFS= read -r g; do
            [[ -z "$g" ]] && continue
            name=$(basename "$g"); gp="${g/LIBRARY.DESKTOP/LIBRARY.PORTABLE}"
            dc=$(find "$g"  -type f -iname "$DGLOB" 2>/dev/null | wc -l | tr -d ' ')
            pc=$(find "$gp" -type f -iname "$PGLOB" -newermt "@$UI_THRESHOLD" 2>/dev/null | wc -l | tr -d ' ')
            (( dc > 0 && pc >= dc )) && continue
            [[ "$name" == "$cgroup" ]] && continue
            pend+=" $(printf '%q' "$name|$pc|$dc")"
        done < <(find "$DROOT" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort)
        pend+=" )"; _publish
    fi
    # category counts, current category first, publishing after each
    local order=(); [[ -n "$ccat" ]] && order+=("$ccat")
    for c in "${CATS[@]}"; do [[ "$c" == "$ccat" ]] || order+=("$c"); done
    for c in "${order[@]}"; do
        roots_for "$c"
        t=$(find "$DROOT" -type f -iname "$DGLOB" 2>/dev/null | wc -l | tr -d ' ')
        d=$(find "$PROOT" -type f -iname "$PGLOB" -newermt "@$UI_THRESHOLD" 2>/dev/null | wc -l | tr -d ' ')
        snap+="TOT[$c]=$t"$'\n'"DONE[$c]=$d"$'\n'
        _publish
    done
}
maybe_refresh_counts() {
    local now; now=$(date +%s)
    # publish finished results
    if [[ -s "$RESULT_FILE" ]]; then
        local m; m=$(stat -c %Y "$RESULT_FILE" 2>/dev/null || echo 0)
        if (( m > _results_mtime )); then
            # shellcheck disable=SC1090
            source "$RESULT_FILE" 2>/dev/null && { COUNTS_READY=1; _results_mtime=$m; }
        fi
    fi
    # (re)spawn producer when idle and results are stale / category changed
    if [[ -z "$_counter_pid" ]] || ! kill -0 "$_counter_pid" 2>/dev/null; then
        if (( COUNTS_READY == 0 )) || (( now - _last_count_ts >= COUNT_TTL )) || [[ "$cur_cat" != "$_last_cat" ]]; then
            spawn_counter "$cur_cat" "$cur_group" </dev/null >/dev/null 2>&1 &
            _counter_pid=$!; _last_count_ts=$now; _last_cat="$cur_cat"
        fi
    fi
}

# ---- rendering -------------------------------------------------------------
FRAME=0
cleanup() {
    [[ -n "$_counter_pid" ]] && kill "$_counter_pid" 2>/dev/null
    rm -f "$RESULT_FILE" "$RESULT_TMP" 2>/dev/null
    printf '%s[?25h%s[?1049l' "$ESC" "$ESC"
}
trap cleanup EXIT INT TERM
printf '%s[?1049h%s[?25l' "$ESC" "$ESC"   # alt screen + hide cursor

draw() {
    # tput cols/lines are unreliable inside $() (stdout is a pipe → defaults to
    # 80x24); read the true size straight from the controlling tty instead.
    local cols lines sz
    sz=$(stty size 2>/dev/null </dev/tty) || sz=""
    if [[ "$sz" =~ ^([0-9]+)[[:space:]]+([0-9]+)$ ]]; then
        lines=${BASH_REMATCH[1]}; cols=${BASH_REMATCH[2]}
    else
        cols=$(tput cols 2>/dev/null || echo 80); lines=$(tput lines 2>/dev/null || echo 24)
    fi
    (( cols < 40 )) && cols=40; (( lines < 16 )) && lines=16
    local bw=$(( cols - 34 )); (( bw < 10 )) && bw=10       # library / overall bars
    local bwn=$(( cols - 46 )); (( bwn < 10 )) && bwn=10    # NOW bar (leaves room for times)
    local sp="${SPIN:$(( FRAME % ${#SPIN} )):1}"
    local rule; rule=$(printf '─%.0s' $(seq 1 $(( cols - 2 )) ))
    local status="running"; [[ "$NOW_RUNNING" == "0" ]] && status="idle"
    [[ -n "$SYNC_PID" ]] && { kill -0 "$SYNC_PID" 2>/dev/null || status="finished"; }

    printf '%s[H' "$ESC"   # home
    printf '%s%s ⟳ MYMEDIA SYNC %s%s%s   %s%s %s  %s%s\n' \
        "$B" "$C_TITLE" "$RST" "$DIM" "$C_LINE" "$C_NOW" "$sp" "$status" \
        "$(date '+%H:%M:%S')" "$RST"
    printf '%s%s%s\n' "$C_LINE" "$rule" "$RST"

    # NOW panel
    if [[ -n "$cur_file" ]]; then
        local icon="•" ccol="$RST"
        [[ -n "$cur_cat" ]] && { roots_for "$cur_cat"; icon="$ICON"; ccol="$COL"; }
        local nlabel="NOW"; [[ "$NOW_RUNNING" == "0" ]] && nlabel="LAST"
        printf ' %s%s▶ %s%s   %s%s %s%s\n' "$B" "$C_NOW" "$nlabel" "$RST" "$ccol" "$icon" "${cur_cat:-?}" "$RST"
        printf '   %s%.*s%s\n' "$B" $(( cols - 4 )) "${cur_group:-$(basename "$cur_file")}" "$RST"
        printf '   %s%.*s%s\n' "$DIM" $(( cols - 4 )) "$(basename "$cur_file")" "$RST"
        printf '   %s  %s%3s%%%s   %s%s / %s%s\n' \
            "$(bar "$cur_pct" 100 "$bwn" "$C_NOW")" "$C_NOW" "$cur_pct" "$RST" \
            "$DIM" "${cur_tpos:-–}" "${cur_tdur:-–}" "$RST"
    else
        printf ' %s(waiting for an item to start…)%s\n\n\n\n' "$DIM" "$RST"
    fi
    printf '%s%s%s\n' "$C_LINE" "$rule" "$RST"

    # library bars
    printf ' %sLIBRARY%s  %s(portable rebuilt ← desktop)%s\n' "$B" "$RST" "$DIM" "$RST"
    local c d t p inscope
    for c in "${CATS[@]}"; do
        roots_for "$c"; d="${DONE[$c]:-0}"; t="${TOT[$c]:-0}"; p=$(pct "$d" "$t")
        if (( d > 0 )) || [[ "$c" == "$cur_cat" ]]; then
            printf '   %s%s %-7s%s %s  %s%4s/%-5s%s %s%3s%%%s\n' \
                "$COL" "$ICON" "$c" "$RST" "$(bar "$d" "$t" "$bw" "$COL")" \
                "$B" "$d" "$t" "$RST" "$DIM" "$p" "$RST"
        else
            printf '   %s%s %-7s %s  %5s   · waiting%s\n' \
                "$DIM" "$ICON" "$c" "$(bar 0 "$t" "$bw" "$C_BARBG")" "$t" "$RST"
        fi
    done
    printf '%s%s%s\n' "$C_LINE" "$rule" "$RST"

    # pending queue for the current category — fills remaining screen height,
    # auto-scrolls when it overflows (manual keys pause the auto-scroll).
    local total=${#PEND_LINES[@]}
    # rows consumed by everything except the pending item rows
    local overhead=16
    local avail=$(( lines - overhead )); (( avail < 3 )) && avail=3
    local maxoff=$(( total - avail )); (( maxoff < 0 )) && maxoff=0
    if (( total > avail )); then
        local nowk; nowk=$(date +%s)
        if (( nowk >= MANUAL_UNTIL )); then            # auto-scroll a line/frame
            PEND_OFFSET=$(( PEND_OFFSET + 1 ))
            (( PEND_OFFSET > maxoff )) && PEND_OFFSET=0
        fi
    else
        PEND_OFFSET=0
    fi
    (( PEND_OFFSET > maxoff )) && PEND_OFFSET=$maxoff
    (( PEND_OFFSET < 0 )) && PEND_OFFSET=0

    local phdr=""
    if (( total > avail )); then
        printf -v phdr '   %s%d–%d of %d  ↑↓/j k · space ⇟ · g top%s' \
            "$DIM" $(( PEND_OFFSET + 1 )) $(( PEND_OFFSET + avail )) "$total" "$RST"
    elif (( total > 0 )); then
        printf -v phdr '   %s%d total%s' "$DIM" "$total" "$RST"
    fi
    printf ' %s⏳ PENDING%s%s%s%s\n' "$B$C_WARN" "$RST" "$DIM" "${cur_cat:+ — $cur_cat}$RST" "$phdr"

    local shown_rows=0
    if (( total == 0 )); then
        printf '   %s%s%s\n' "$DIM" "${cur_cat:+nothing pending}" "$RST"; shown_rows=1
    else
        local i line name pc dc nw=$(( cols - 13 )); (( nw < 10 )) && nw=10
        for (( i = PEND_OFFSET; i < total && shown_rows < avail; i++ )); do
            line="${PEND_LINES[$i]}"
            IFS='|' read -r name pc dc <<<"$line"
            printf '   %s•%s %-*.*s %s%s%s/%s\n' \
                "$C_WARN" "$RST" "$nw" "$nw" "$name" "$B" "$pc" "$RST" "$dc"
            (( shown_rows++ ))
        done
    fi
    # pad so the OVERALL bar stays pinned to the bottom of the screen
    while (( shown_rows < avail )); do printf '\n'; (( shown_rows++ )); done
    printf '%s%s%s\n' "$C_LINE" "$rule" "$RST"

    # overall — only categories active or with progress this session
    local od=0 ot=0
    for c in "${CATS[@]}"; do
        if (( ${DONE[$c]:-0} > 0 )) || [[ "$c" == "$cur_cat" ]]; then
            od=$(( od + ${DONE[$c]:-0} )); ot=$(( ot + ${TOT[$c]:-0} ))
        fi
    done
    printf '%s[J' "$ESC"   # clear stale rows before drawing the bottom line
    printf ' %sOVERALL%s %s  %s%s/%s%s  %s·  q quit%s' \
        "$B" "$RST" "$(bar "$od" "$ot" "$bw" "$C_OK")" "$B" "$od" "$ot" "$RST" "$DIM" "$RST"
}

# ---- main loop -------------------------------------------------------------
while :; do
    read_now
    maybe_refresh_counts
    draw
    FRAME=$(( FRAME + 1 ))
    if [[ -n "$SYNC_PID" ]] && ! kill -0 "$SYNC_PID" 2>/dev/null; then
        UI_THRESHOLD="$UI_THRESHOLD"   # keep; final frame already drawn
    fi
    IFS= read -rsn1 -t "$REFRESH" key 2>/dev/null || true
    case "${key:-}" in
        q|Q) break ;;
        $'\033')                                   # arrow keys: ESC [ A/B
            IFS= read -rsn2 -t 0.001 seq 2>/dev/null || true
            case "$seq" in
                '[A') PEND_OFFSET=$(( PEND_OFFSET - 1 )); MANUAL_UNTIL=$(( $(date +%s) + 15 )) ;;
                '[B') PEND_OFFSET=$(( PEND_OFFSET + 1 )); MANUAL_UNTIL=$(( $(date +%s) + 15 )) ;;
                '[5') PEND_OFFSET=$(( PEND_OFFSET - 10 )); MANUAL_UNTIL=$(( $(date +%s) + 15 )) ;;
                '[6') PEND_OFFSET=$(( PEND_OFFSET + 10 )); MANUAL_UNTIL=$(( $(date +%s) + 15 )) ;;
            esac; seq="" ;;
        k)   PEND_OFFSET=$(( PEND_OFFSET - 1 )); MANUAL_UNTIL=$(( $(date +%s) + 15 )) ;;
        j)   PEND_OFFSET=$(( PEND_OFFSET + 1 )); MANUAL_UNTIL=$(( $(date +%s) + 15 )) ;;
        b)   PEND_OFFSET=$(( PEND_OFFSET - 10 )); MANUAL_UNTIL=$(( $(date +%s) + 15 )) ;;
        ' '|f) PEND_OFFSET=$(( PEND_OFFSET + 10 )); MANUAL_UNTIL=$(( $(date +%s) + 15 )) ;;
        g)   PEND_OFFSET=0; MANUAL_UNTIL=$(( $(date +%s) + 15 )) ;;
        a)   MANUAL_UNTIL=0 ;;                       # resume auto-scroll
    esac
    (( PEND_OFFSET < 0 )) && PEND_OFFSET=0
    key=""
done
