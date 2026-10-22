#!/usr/bin/env bash
# sync.sh — main orchestrator for the v2 media library system
#
# Usage:
#   ./sync.sh                        # run all stages
#   ./sync.sh music                  # music only
#   ./sync.sh movies                 # movies only
#   ./sync.sh camera                 # camera only
#   ./sync.sh photos                 # photos only
#   ./sync.sh downloads              # downloads/inbox only
#   ./sync.sh music movies           # multiple stages
#
# Stage names: camera, downloads, music, movies, tv, photos

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# Stage filter: parse CLI arguments into a set of enabled stages
# No arguments = run all stages
# MEDIA_PATH=<dir> sets the library root (UNSORTED and LIBRARY.* live there)
# Compatible with bash 3.2 (no associative arrays)
# ---------------------------------------------------------------------------
_STAGES_ENABLED=""
for _arg in "$@"; do
    case "$_arg" in
        MEDIA_PATH=*) export MEDIA_PATH="${_arg#MEDIA_PATH=}" ;;
        *)
            _arg_lower="$(echo "$_arg" | tr '[:upper:]' '[:lower:]')"
            case "$_arg_lower" in
                camera|downloads|music|movies|tv|photos) _STAGES_ENABLED="$_STAGES_ENABLED $_arg_lower" ;;
                setup) _STAGES_ENABLED="$_STAGES_ENABLED setup" ;;
                doctor) _STAGES_ENABLED="$_STAGES_ENABLED doctor" ;;
                stop)
                    echo "[STOP] Killing sync processes..." >&2
                    # Kill workers first (leaf processes), then the orchestrators,
                    # then the sync.sh parent/tee — use SIGTERM first, SIGKILL if needed.
                    pkill -TERM -f "orginize.sh"  2>/dev/null || true
                    pkill -TERM -f "import.sh"    2>/dev/null || true
                    pkill -TERM -f "ffmpeg"        2>/dev/null || true
                    pkill -TERM -f "sips"          2>/dev/null || true
                    # Give processes a moment to exit cleanly
                    _stop_waited=0
                    while pgrep -qf "orginize.sh|import.sh" 2>/dev/null && (( _stop_waited < 5 )); do
                        (( _stop_waited++ )) || true
                    done
                    # Force-kill anything still alive
                    pkill -KILL -f "orginize.sh"  2>/dev/null || true
                    pkill -KILL -f "import.sh"    2>/dev/null || true
                    pkill -KILL -f "ffmpeg"        2>/dev/null || true
                    # Kill the sync.sh orchestrator (the tee-parent process); exclude
                    # this very invocation ($$) so we don't kill ourselves before exit 0.
                    pgrep -f "sync.sh" 2>/dev/null | while IFS= read -r _pid; do
                        [[ "$_pid" == "$$" ]] && continue
                        kill -TERM "$_pid" 2>/dev/null || true
                    done
                    echo "[STOP] Done." >&2
                    exit 0
                    ;;
                *) echo "[ERROR] Unknown argument: '${_arg}'. Valid stages: camera downloads music movies tv photos setup doctor stop" >&2; exit 1 ;;
            esac
            ;;
    esac
done
[[ -z "$_STAGES_ENABLED" ]] && _STAGES_ENABLED="camera downloads music movies tv photos"
unset _arg _arg_lower

source "${SCRIPT_DIR}/config.sh"

# ---------------------------------------------------------------------------
# Full-run output capture (auto-tee)
# ---------------------------------------------------------------------------
# Mirror EVERY line of this run — tagged log_* lines AND untagged tool stdout
# (AtomicParsley/ffmpeg/sips progress, AcoustID INFO, etc.) — to a timestamped
# archive file, so the complete run narrative survives the terminal closing
# without anyone remembering to add `| tee`. Implemented by re-executing self
# once with all output piped through tee. This is a PLAIN PIPE, never process
# substitution (`> >(...)` corrupts the heap on Apple's bash 3.2). The child run
# sees _SYNC_TEE_ACTIVE set and proceeds normally. Set SYNC_AUTOTEE=0 to disable.
if [[ -z "${_SYNC_TEE_ACTIVE:-}" && "${SYNC_AUTOTEE:-1}" == "1" ]]; then
    export _SYNC_TEE_ACTIVE=1
    mkdir -p "${LOG_ARCHIVE_DIR}" 2>/dev/null || true
    _RUN_LOG="${LOG_ARCHIVE_DIR}/sync-$(date '+%Y%m%d-%H%M%S').log"
    echo "[INFO] Full run output is being captured to: ${_RUN_LOG}" >&2
    set +e
    # Prefer running under a pseudo-TTY (`script`) so interactive tools such as
    # ffmpeg keep their live, unbuffered progress output on screen while every
    # line is still captured to ${_RUN_LOG}. A plain `| tee` makes stdout a pipe,
    # which ffmpeg detects as non-interactive and then block-buffers, hiding all
    # progress until the very end. Fall back to `tee` when stdout is not a
    # terminal or `script` is unavailable. Never use process substitution
    # (`> >(...)`) — it corrupts the heap on Apple's bash 3.2.
    if [[ -t 1 ]] && command -v script >/dev/null 2>&1; then
        if script --version 2>/dev/null | grep -qi util-linux; then
            # util-linux: script -q -e -c "<command string>" <logfile>
            script -q -e -c "$(printf '%q ' "${BASH:-/bin/bash}" "$0" "$@")" "${_RUN_LOG}"
            _rc=$?
        else
            # macOS/BSD: script -q <logfile> <command> [args...]
            script -q "${_RUN_LOG}" "${BASH:-/bin/bash}" "$0" "$@"
            _rc=$?
        fi
    else
        "${BASH:-/bin/bash}" "$0" "$@" 2>&1 | tee "${_RUN_LOG}"
        _rc="${PIPESTATUS[0]}"
    fi
    set -e
    exit "$_rc"
fi

# Returns 0 (true) if the named stage is in the enabled list
stage_enabled() { echo " $_STAGES_ENABLED " | grep -qw "$1"; }

# ---------------------------------------------------------------------------
# setup: install all required external tools via Homebrew
# Usage: bash sync.sh setup
# ---------------------------------------------------------------------------
# Install the eyeD3 CLI (MP3 ID3 tag writer). The Ubuntu python3-eyed3 package is
# module-only (no `eyeD3` command), so the console script must come from PyPI via
# pipx (isolated, PEP-668 safe) or pip.
_pip_install_eyed3() {
    if command -v eyeD3 &>/dev/null; then
        return 0
    fi
    if command -v pipx &>/dev/null; then
        pipx install eyeD3 || true
        pipx ensurepath &>/dev/null || true
    elif command -v pip3 &>/dev/null; then
        pip3 install --user eyeD3 2>/dev/null || pip3 install --user --break-system-packages eyeD3 || true
    else
        echo "[WARN] Could not install eyeD3 (no pipx/pip3). MP3 ID3 tagging will be limited." >&2
    fi
}

# macOS: install everything via Homebrew. ffmpeg is tapped with fdk-aac for the
# highest-quality AAC encoder; sips is a macOS built-in so no image tool needed.
_setup_macos() {
    if ! command -v brew &>/dev/null; then
        echo "[ERROR] Homebrew not found. Install from https://brew.sh first." >&2
        return 1
    fi
    echo "[SETUP] Installing required tools via Homebrew..."
    if ! command -v ffmpeg &>/dev/null; then
        brew tap homebrew-ffmpeg/ffmpeg 2>/dev/null || true
        brew install homebrew-ffmpeg/ffmpeg/ffmpeg --with-fdk-aac || brew install ffmpeg || true
    else
        echo "[SETUP] ffmpeg already installed: $(command -v ffmpeg)"
    fi
    brew install chromaprint       || true   # fpcalc (AcoustID fingerprinting)
    brew install exiftool          || true   # EXIF read/write
    brew install atomicparsley     || true   # MP4/M4A metadata atoms
    brew install jq                || true   # JSON parsing (TMDB / Last.fm)
    brew install flac              || true   # metaflac (FLAC tag writing)
    brew install eye-d3            || true   # MP3 ID3 tags
    brew install imagemagick       || true   # optional: extra image formats
}

# Linux (Debian/Ubuntu/Xubuntu): install via apt-get. ImageMagick + libheif
# replace macOS sips for photo conversion. The apt ffmpeg provides ffprobe +
# decoders; a local libfdk_aac ffmpeg (build-ffmpeg.sh) provides the encoder so
# AAC output matches v2 exactly.
_setup_linux() {
    if command -v apt-get &>/dev/null; then
        echo "[SETUP] Installing dependencies via apt-get (sudo required)..."
        sudo apt-get update
        sudo apt-get install -y \
            ffmpeg \
            libimage-exiftool-perl \
            atomicparsley \
            flac \
            libchromaprint-tools \
            jq \
            imagemagick \
            libheif1 \
            curl || true
        # eyeD3 CLI is not shipped by the distro package — install via pipx/pip.
        _pip_install_eyed3
        # Build a local ffmpeg WITH libfdk_aac (exact v2 AAC parity). The apt
        # ffmpeg above provides ffprobe + decoders; this build is the encoder.
        bash "${SCRIPT_DIR}/build-ffmpeg.sh" \
            || echo "[WARN] libfdk_aac ffmpeg build failed; encoding will fail until fixed." >&2
    else
        echo "[ERROR] apt-get not found. Install manually:" >&2
        echo "        ffmpeg exiftool AtomicParsley flac chromaprint(fpcalc) jq imagemagick libheif eyeD3" >&2
        return 1
    fi
}

# Verify every required tool is present (cross-platform).
_setup_verify() {
    echo "[SETUP] Verifying tools:"
    local _ok=1 _tool
    for _tool in ffmpeg ffprobe fpcalc exiftool AtomicParsley jq metaflac eyeD3 curl; do
        if command -v "$_tool" &>/dev/null; then
            echo "  [OK]      $_tool → $(command -v "$_tool")"
        else
            echo "  [MISSING] $_tool"
            _ok=0
        fi
    done
    # Image converter: sips (macOS built-in) or ImageMagick (Linux)
    if [[ "$OS_NAME" == "macos" ]] && command -v sips &>/dev/null; then
        echo "  [OK]      image  → $(command -v sips) (macOS sips)"
    elif command -v magick &>/dev/null; then
        echo "  [OK]      image  → $(command -v magick) (ImageMagick)"
    elif command -v convert &>/dev/null; then
        echo "  [OK]      image  → $(command -v convert) (ImageMagick)"
    else
        echo "  [MISSING] image converter (install sips/ImageMagick)"
        _ok=0
    fi
    # Encoder must be libfdk_aac (exact v2 parity) — check the encode binary.
    if "${FFMPEG_BIN}" -hide_banner -encoders 2>/dev/null | grep -qw libfdk_aac; then
        echo "  [OK]      libfdk_aac → ${FFMPEG_BIN}"
    else
        echo "  [MISSING] libfdk_aac encoder in ${FFMPEG_BIN} (run: bash build-ffmpeg.sh)"
        _ok=0
    fi
    echo "  [INFO]    OS=${OS_NAME}  parallel jobs=${MAX_PARALLEL_JOBS}"
    if [[ "$_ok" == "1" ]]; then
        echo "[SETUP] All tools installed."
    else
        echo "[SETUP] Some tools are still missing — check output above." >&2
        return 1
    fi
}

# ---------------------------------------------------------------------------
# setup: install all required external tools for the current OS, then verify.
# Usage: bash sync.sh setup   (or: make setup)
# ---------------------------------------------------------------------------
run_setup() {
    echo "[SETUP] Detected OS: ${OS_NAME}"
    case "$OS_NAME" in
        macos) _setup_macos ;;
        linux) _setup_linux ;;
        *) echo "[ERROR] Unsupported OS '${OS_NAME}' for automated setup. Install deps manually." >&2; return 1 ;;
    esac
    _setup_verify
}

if stage_enabled setup; then
    run_setup
    exit $?
fi

if stage_enabled doctor; then
    _setup_verify
    exit $?
fi

# ---------------------------------------------------------------------------
# DEBUG_MODE: kill any leftover processes from a previous run before starting
# ---------------------------------------------------------------------------
if [[ "${DEBUG_MODE:-0}" == "1" ]]; then
    echo "[DEBUG] Stopping any leftover sync processes for clean run..." >&2
    pkill -f "${SCRIPT_DIR}/import\.sh"   2>/dev/null || true
    pkill -f "${SCRIPT_DIR}/orginize\.sh" 2>/dev/null || true
    pkill -f "${SCRIPT_DIR}/convert\.sh"  2>/dev/null || true
    pkill -f "ffmpeg.*${SCRIPT_DIR}"      2>/dev/null || true
    # small grace period for processes to exit
    sleep 0.3
fi

# ---------------------------------------------------------------------------
# Trap: kill all background children on Ctrl-C / error
# ---------------------------------------------------------------------------
CHILD_PIDS=""

cleanup() {
    echo "[INFO] Interrupted — killing background jobs..." >&2
    # shellcheck disable=SC2086
    [[ -n "$CHILD_PIDS" ]] && kill $CHILD_PIDS 2>/dev/null || true
    exit 1
}
trap cleanup INT TERM

# ---------------------------------------------------------------------------
# Utility
# ---------------------------------------------------------------------------

# Pool of active import.sh PIDs.
_IMPORT_POOL_PIDS=()

# Max concurrent import.sh processes across ALL stages.
# Default: 1 (sequential) — guarantees total active ffmpeg ≤ ncores at any time.
# Each import.sh already parallelises internally up to MAX_PARALLEL_JOBS (=ncores).
# Increase only if you have very fast I/O and want to overlap album-context API
# lookups with encoding of a previous batch.
MAX_IMPORT_JOBS="${MAX_IMPORT_JOBS:-1}"

# Wait for the oldest slot in the import pool to finish.
_import_pool_drain_one() {
    local _oldest="${_IMPORT_POOL_PIDS[0]}"
    wait "$_oldest" 2>/dev/null || true
    _IMPORT_POOL_PIDS=("${_IMPORT_POOL_PIDS[@]:1}")
}

# Run import.sh; blocks if the pool is already at MAX_IMPORT_JOBS.
run_import_bg() {
    local src="$1" label="$2" root="$3"
    if [[ ! -d "$src" ]]; then
        echo "[WARN] Source not found, skipping: $src" >&2
        return 0
    fi
    # Throttle: wait for a free slot before launching
    while (( ${#_IMPORT_POOL_PIDS[@]} >= MAX_IMPORT_JOBS )); do
        _import_pool_drain_one
    done
    "${SCRIPT_DIR}/import.sh" "$src" "$label" "$root" &
    local pid=$!
    _IMPORT_POOL_PIDS+=("$pid")
    CHILD_PIDS+=" $pid"
}

# Wait for all tracked background jobs; reset pool.
wait_all() {
    # shellcheck disable=SC2086
    [[ -n "$CHILD_PIDS" ]] && wait $CHILD_PIDS || true
    CHILD_PIDS=""
    _IMPORT_POOL_PIDS=()
}

# ---------------------------------------------------------------------------
# Clear logs
# ---------------------------------------------------------------------------
mkdir -p "${LOG_ARCHIVE_DIR}" 2>/dev/null || true
# Rotate the previous run's tagged logs (keep one quick-reference backup of each)
# so "any failures this run?" checks only see the current run, not stale warnings.
# Full per-run history (every line, tagged + untagged) lives in the timestamped
# LOG_ARCHIVE_DIR/sync-*.log files written by the auto-tee above; those are the
# durable record for post-run analysis. import.log is rotated to .1 instead of
# being truncated with no backup. Workers append to the fresh files.
[[ -f "${IMPORT_LOG}" ]] && mv -f "${IMPORT_LOG}" "${IMPORT_LOG}.1" 2>/dev/null || true
[[ -f "${SYNC_LOG}"   ]] && mv -f "${SYNC_LOG}"   "${SYNC_LOG}.1"   2>/dev/null || true
: > "${IMPORT_LOG}"
# Prune the timestamped full-run archives to the most recent LOG_KEEP. ls -1t is
# newest-first; tail drops everything past the keep count. Plain pipe, no process
# substitution (bash 3.2 safe). The current run's log is newest, so never pruned.
_run_logs="$(ls -1t "${LOG_ARCHIVE_DIR}"/sync-*.log 2>/dev/null || true)"
if [[ -n "$_run_logs" ]]; then
    printf '%s\n' "$_run_logs" | tail -n +"$(( ${LOG_KEEP:-10} + 1 ))" | while IFS= read -r _old; do
        [[ -n "$_old" ]] && rm -f "$_old" 2>/dev/null || true
    done
fi
unset _run_logs
# backup.log is managed by backup.sh; sync.sh does not run backup, so leave it alone.
echo "[INFO] sync.sh started at $(date)" | tee -a "${SYNC_LOG}"

# ---------------------------------------------------------------------------
# Stage 1 — Camera import (LUMIX → desktop + portable photos)
# ---------------------------------------------------------------------------
if stage_enabled camera; then
    # Phase 1 — MOVE: every original in UNSORTED/CAMERA goes into the camera library
    # (${MEDIA_PATH}/CAMERA, at the drive root) — verified, never overwritten — and is
    # removed from UNSORTED. Nothing runs when the camera library is not mounted, so
    # nothing is ever written to a stray local folder.
    if ! camera_library_ready; then
        echo "[ERROR] Camera library is not available: $DESKTOP_CAMERA_ROOT" | tee -a "${SYNC_LOG}"
        echo "        Mount it (e.g. sudo systemctl restart router-smb.service) and run again. Camera stage skipped." | tee -a "${SYNC_LOG}"
    else
    echo "[STAGE 1a] Camera: move UNSORTED → camera library: ${CAMERA_SOURCE}" | tee -a "${SYNC_LOG}"
    if [[ -d "$CAMERA_SOURCE" ]]; then
        for cam_dir in "${CAMERA_SOURCE}"/*/; do
            [[ -d "$cam_dir" ]] || continue
            CAMERA_PHASE=archive run_import_bg "$cam_dir" "$(basename "$cam_dir")" "${DESKTOP_PHOTOS_ROOT}"
        done
        wait_all
    else
        echo "[WARN] Camera source not mounted: $CAMERA_SOURCE" | tee -a "${SYNC_LOG}"
    fi
    # Phase 2 — desktop photos/videos are built from the camera library, only the
    # files that do not have their outputs yet.
    echo "[STAGE 1b] Camera: build desktop from the camera library: ${DESKTOP_CAMERA_ROOT}" | tee -a "${SYNC_LOG}"
    if [[ -d "$DESKTOP_CAMERA_ROOT" ]]; then
        CAMERA_PHASE=build ENABLE_PORTABLE=0 run_import_bg "$DESKTOP_CAMERA_ROOT" "camera" "${DESKTOP_PHOTOS_ROOT}"
        wait_all
    else
        echo "[WARN] Camera library not mounted: $DESKTOP_CAMERA_ROOT" | tee -a "${SYNC_LOG}"
    fi
    # Phase 3 — portable is derived from the desktop output.
    if [[ "${ENABLE_PORTABLE:-1}" == "1" ]]; then
        echo "[STAGE 1c] Camera: derive portable from desktop" | tee -a "${SYNC_LOG}"
        "${SCRIPT_DIR}/portablize.sh" photo "${DESKTOP_PHOTOS_ROOT}" "${PORTABLE_PHOTOS_ROOT}" || true
    fi
    fi
else
    echo "[STAGE 1] Camera — skipped" | tee -a "${SYNC_LOG}"
fi

# ---------------------------------------------------------------------------
# Stage 2 — Downloads / Inbox import
# ---------------------------------------------------------------------------
if stage_enabled downloads; then
    echo "[STAGE 2] Inbox import: ${DOWNLOADS_SOURCE}" | tee -a "${SYNC_LOG}"
    if [[ -d "$DOWNLOADS_SOURCE" ]]; then
        for inbox_dir in "${DOWNLOADS_SOURCE}"/*/; do
            [[ -d "$inbox_dir" ]] || continue
            run_import_bg "$inbox_dir" "$(basename "$inbox_dir")" "${DESKTOP_MOVIES_ROOT}"
        done
        wait_all
    else
        echo "[WARN] Inbox source not mounted: $DOWNLOADS_SOURCE" | tee -a "${SYNC_LOG}"
    fi
else
    echo "[STAGE 2] Downloads — skipped" | tee -a "${SYNC_LOG}"
fi

# ---------------------------------------------------------------------------
# Stage 3 — Music import (album folders in parallel)
# ---------------------------------------------------------------------------
if stage_enabled music; then
    echo "[STAGE 3] Music import: ${MUSIC_SOURCE}" | tee -a "${SYNC_LOG}"
    if [[ -d "$MUSIC_SOURCE" ]]; then
        for album_dir in "${MUSIC_SOURCE}"/*/; do
            [[ -d "$album_dir" ]] || continue
            run_import_bg "$album_dir" "$(basename "$album_dir")" "${DESKTOP_MUSIC_ROOT}"
        done
        wait_all
    else
        echo "[WARN] Music source not mounted: $MUSIC_SOURCE" | tee -a "${SYNC_LOG}"
    fi
else
    echo "[STAGE 3] Music — skipped" | tee -a "${SYNC_LOG}"
fi

# ---------------------------------------------------------------------------
# Stage 3a — Derive portable music (m4a) FROM the desktop FLAC tier
# ---------------------------------------------------------------------------
if stage_enabled music && [[ "${ENABLE_PORTABLE:-1}" == "1" ]]; then
    echo "[STAGE 3a] Deriving portable music from desktop" | tee -a "${SYNC_LOG}"
    "${SCRIPT_DIR}/portablize.sh" audio "${DESKTOP_MUSIC_ROOT}" "${PORTABLE_MUSIC_ROOT}" || true
fi

# ---------------------------------------------------------------------------
# Stage 3b — Music playlists (per-album + per-artist M3U8, both tiers)
# ---------------------------------------------------------------------------
if stage_enabled music && [[ "${PLAYLIST_ENABLED:-1}" == "1" ]]; then
    echo "[STAGE 3b] Generating music playlists" | tee -a "${SYNC_LOG}"
    source "${SCRIPT_DIR}/playlist.sh"
    generate_music_playlists "${DESKTOP_MUSIC_ROOT}"  "flac" 2>&1 | tee -a "${SYNC_LOG}" || true
    generate_music_playlists "${PORTABLE_MUSIC_ROOT}" "m4a"  2>&1 | tee -a "${SYNC_LOG}" || true
fi

# ---------------------------------------------------------------------------
# Stage 4 — Movies import
# ---------------------------------------------------------------------------
if stage_enabled movies; then
    echo "[STAGE 4] Movies import: ${MOVIES_SOURCE}" | tee -a "${SYNC_LOG}"
    if [[ -d "$MOVIES_SOURCE" ]]; then
        for movie_dir in "${MOVIES_SOURCE}"/*/; do
            [[ -d "$movie_dir" ]] || continue
            run_import_bg "$movie_dir" "$(basename "$movie_dir")" "${DESKTOP_MOVIES_ROOT}"
        done
        wait_all
    else
        echo "[WARN] Movies source not mounted: $MOVIES_SOURCE" | tee -a "${SYNC_LOG}"
    fi
    if [[ "${ENABLE_PORTABLE:-1}" == "1" ]]; then
        echo "[STAGE 4b] Deriving movie portables from desktop" | tee -a "${SYNC_LOG}"
        "${SCRIPT_DIR}/portablize.sh" video "${DESKTOP_MOVIES_ROOT}" "${PORTABLE_MOVIES_ROOT}" || true
    fi
else
    echo "[STAGE 4] Movies — skipped" | tee -a "${SYNC_LOG}"
fi

# ---------------------------------------------------------------------------
# Stage 5 — TV Shows import
# ---------------------------------------------------------------------------
if stage_enabled tv; then
    echo "[STAGE 5] TV import: ${TV_SOURCE}" | tee -a "${SYNC_LOG}"
    if [[ -d "$TV_SOURCE" ]]; then
        for show_dir in "${TV_SOURCE}"/*/; do
            [[ -d "$show_dir" ]] || continue
            run_import_bg "$show_dir" "$(basename "$show_dir")" "${DESKTOP_TV_ROOT}"
        done
        wait_all
    else
        echo "[WARN] TV source not mounted: $TV_SOURCE" | tee -a "${SYNC_LOG}"
    fi
    if [[ "${ENABLE_PORTABLE:-1}" == "1" ]]; then
        echo "[STAGE 5b] Deriving TV portables from desktop" | tee -a "${SYNC_LOG}"
        "${SCRIPT_DIR}/portablize.sh" video "${DESKTOP_TV_ROOT}" "${PORTABLE_TV_ROOT}" || true
    fi
else
    echo "[STAGE 5] TV — skipped" | tee -a "${SYNC_LOG}"
fi

# ---------------------------------------------------------------------------
# Stage 6 — Photos from source PHOTOS directory
# ---------------------------------------------------------------------------
if stage_enabled photos; then
    echo "[STAGE 6] Photos import: ${PHOTOS_SOURCE}" | tee -a "${SYNC_LOG}"
    if [[ -d "$PHOTOS_SOURCE" ]]; then
        for photo_dir in "${PHOTOS_SOURCE}"/*/; do
            [[ -d "$photo_dir" ]] || continue
            run_import_bg "$photo_dir" "$(basename "$photo_dir")" "${DESKTOP_PHOTOS_ROOT}"
        done
        wait_all
    else
        echo "[WARN] Photos source not mounted: $PHOTOS_SOURCE" | tee -a "${SYNC_LOG}"
    fi
    if [[ "${ENABLE_PORTABLE:-1}" == "1" ]]; then
        echo "[STAGE 6b] Deriving photo portables from desktop" | tee -a "${SYNC_LOG}"
        "${SCRIPT_DIR}/portablize.sh" photo "${DESKTOP_PHOTOS_ROOT}" "${PORTABLE_PHOTOS_ROOT}" || true
    fi
else
    echo "[STAGE 6] Photos — skipped" | tee -a "${SYNC_LOG}"
fi

# ---------------------------------------------------------------------------
# Stage 7 — Cleanup staging dirs and empty source dirs
# ---------------------------------------------------------------------------
echo "[STAGE 7] Cleanup" | tee -a "${SYNC_LOG}"

# Remove .syncing temp directories from all library roots
for lib_root in \
    "${DESKTOP_MUSIC_ROOT}" "${DESKTOP_MOVIES_ROOT}" "${DESKTOP_TV_ROOT}" "${DESKTOP_PHOTOS_ROOT}" \
    "${PORTABLE_MUSIC_ROOT}" "${PORTABLE_MOVIES_ROOT}" "${PORTABLE_TV_ROOT}" "${PORTABLE_PHOTOS_ROOT}"; do
    if [[ -d "$lib_root" ]]; then
        find "$lib_root" -type d -name "${STAGING_SUFFIX}" -exec rm -rf {} + 2>/dev/null || true
    fi
done

# Remove empty source directories after import (only when DELETE_AFTER_IMPORT=1).
# A directory is considered empty if it contains only noise files
# (.DS_Store, Thumbs.db, desktop.ini, etc.) and no real content.
# Noise files are removed first so they don't block empty-dir detection,
# but only from directories that would otherwise be empty.
if [[ "${DELETE_AFTER_IMPORT:-1}" == "1" ]]; then
for src_root in \
    "${CAMERA_SOURCE}" "${MUSIC_SOURCE}" "${MOVIES_SOURCE}" "${TV_SOURCE}" "${PHOTOS_SOURCE}" \
    "${DOWNLOADS_SOURCE}" "${VIDEO_SOURCE}"; do
    [[ -d "$src_root" ]] || continue
    # Remove noise files only inside dirs that contain nothing else
    find "$src_root" -mindepth 1 -depth -type d | while IFS= read -r dir; do
        real_files=$(find "$dir" -maxdepth 1 -mindepth 1 -type f \
            ! -name ".DS_Store" ! -name "Thumbs.db" ! -name "desktop.ini" \
            ! -name ".Spotlight-V100" ! -name ".Trashes" ! -name ".fseventsd" \
            ! -name ".TemporaryItems" ! -name ".localized" 2>/dev/null | wc -l | tr -d ' ')
        subdirs=$(find "$dir" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
        if [[ "$real_files" -eq 0 && "$subdirs" -eq 0 ]]; then
            find "$dir" -maxdepth 1 -mindepth 1 -type f -delete 2>/dev/null || true
            rmdir "$dir" 2>/dev/null || true
        fi
    done
done
fi | tee -a "${SYNC_LOG}"
