#!/usr/bin/env bash
# import.sh — import driver: walk a source directory and organize each file
#
# Usage:
#   ./import.sh <sourceDir> <folderLabel> <mediaRootDir>

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.sh"
source "${SCRIPT_DIR}/metadata.sh"

SOURCE_DIR="$1"
FOLDER_LABEL="${2:-misc}"
MEDIA_ROOT="$3"

if [[ ! -d "$SOURCE_DIR" ]]; then
    echo "[ERROR] Source directory not found: $SOURCE_DIR" >&2
    exit 1
fi

echo "[INFO] Importing from: $SOURCE_DIR  label=$FOLDER_LABEL  root=$MEDIA_ROOT  started=$(date)" | tee -a "${IMPORT_LOG}" >&2
debug_log "import.sh: max parallel jobs = $MAX_PARALLEL_JOBS"

# Create a temp dir to hold per-album context files (one .sh + one tracklist JSON per album).
# Exported so every background orginize.sh subprocess can source its album's context file.
ALBUM_CTX_DIR=$(mktemp -d /tmp/album_ctx_XXXXXX)
export ALBUM_CTX_DIR

# Clean up the entire context directory when this import job exits.
_cleanup_album_ctx() {
    [[ -n "${ALBUM_CTX_DIR:-}" && -d "${ALBUM_CTX_DIR}" ]] && rm -rf "${ALBUM_CTX_DIR}"
}
trap _cleanup_album_ctx EXIT

# Discover every unique immediate-parent directory of audio files in SOURCE_DIR.
# Each such directory is treated as one album and gets its own context query.
# We collect paths via a temp file to avoid running fetch_album_meta_for_folder
# in a subshell (which would lose the written ctx files … well, ctx_dir is a
# real path, so a subshell is fine here).
echo "[INFO] Scanning album directories under: $SOURCE_DIR" >&2
_album_dirs_file=$(mktemp /tmp/album_dirs_XXXXXX)
find "$SOURCE_DIR" -maxdepth 8 -type f \
    \( -iname '*.flac' -o -iname '*.m4a' -o -iname '*.mp3' \
       -o -iname '*.aac' -o -iname '*.wav' -o -iname '*.ogg' \) \
    -print | while IFS= read -r f; do dirname "$f"; done \
    | sort -u > "$_album_dirs_file"

while IFS= read -r _album_dir; do
    [[ -z "$_album_dir" ]] && continue
    echo "[INFO] Building album context for: $_album_dir" >&2
    # Resilient: a per-album metadata fetch (AcoustID fingerprint, MusicBrainz
    # lookup — both network-dependent and nondeterministic) must never abort the
    # whole import. On failure we simply skip the album context; orginize.sh then
    # falls back to the file's embedded tags + folder-name parsing.
    if ! fetch_album_meta_for_folder "$_album_dir" "$(basename "$_album_dir")" "$ALBUM_CTX_DIR"; then
        log_warn "Album context unavailable, using embedded tags: $_album_dir"
    fi
    # When no MusicBrainz match was found, derive ONE consensus album/year from the
    # folder's embedded tags so every track lands in the SAME album folder (prevents
    # per-track year scatter for year-less folders, e.g. rarities compilations).
    ensure_album_ctx_fallback "$_album_dir" "$ALBUM_CTX_DIR"
done < "$_album_dirs_file"
rm -f "$_album_dirs_file"

fail_count=0
job_count=0
_err_tmp=""
declare -a pids=()
declare -a pids_files=()   # parallel to pids — maps each PID to its source file
declare -a pids_errs=()    # parallel to pids — per-job stderr capture files
declare -a retry_files=()  # files that failed in parallel phase; retried sequentially

# Walk source up to depth 8.
# Materialize the find results into a temp file FIRST, then read from it.
# Bash 3.2.57 (Apple's /bin/bash) corrupts the heap when a long-running loop
# body (spawning ffmpeg/exiftool children) reads from a process-substitution
# pipe `< <(find ...)` — the loop aborts nondeterministically mid-walk. Reading
# from a plain file (as the album-dir loop above already does) is crash-safe.
_files_list="$(mktemp /tmp/import_files_XXXXXX)"
find "$SOURCE_DIR" -maxdepth 8 -type f -print0 > "$_files_list"

# Camera build phase: the source is the camera archive. Skip files whose desktop
# (and portable, when enabled) output already exists, and publish progress for the UI.
BUILD_PROGRESS_FILE="${BUILD_PROGRESS_FILE:-${SCRIPT_DIR}/logs/.camera-build-progress}"
_bp_done=0; _bp_total=0
write_build_progress() {
    [[ "${CAMERA_PHASE:-}" == "build" ]] || return 0
    printf '%s %s\n' "$_bp_done" "$_bp_total" > "${BUILD_PROGRESS_FILE}.tmp" 2>/dev/null \
        && mv -f "${BUILD_PROGRESS_FILE}.tmp" "$BUILD_PROGRESS_FILE" 2>/dev/null || true
}
camera_build_done() {
    local f="$1" rel d base ext out
    rel="${f#"${DESKTOP_CAMERA_ROOT%/}"/}"
    [[ "$rel" =~ ^([0-9]{4})/([0-9]{2})/([0-9]{2})/([^/]+)$ ]] || return 1
    d="${BASH_REMATCH[1]}-${BASH_REMATCH[2]}-${BASH_REMATCH[3]}"
    base="${BASH_REMATCH[4]%.*}"; ext="$(tr '[:upper:]' '[:lower:]' <<< "${BASH_REMATCH[4]##*.}")"
    case "$ext" in
        mp4|mov|avi|mkv|m4v|3gp|3g2|mts|m2ts|ts) out="${base}.m4v" ;;
        *) out="${base}.jpg" ;;
    esac
    [[ "${ENABLE_DESKTOP:-1}"  != "1" || -s "${DESKTOP_PHOTOS_ROOT}/${d}/${out}"  ]] || return 1
    [[ "${ENABLE_PORTABLE:-1}" != "1" || -s "${PORTABLE_PHOTOS_ROOT}/${d}/${out}" ]] || return 1
    return 0
}
if [[ "${CAMERA_PHASE:-}" == "build" ]]; then
    _all=0; _todo_list="$(mktemp /tmp/import_todo_XXXXXX)"
    while IFS= read -r -d '' _f; do
        [[ "$(basename "$_f")" == .* ]] && continue
        _all=$(( _all + 1 ))
        camera_build_done "$_f" || printf '%s\0' "$_f" >> "$_todo_list"
    done < "$_files_list"
    mv -f "$_todo_list" "$_files_list"
    _bp_total=$(tr -cd '\0' < "$_files_list" | wc -c | tr -d ' ')
    echo "[INFO] Camera build: ${_bp_total} to build, $(( _all - _bp_total )) already built (of ${_all} archived)" | tee -a "${IMPORT_LOG}" >&2
    write_build_progress
fi

while IFS= read -r -d '' file; do
    # Skip hidden files and staging temp files
    [[ "$(basename "$file")" == .* ]] && continue
    [[ "$file" == *"${STAGING_SUFFIX}"* ]] && continue

    debug_log "Queuing: $file"

    # Capture stderr to a temp file so failures can be logged with their error output
    _err_tmp="$(mktemp /tmp/orginize_err_XXXXXX)"

    # Run organizer in background; stdout goes directly to terminal, stderr captured
    # < /dev/null: prevent background process (and its children, e.g. ffmpeg) from
    # accidentally consuming bytes from the parent while-loop's find -print0 pipe.
    "${SCRIPT_DIR}/orginize.sh" "$file" "$FOLDER_LABEL" "$MEDIA_ROOT" "$SOURCE_DIR" < /dev/null 2>>"$_err_tmp" &
    pids+=($!)
    pids_files+=("$file")
    pids_errs+=("$_err_tmp")
    (( job_count++ )) || true   # || true: (( )) returns 1 when expr=0 (post-inc from 0); safe with set -e

    # Throttle to MAX_PARALLEL_JOBS
    if (( job_count >= MAX_PARALLEL_JOBS )); then
        if ! wait "${pids[0]}"; then
            retry_files+=("${pids_files[0]}")
        fi
        _bp_done=$(( _bp_done + 1 )); write_build_progress
        drain_err_to_log "${pids_errs[0]}" "$(basename "${pids_files[0]}")"
        rm -f "${pids_errs[0]}"
        pids=("${pids[@]:1}")
        pids_files=("${pids_files[@]:1}")
        pids_errs=("${pids_errs[@]:1}")
        (( job_count-- )) || true
    fi
done < "$_files_list"
rm -f "$_files_list"

# Wait for remaining jobs
for _i in "${!pids[@]}"; do
    if ! wait "${pids[$_i]}"; then
        retry_files+=("${pids_files[$_i]}")
    fi
    _bp_done=$(( _bp_done + 1 )); write_build_progress
    drain_err_to_log "${pids_errs[$_i]}" "$(basename "${pids_files[$_i]}")"
    rm -f "${pids_errs[$_i]}"
done
unset _i

# Sequential retry for all files that failed during the parallel phase.
# Runs after ALL parallel jobs are done — no concurrent I/O on the USB drive —
# which clears the transient ENOENT errors caused by the exFAT driver under load.
if (( ${#retry_files[@]} > 0 )); then
    echo "[INFO] ${#retry_files[@]} file(s) failed during parallel phase; retrying sequentially..." | tee -a "${IMPORT_LOG}" >&2
    # Let the USB drive settle and force ExFAT directory cache refresh
    sleep 5
    for _retry_file in "${retry_files[@]}"; do
        # Re-read the parent directory to bust stale ExFAT directory cache entries
        ls "$(dirname "$_retry_file")" > /dev/null 2>&1 || true
        _retry_err="$(mktemp /tmp/orginize_err_XXXXXX)"
        if "${SCRIPT_DIR}/orginize.sh" "$_retry_file" "$FOLDER_LABEL" "$MEDIA_ROOT" "$SOURCE_DIR" 2>>"$_retry_err"; then
            echo "[INFO] Retry succeeded: $(basename "$_retry_file")" | tee -a "${IMPORT_LOG}" >&2
            # Surface any warnings emitted on the (now successful) retry.
            drain_err_to_log "$_retry_err" "$(basename "$_retry_file")"
        else
            fail_count=$(( fail_count + 1 ))
            log_error "Import failed after retry: $_retry_file" | tee -a "${IMPORT_LOG}" >/dev/null
            [[ -s "$_retry_err" ]] && cat "$_retry_err" | tee -a "${IMPORT_LOG}" >&2
            drain_err_to_log "$_retry_err" "$(basename "$_retry_file")"
        fi
        rm -f "$_retry_err"
    done
fi

echo "[INFO] Import complete: $SOURCE_DIR  finished=$(date)  failures=${fail_count}" | tee -a "${IMPORT_LOG}" >&2
if (( fail_count > 0 )); then
    log_warn "${fail_count} file(s) failed during import from: $SOURCE_DIR"
    echo "[WARN] ${fail_count} file(s) failed during import from: $SOURCE_DIR" | tee -a "${IMPORT_LOG}" >/dev/null
    exit 1
fi
