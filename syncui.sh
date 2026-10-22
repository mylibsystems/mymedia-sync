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
#
# INBOX panel: camera / photos / video / downloads progress, derived from the
# files left in UNSORTED (each source is removed right after it is imported).

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/config.sh" >/dev/null 2>&1 || true

REFRESH="${SYNC_UI_REFRESH:-2}"
COUNT_TTL="${SYNC_UI_COUNT_TTL:-20}"
BASE_FILE="${SCRIPT_DIR}/logs/.syncui-baseline"
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
    rm -f "$BASE_FILE"   # new run → fresh inbox baseline
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
    DGLOB2=''; [[ "$1" == PHOTOS ]] && DGLOB2='*.m4v'
}

# count_lib ROOT GLOB [GLOB2] [NEWER_THAN_EPOCH]
count_lib() {
    local root="$1" g1="$2" g2="${3:-}" nt="${4:-}" a=()
    a=( "$root" -type f )
    if [[ -n "$g2" ]]; then a+=( \( -iname "$g1" -o -iname "$g2" \) ); else a+=( -iname "$g1" ); fi
    [[ -n "$nt" ]] && a+=( -newermt "@$nt" )
    find "${a[@]}" 2>/dev/null | wc -l | tr -d ' '
}
CATS=(MUSIC MOVIES TV PHOTOS)

# Inbox sources whose files are deleted from UNSORTED once imported.
SRC_CATS=(CAMERA PHOTOS VIDEO DOWNLOADS)
src_for() {
    case "$1" in
        CAMERA)    SDIR="$CAMERA_SOURCE";    SICON='📷'; SCOL="$C_PH" ;;
        PHOTOS)    SDIR="$PHOTOS_SOURCE";    SICON='🖼'; SCOL="$C_PH" ;;
        VIDEO)     SDIR="$VIDEO_SOURCE";     SICON='🎞'; SCOL="$C_MOV" ;;
        DOWNLOADS) SDIR="$DOWNLOADS_SOURCE"; SICON='📥'; SCOL="$C_TV" ;;
    esac
}

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
    # CAMERA files map to PHOTOS but live outside /PHOTOS/ → fall back to the parent folder
    [[ -z "$cur_group" || "$cur_group" == "$cur_file" ]] && cur_group="$(basename "$(dirname "$cur_file")")"
    local dur pos
    dur=$(grep -a 'Duration:' "$LOG" 2>/dev/null | tail -1 | sed -E 's/.*Duration: ([0-9:.]+).*/\1/')
    pos=$(tr '\r' '\n' < "$LOG" 2>/dev/null | grep -aoE 'time=[0-9:.]+' | tail -1 | cut -d= -f2)
    cur_tdur="$dur"; cur_tpos="$pos"
    local ds ps; ds=$(hms_to_s "${dur:-0}"); ps=$(hms_to_s "${pos:-0}")
    (( ds > 0 )) && cur_pct=$(( ps*100/ds )) || cur_pct=0
    (( cur_pct > 100 )) && cur_pct=100
}

# Which source folder / library does a path belong to?
act_cat_of() {
    case "$1" in
        "$CAMERA_SOURCE"/*|"$DESKTOP_CAMERA_ROOT"/*) echo CAMERA ;;
        "$PHOTOS_SOURCE"/*|"$DESKTOP_PHOTOS_ROOT"/*) echo PHOTOS ;;
        "$VIDEO_SOURCE"/*)     echo VIDEO ;;
        "$DOWNLOADS_SOURCE"/*) echo DOWNLOADS ;;
        "$MUSIC_SOURCE"/*|"$DESKTOP_MUSIC_ROOT"/*)   echo MUSIC ;;
        "$MOVIES_SOURCE"/*|"$DESKTOP_MOVIES_ROOT"/*) echo MOVIES ;;
        "$TV_SOURCE"/*|"$DESKTOP_TV_ROOT"/*)         echo TV ;;
        *)                     echo "" ;;
    esac
}

# Files being processed RIGHT NOW, read from the process table (works for photos,
# RAW and camera files, which never write per-file progress to the log).
# Newest first; the step comes from what the file's job is currently running.
ACT_N=0; ACT_FILE=(); ACT_STEP=(); ACT_ET=(); ACT_CAT=()
read_active() {
    ACT_N=0; ACT_FILE=(); ACT_STEP=(); ACT_ET=(); ACT_CAT=()
    local -A par=() cm=() et=() isroot=() rootset=() rank=() lbl=() fileof=()
    local pid ppid e c p q a h r row
    local -a roots=() av=()
    while read -r pid ppid e c; do par[$pid]=$ppid; cm[$pid]=$c; et[$pid]=$e; done \
        < <(ps -eo pid=,ppid=,etimes=,comm= 2>/dev/null)
    while read -r p; do [[ -n "$p" ]] && isroot[$p]=1; done < <(pgrep -f '[o]rginize\.sh|[p]ortablize\.sh one' 2>/dev/null)
    for p in "${!isroot[@]}"; do
        [[ -n "${isroot[${par[$p]:-0}]:-}" ]] && continue          # forked subshell of another job
        av=(); mapfile -d '' -t av < "/proc/$p/cmdline" 2>/dev/null || continue
        local f="" i
        for i in "${!av[@]}"; do
            if [[ "${av[$i]}" == */orginize.sh || "${av[$i]}" == orginize.sh ]]; then f="${av[$((i+1))]:-}"; break; fi
            if [[ "${av[$i]}" == */portablize.sh || "${av[$i]}" == portablize.sh ]]; then
                [[ "${av[$((i+1))]:-}" == one ]] && f="${av[$((i+3))]:-}"; break
            fi
        done
        [[ -n "$f" ]] || continue
        roots+=("$p"); rootset[$p]=1; fileof[$p]="$f"
    done
    (( ${#roots[@]} > 0 )) || return 0
    for q in "${!par[@]}"; do
        a=$q; h=0; r=""
        case "${cm[$q]}" in
            ffmpeg)                          r=6; row="encoding" ;;
            magick|convert|mogrify|identify) r=6; row="converting image" ;;
            exiftool)                        r=5; row="metadata" ;;
            AtomicParsley|metaflac|flac)     r=5; row="tagging" ;;
            fpcalc)                          r=4; row="fingerprint" ;;
            curl|wget)                       r=4; row="online lookup" ;;
            cp|cmp|mv|dd)                    r=3; row="copying" ;;
            *) continue ;;
        esac
        while (( h < 8 )) && [[ -n "${par[$a]:-}" ]]; do
            a=${par[$a]}
            if [[ -n "${rootset[$a]:-}" ]]; then
                (( r > ${rank[$a]:-0} )) && { rank[$a]=$r; lbl[$a]="$row"; }
                break
            fi
            h=$(( h + 1 ))
        done
    done
    local sorted
    sorted=$(for p in "${roots[@]}"; do printf '%s %s\n' "${et[$p]:-0}" "$p"; done | sort -n)
    while read -r e p; do
        [[ -n "$p" ]] || continue
        ACT_FILE+=("${fileof[$p]}"); ACT_ET+=("$e"); ACT_STEP+=("${lbl[$p]:-working}")
        ACT_CAT+=("$(act_cat_of "${fileof[$p]}")")
    done <<<"$sorted"
    ACT_N=${#ACT_FILE[@]}
}

# Current pipeline phase, from the last "[STAGE …]" line of the log.
STAGE_TXT=""
read_stage() {
    STAGE_TXT=""
    [[ -f "$LOG" ]] || return 0
    STAGE_TXT=$(tail -c 60000 "$LOG" 2>/dev/null | tr '\r' '\n' | grep -aE '^\[STAGE [0-9]' | tail -1)
    STAGE_TXT="${STAGE_TXT//[[:cntrl:]]/ }"
}

# Focus: which source / library category the dashboard is about right now.
ASRC=""
derive_focus() {
    ASRC=""
    (( ACT_N > 0 )) || return 0
    local fc="${ACT_CAT[0]:-}"
    case "$fc" in CAMERA|PHOTOS|VIDEO|DOWNLOADS) ASRC="$fc" ;; esac
    if [[ "${NOW_RUNNING:-0}" == "0" ]]; then
        case "$fc" in
            CAMERA|PHOTOS) cur_cat=PHOTOS ;;
            MUSIC|MOVIES|TV) cur_cat="$fc" ;;
            *) cur_cat="" ;;
        esac
        cur_group="$(basename "$(dirname "${ACT_FILE[0]}")")"
    fi
}

# Progress of a category: inbox sources count files imported out of the baseline;
# the camera build phase reads the importer's own done/total; library categories use
# portable-built / desktop-total.
BUILD_PROGRESS_FILE="${SCRIPT_DIR}/logs/.camera-build-progress"
prog_for() {
    local c="$1" l b bd bt
    PD=0; PT=0
    if [[ "$c" == CAMERA && "$STAGE_TXT" == "[STAGE 1b]"* && -s "$BUILD_PROGRESS_FILE" ]]; then
        read -r bd bt < "$BUILD_PROGRESS_FILE" 2>/dev/null || true
        if [[ "${bt:-}" =~ ^[0-9]+$ && "${bd:-}" =~ ^[0-9]+$ ]]; then PD=$bd; PT=$bt; return 0; fi
    fi
    if [[ -n "${SRC_LEFT[$c]:-}" || -n "${SRC_BASE[$c]:-}" ]]; then
        l="${SRC_LEFT[$c]:-0}"; b="${SRC_BASE[$c]:-0}"
        if (( b > 0 )); then PT=$b; PD=$(( b - l )); (( PD < 0 )) && PD=0; return 0; fi
    fi
    [[ "$c" == CAMERA ]] && c=PHOTOS
    PD="${DONE[$c]:-0}"; PT="${TOT[$c]:-0}"; (( PT < PD )) && PT=$PD
    return 0
}

# cached library counts + pending (computed by a background producer so slow
# SMB scans never block the render loop)
declare -A DONE TOT SRC_LEFT SRC_BASE
PEND_LINES=(); _last_count_ts=0; _last_cat=""; _last_asrc=""
SESSION_T0=$(date +%s); IMPORTED_T0=-1
PEND_OFFSET=0; MANUAL_UNTIL=0
COUNTS_READY=0; _counter_pid=""; _results_mtime=0
RESULT_FILE="$(mktemp -t syncui.res.XXXXXX 2>/dev/null || echo /tmp/syncui.res.$$)"
RESULT_TMP="${RESULT_FILE}.tmp"
FRAME_FILE="$(mktemp -t syncui.frame.XXXXXX 2>/dev/null || echo /tmp/syncui.frame.$$)"

# Runs in the background; discovers counts + the current category's pending queue
# incrementally, republishing an atomic snapshot after each step so the UI fills
# in from 0 as results arrive (fast categories first, slow SMB scans last).
spawn_counter() {
    local ccat="$1" cgroup="$2" asrc="${3:-}"
    local snap="" pend="PEND_LINES=()" c t d g gp dc pc name n cnt dir rel tot items pend_in=""
    _publish() { { printf '%s' "$snap"; printf '%s\n' "$pend"; } > "$RESULT_TMP" 2>/dev/null \
                 && mv -f "$RESULT_TMP" "$RESULT_FILE" 2>/dev/null; }
    # library queue (music / movies / TV) for the current category, when no inbox source is active
    if [[ -n "$ccat" && -z "$asrc" ]]; then
        roots_for "$ccat"; pend="PEND_LINES=("
        while IFS= read -r g; do
            [[ -z "$g" ]] && continue
            name=$(basename "$g"); gp="${g/LIBRARY.DESKTOP/LIBRARY.PORTABLE}"
            dc=$(count_lib "$g"  "$DGLOB" "$DGLOB2")
            pc=$(count_lib "$gp" "$PGLOB" "$DGLOB2" "$UI_THRESHOLD")
            (( dc > 0 && pc >= dc )) && continue
            [[ "$name" == "$cgroup" ]] && continue
            pend+=" $(printf '%q' "$name|$pc|$dc")"
        done < <(find "$DROOT" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort)
        pend+=" )"; _publish
    fi
    # inbox: ONE scan per source gives both the files left and the per-folder queue
    local order_src=(); [[ -n "$asrc" ]] && order_src+=("$asrc")
    for c in "${SRC_CATS[@]}"; do [[ "$c" == "$asrc" ]] || order_src+=("$c"); done
    local want_inbox_pend=0; [[ -n "$asrc" || -z "$ccat" ]] && want_inbox_pend=1
    for c in "${order_src[@]}"; do
        src_for "$c"; tot=0; items=""
        while IFS='|' read -r cnt dir; do
            [[ -n "$cnt" ]] || continue
            tot=$(( tot + cnt ))
            if (( want_inbox_pend )) && [[ -z "$asrc" || "$c" == "$asrc" ]] && (( ${#items} < 400000 )); then
                rel="${dir#"$SDIR"}"; rel="${rel#/}"; [[ -z "$rel" ]] && rel="."
                [[ -z "$asrc" ]] && rel="$c/$rel"
                items+=" $(printf '%q' "$rel|$cnt|-")"
            fi
        done < <(find "$SDIR" -type f ! -name '.*' ! -iname 'Thumbs.db' ! -iname 'desktop.ini' -printf '%h\n' 2>/dev/null \
                 | sort | uniq -c | sed -E 's/^ *([0-9]+) (.*)$/\1|\2/')
        snap+="SRC_LEFT[$c]=$tot"$'\n'
        if (( want_inbox_pend )); then pend_in+="$items"; pend="PEND_LINES=($pend_in )"; fi
        _publish
    done
    # category counts, current category first, publishing after each
    local order=(); [[ -n "$ccat" ]] && order+=("$ccat")
    for c in "${CATS[@]}"; do [[ "$c" == "$ccat" ]] || order+=("$c"); done
    for c in "${order[@]}"; do
        roots_for "$c"
        t=$(count_lib "$DROOT" "$DGLOB" "$DGLOB2")
        d=$(count_lib "$PROOT" "$PGLOB" "$DGLOB2" "$UI_THRESHOLD")
        snap+="TOT[$c]=$t"$'\n'"DONE[$c]=$d"$'\n'
        _publish
    done
}
# Baseline = the most files ever seen waiting in a source folder this run;
# progress = baseline - files left.
load_baseline() {
    local k v
    [[ -f "$BASE_FILE" ]] || return 0
    while IFS== read -r k v; do
        [[ "$k" =~ ^[A-Z]+$ && "$v" =~ ^[0-9]+$ ]] && SRC_BASE[$k]=$v
    done < "$BASE_FILE"
}
update_baselines() {
    local c l changed=0
    for c in "${SRC_CATS[@]}"; do
        l="${SRC_LEFT[$c]:-}"; [[ -n "$l" ]] || continue
        if (( l > ${SRC_BASE[$c]:-0} )); then SRC_BASE[$c]=$l; changed=1; fi
    done
    if (( changed )); then
        for c in "${SRC_CATS[@]}"; do printf '%s=%s\n' "$c" "${SRC_BASE[$c]:-0}"; done > "$BASE_FILE" 2>/dev/null
    fi
}
load_baseline

maybe_refresh_counts() {
    local now; now=$(date +%s)
    # publish finished results
    if [[ -s "$RESULT_FILE" ]]; then
        local m; m=$(stat -c %Y "$RESULT_FILE" 2>/dev/null || echo 0)
        if (( m > _results_mtime )); then
            # shellcheck disable=SC1090
            source "$RESULT_FILE" 2>/dev/null && { COUNTS_READY=1; _results_mtime=$m; update_baselines; }
        fi
    fi
    # (re)spawn producer when idle and results are stale / category changed
    if [[ -z "$_counter_pid" ]] || ! kill -0 "$_counter_pid" 2>/dev/null; then
        if (( COUNTS_READY == 0 )) || (( now - _last_count_ts >= COUNT_TTL )) \
           || [[ "$cur_cat" != "$_last_cat" || "$ASRC" != "${_last_asrc:-}" ]]; then
            spawn_counter "$cur_cat" "$cur_group" "$ASRC" </dev/null >/dev/null 2>&1 &
            _counter_pid=$!; _last_count_ts=$now; _last_cat="$cur_cat"; _last_asrc="$ASRC"
        fi
    fi
}

# ---- rendering -------------------------------------------------------------
FRAME=0
cleanup() {
    [[ -n "$_counter_pid" ]] && kill "$_counter_pid" 2>/dev/null
    rm -f "$RESULT_FILE" "$RESULT_TMP" "$FRAME_FILE" 2>/dev/null
    printf '%s[?7h%s[?25h%s[?1049l' "$ESC" "$ESC" "$ESC"
}
trap cleanup EXIT INT TERM
printf '%s[?1049h%s[?25l%s[?7l' "$ESC" "$ESC" "$ESC"   # alt screen, hide cursor, no auto-wrap

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
    FRAME_LINES=$lines
    local bw=$(( cols - 38 )); (( bw < 10 )) && bw=10       # library / overall bars
    local bwn=$(( cols - 46 )); (( bwn < 10 )) && bwn=10    # NOW bar (leaves room for times)
    local sp="${SPIN:$(( FRAME % ${#SPIN} )):1}"
    local rule; rule=$(printf '─%.0s' $(seq 1 $(( cols - 2 )) ))
    local status="running"; [[ "$NOW_RUNNING" == "0" && "$ACT_N" == "0" ]] && status="idle"
    [[ -n "$SYNC_PID" ]] && { kill -0 "$SYNC_PID" 2>/dev/null || status="finished"; }

    local szkey="${cols}x${lines}"
    [[ "$szkey" != "${LAST_SZ:-}" ]] && { printf '%s[2J' "$ESC"; LAST_SZ="$szkey"; }   # resized → clear once
    printf '%s[H' "$ESC"   # home
    printf '%s%s ⟳ MYMEDIA SYNC %s%s%s   %s%s %s  %s%s\n' \
        "$B" "$C_TITLE" "$RST" "$DIM" "$C_LINE" "$C_NOW" "$sp" "$status" \
        "$(date '+%H:%M:%S')" "$RST"
    printf '%s%s%s\n' "$C_LINE" "$rule" "$RST"

    # NOW panel: 4 rows (2 when compact), always the same height
    local compact=0; (( lines < 28 )) && compact=1
    local nmode=none
    if [[ "$NOW_RUNNING" == "1" && -n "$cur_file" ]]; then nmode=ffmpeg
    elif (( ACT_N > 0 )); then nmode=active
    elif [[ -n "$cur_file" ]]; then nmode=last; fi
    local icon="•" ccol="$RST" nlabel="NOW" fc stage_short=""
    if [[ -n "$STAGE_TXT" ]]; then
        stage_short="${STAGE_TXT#\[STAGE }"; stage_short="${stage_short/\] / · }"; stage_short="${stage_short%%: /*}"
    fi
    case "$nmode" in
    ffmpeg|last)
        [[ -n "$cur_cat" ]] && { roots_for "$cur_cat"; icon="$ICON"; ccol="$COL"; }
        [[ "$nmode" == last ]] && nlabel="LAST"
        if (( compact )); then
            printf ' %s%s▶ %s%s %s%s %s%s %.*s%s\n' "$B" "$C_NOW" "$nlabel" "$RST" "$ccol" "$icon" "${cur_cat:-?}" "$RST$B" \
                $(( cols - 16 )) "${cur_group:-$(basename "$cur_file")}" "$RST"
        else
            printf ' %s%s▶ %s%s   %s%s %s%s\n' "$B" "$C_NOW" "$nlabel" "$RST" "$ccol" "$icon" "${cur_cat:-?}" "$RST"
            printf '   %s%.*s%s\n' "$B" $(( cols - 4 )) "${cur_group:-$(basename "$cur_file")}" "$RST"
            printf '   %s%.*s%s\n' "$DIM" $(( cols - 4 )) "$(basename "$cur_file")" "$RST"
        fi
        printf '   %s  %s%3s%%%s   %s%s / %s%s\n' \
            "$(bar "$cur_pct" 100 "$bwn" "$C_NOW")" "$C_NOW" "$cur_pct" "$RST" \
            "$DIM" "${cur_tpos:-–}" "${cur_tdur:-–}" "$RST" ;;
    active)
        fc="${ACT_CAT[0]:-}"
        if [[ -n "$fc" ]]; then
            if [[ " ${SRC_CATS[*]} " == *" $fc "* ]]; then src_for "$fc"; icon="$SICON"; ccol="$SCOL"
            else roots_for "$fc"; icon="$ICON"; ccol="$COL"; fi
        fi
        local k nm tail_ rows_files=2; (( compact )) && rows_files=0
        if (( compact )); then
            nm="$(basename "${ACT_FILE[0]}")"; nm="${nm//[[:cntrl:]]/ }"
            printf -v tail_ '%s · %ss' "${ACT_STEP[0]}" "${ACT_ET[0]}"
            local cw=$(( cols - 30 - ${#tail_} )); (( cw < 8 )) && cw=8
            (( ${#nm} > cw )) && nm="${nm:0:$(( cw - 1 ))}…"
            printf ' %s%s▶ NOW%s %s%s %s%s %s%s%s %s%s %s %s%s\n' "$B" "$C_NOW" "$RST" "$ccol" "$icon" "${fc:-?}" "$RST" \
                "$DIM" "$ACT_N" "$RST" "$B" "$nm" "$RST" "$DIM" "$tail_$RST"
        else
            printf ' %s%s▶ NOW%s   %s%s %s%s  %s%s processing%s%s%s\n' "$B" "$C_NOW" "$RST" "$ccol" "$icon" "${fc:-?}" "$RST" \
                "$DIM" "$ACT_N" "${stage_short:+  ·  }" "${stage_short:0:$(( cols - 32 ))}" "$RST"
        fi
        for (( k = 0; k < rows_files; k++ )); do
            if (( k < ACT_N )); then
                nm="$(basename "${ACT_FILE[$k]}")"; nm="${nm//[[:cntrl:]]/ }"
                printf -v tail_ '%s · %ss' "${ACT_STEP[$k]}" "${ACT_ET[$k]}"
                local nwid=$(( cols - 8 - ${#tail_} )); (( nwid < 8 )) && nwid=8
                (( ${#nm} > nwid )) && nm="${nm:0:$(( nwid - 1 ))}…"
                printf '   %s%s%s %s%-*s%s  %s%s%s\n' "$C_NOW" "$sp" "$RST" "$B" "$nwid" "$nm" "$RST" "$DIM" "$tail_" "$RST"
            else
                printf '\n'
            fi
        done
        if [[ -n "$fc" ]]; then prog_for "$fc"; else PD=0; PT=0; fi
        printf '   %s  %s%3s%%%s   %s%s / %s files%s\n' \
            "$(bar "$PD" "$PT" "$bwn" "$C_NOW")" "$C_NOW" "$(pct "$PD" "$PT")" "$RST" \
            "$DIM" "$PD" "$PT" "$RST" ;;
    *)
        printf ' %s(waiting for an item to start…)%s%s\n' "$DIM" "${stage_short:+  ·  $stage_short}" "$RST"
        if (( compact )); then printf '\n'; else printf '\n\n\n'; fi ;;
    esac
    printf '%s%s%s\n' "$C_LINE" "$rule" "$RST"

    # library bars
    (( compact )) || printf ' %sLIBRARY%s  %s(portable rebuilt ← desktop)%s\n' "$B" "$RST" "$DIM" "$RST"
    local c d t p inscope
    for c in "${CATS[@]}"; do
        roots_for "$c"; d="${DONE[$c]:-0}"; t="${TOT[$c]:-0}"; (( t < d )) && t=$d; p=$(pct "$d" "$t")
        if (( d > 0 )) || [[ "$c" == "$cur_cat" ]]; then
            printf '   %s%s %-7s%s %s  %s%6s/%-6s%s %s%3s%%%s\n' \
                "$COL" "$ICON" "$c" "$RST" "$(bar "$d" "$t" "$bw" "$COL")" \
                "$B" "$d" "$t" "$RST" "$DIM" "$p" "$RST"
        else
            printf '   %s%s %-7s %s  %6s    · waiting%s\n' \
                "$DIM" "$ICON" "$c" "$(bar 0 "$t" "$bw" "$C_BARBG")" "$t" "$RST"
        fi
    done
    printf '%s%s%s\n' "$C_LINE" "$rule" "$RST"

    # inbox bars (camera / photos / video / downloads)
    local inbox_rows=0 sc sl sb sd sp2 lastev evcol
    printf ' %sINBOX%s  %s(UNSORTED → library, source removed after each import)%s\n' "$B" "$RST" "$DIM" "$RST"
    (( inbox_rows++ ))
    for sc in "${SRC_CATS[@]}"; do
        src_for "$sc"; sl="${SRC_LEFT[$sc]:-}"; sb="${SRC_BASE[$sc]:-0}"
        if [[ -z "$sl" ]]; then
            printf '   %s%s %-9s %s  counting…%s\n' "$DIM" "$SICON" "$sc" "$(bar 0 1 $(( bw - 2 )) "$C_BARBG")" "$RST"
        elif (( sb == 0 )); then
            printf '   %s%s %-9s %s  %s· empty%s\n' "$DIM" "$SICON" "$sc" "$(bar 0 1 $(( bw - 2 )) "$C_BARBG")" "" "$RST"
        else
            sd=$(( sb - sl )); (( sd < 0 )) && sd=0
            printf '   %s%s %-9s%s %s  %s%6s/%-6s%s %s%3s%%%s\n' \
                "$SCOL" "$SICON" "$sc" "$RST" "$(bar "$sd" "$sb" $(( bw - 2 )) "$SCOL")" \
                "$B" "$sd" "$sb" "$RST" "$DIM" "$(pct "$sd" "$sb")" "$RST"
        fi
        (( inbox_rows++ ))
    done
    lastev=""
    [[ -f "$LOG" ]] && lastev=$(tail -n 400 "$LOG" 2>/dev/null | tr '\r' '\n' | grep -aE '^\[(WARN|ERROR)\]' | tail -1)
    local imp=0 left=0 rate="" eta="" nowt; nowt=$(date +%s)
    for sc in "${SRC_CATS[@]}"; do
        sb="${SRC_BASE[$sc]:-0}"; sl="${SRC_LEFT[$sc]:-0}"
        (( sb > 0 )) && { imp=$(( imp + sb - sl )); left=$(( left + sl )); }
    done
    (( IMPORTED_T0 < 0 && COUNTS_READY == 1 )) && IMPORTED_T0=$imp
    if (( IMPORTED_T0 >= 0 && nowt - SESSION_T0 >= 60 && imp > IMPORTED_T0 )); then
        local per_min=$(( (imp - IMPORTED_T0) * 600 / (nowt - SESSION_T0) ))   # tenths of files/min
        rate=$(printf '%d.%d/min' $(( per_min / 10 )) $(( per_min % 10 )))
        if (( per_min > 0 && left > 0 )); then
            local mins=$(( left * 600 / per_min ))
            eta=$(printf ' · ETA %dh%02dm' $(( mins / 60 )) $(( mins % 60 )))
        fi
    fi
    if [[ -n "$lastev" ]]; then
        lastev="${lastev//[[:cntrl:]]/ }"
        printf '   %s↳ %.*s%s\n' "$C_WARN" $(( cols - 8 )) "$lastev" "$RST"
    else
        printf '   %s↳ %s moved · %s left · %s processing%s%s%s\n' "$DIM" "$imp" "$left" "$ACT_N" "${rate:+ · $rate}" "$eta" "$RST"
    fi
    (( inbox_rows++ ))
    printf '%s%s%s\n' "$C_LINE" "$rule" "$RST"
    (( inbox_rows++ ))

    # pending queue for the current category — fills remaining screen height,
    # auto-scrolls when it overflows (manual keys pause the auto-scroll).
    local total=${#PEND_LINES[@]}
    # rows consumed by everything except the pending item rows
    local overhead=$(( 16 + inbox_rows - 3 * compact ))
    local avail=$(( lines - overhead )); (( avail < 1 )) && avail=1
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
        printf -v phdr '  %s·  %d–%d of %d  (↑↓ scroll)%s' \
            "$DIM" $(( PEND_OFFSET + 1 )) $(( PEND_OFFSET + avail )) "$total" "$RST"
    elif (( total > 0 )); then
        printf -v phdr '  %s·  %d to go%s' "$DIM" "$total" "$RST"
    fi
    printf ' %s⏳ PENDING%s %s— %s%s%s\n' "$B$C_WARN" "$RST" "$DIM" "${ASRC:-${cur_cat:-INBOX}}" "$RST" "$phdr"

    local shown_rows=0
    if (( total == 0 )); then
        printf '   %snothing pending%s\n' "$DIM" "$RST"; shown_rows=1
    else
        local i line name pc dc nw=$(( cols - 24 )); (( nw < 10 )) && nw=10
        for (( i = PEND_OFFSET; i < total && shown_rows < avail; i++ )); do
            line="${PEND_LINES[$i]}"
            IFS='|' read -r name pc dc <<<"$line"
            name="${name//[[:cntrl:]]/ }"
            (( ${#name} > nw )) && name="${name:0:$(( nw - 1 ))}…"
            if [[ "$dc" == "-" ]]; then
                printf '   %s%*s%s files  %s\n' "$B" 11 "$pc" "$RST" "$name"
            else
                printf '   %s  %s%3s%s/%-3s  %s\n' \
                    "$(bar "$pc" "$dc" 8 "$C_WARN")" "$B" "$pc" "$RST$DIM" "$dc$RST" "$name"
            fi
            (( shown_rows++ ))
        done
    fi
    # pad so the OVERALL bar stays pinned to the bottom of the screen
    while (( shown_rows < avail )); do printf '\n'; (( shown_rows++ )); done
    printf '%s%s%s\n' "$C_LINE" "$rule" "$RST"

    # overall — only categories active or with progress this session
    local od=0 ot=0 ib=0 bd bt
    for c in "${SRC_CATS[@]}"; do ib=$(( ib + ${SRC_BASE[$c]:-0} )); done
    if [[ "$STAGE_TXT" == "[STAGE 1b]"* && -s "$BUILD_PROGRESS_FILE" ]] && read -r bd bt < "$BUILD_PROGRESS_FILE" 2>/dev/null \
       && [[ "${bd:-}" =~ ^[0-9]+$ && "${bt:-}" =~ ^[0-9]+$ ]]; then
        od=$bd; ot=$bt                                   # camera build phase: files built / to build
    elif (( ib > 0 )); then
        for c in "${SRC_CATS[@]}"; do
            sb="${SRC_BASE[$c]:-0}"; (( sb > 0 )) && { od=$(( od + sb - ${SRC_LEFT[$c]:-0} )); ot=$(( ot + sb )); }
        done
    else
        for c in "${CATS[@]}"; do
            if (( ${DONE[$c]:-0} > 0 )) || [[ "$c" == "$cur_cat" ]]; then
                d="${DONE[$c]:-0}"; t="${TOT[$c]:-0}"; (( t < d )) && t=$d
                od=$(( od + d )); ot=$(( ot + t ))
            fi
        done
    fi
    printf '%s[J' "$ESC"   # clear stale rows before drawing the bottom line
    printf ' %sOVERALL%s %s  %s%6s/%-6s%s %s%3s%%%s  %s·  q quit%s' \
        "$B" "$RST" "$(bar "$od" "$ot" "$(( bw - 5 ))" "$C_OK")" "$B" "$od" "$ot" "$RST" "$DIM" "$(pct "$od" "$ot")" "$RST" "$DIM" "$RST"
}

# ---- main loop -------------------------------------------------------------
while :; do
    read_now
    read_active
    read_stage
    derive_focus
    maybe_refresh_counts
    draw >"$FRAME_FILE"
    # Force the frame to exactly the terminal height: any surplus/shortfall is taken
    # from the PENDING area (just above the last rule + OVERALL line), so the screen
    # never scrolls and the other widgets never move. Then erase to end of line on
    # every row so shorter frames leave no stale text.
    awk -v n="${FRAME_LINES:-24}" '{ L[NR]=$0 }
        END { k=NR
              if (k <= 2) { for (i=1;i<=k;i++) { if (i<k) print L[i]; else printf "%s", L[i] } exit }
              if (k > n) { for (i=1;i<=n-2;i++) print L[i] }
              else       { for (i=1;i<=k-2;i++) print L[i]; for (i=k;i<n;i++) print "" }
              print L[k-1]; printf "%s", L[k] }' "$FRAME_FILE" | sed "s/\$/${ESC}[K/"
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
