#!/usr/bin/env bash
# portablize.sh — derive the PORTABLE library tier FROM the finished DESKTOP tier.
#
# New architecture (2026-08): the portable copy is never re-encoded from the
# original UNSORTED source. It is transcoded from the already-produced desktop
# output, and its metadata + cover art are COPIED from the desktop side instead
# of being fetched from the network a second time. This walks a desktop library
# root and creates every missing (or broken) portable counterpart.
#
# Usage (dispatcher — walks a whole desktop root):
#   ./portablize.sh <kind> <desktopRoot> <portableRoot>
#     <kind> = video | audio | photo
#
# Usage (single file — internal, spawned per file so each gets a unique PID for
# staging isolation):
#   ./portablize.sh one <kind> <desktopFile> <desktopRoot> <portableRoot>

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.sh"
source "${SCRIPT_DIR}/metadata.sh"
source "${SCRIPT_DIR}/convert.sh"

# ---------------------------------------------------------------------------
# Single-file workers
# ---------------------------------------------------------------------------

# Map a desktop path to its portable sibling directory (swap the tier root).
_portable_dir_for() {
    local desktop_dir="$1"
    printf '%s' "${desktop_dir/LIBRARY.DESKTOP/LIBRARY.PORTABLE}"
}

# Derive one portable VIDEO (.m4v) from a finished desktop .m4v.
portablize_one_video() {
    local desktop_file="$1"
    local desktop_dir portable_dir dbase stem base pbase portable_file
    desktop_dir="$(dirname "$desktop_file")"
    portable_dir="$(_portable_dir_for "$desktop_dir")"
    dbase="$(basename "$desktop_file")"
    stem="${dbase%.*}"
    # Desktop names carry a resolution suffix, e.g. "Title (Year) [4K]".
    # Portable is always the SD variant: replace the trailing " [label]" with " [SD]".
    base="$(printf '%s' "$stem" | sed -E 's/ \[[^][]*\]$//')"
    pbase="${base} [SD]"
    portable_file="${portable_dir}/${pbase}.m4v"

    if [[ "${SKIP_IF_EXISTS:-1}" == "1" ]] && media_file_valid "$portable_file"; then
        echo "[SKIP] Portable present: ${pbase}.m4v" >&2
        return 0
    fi
    validate_output_or_remove "$portable_file" || true   # broken → removed, rebuild below
    mkdir -p "$portable_dir"

    # Copy metadata from the desktop output (no network lookup).
    unset VIDEO_TITLE VIDEO_YEAR VIDEO_GENRE VIDEO_DESC VIDEO_TVSHOW VIDEO_SEASON VIDEO_EPISODE
    eval "$(read_video_tags "$desktop_file")" 2>/dev/null || true

    echo "[START] Portable from desktop: ${pbase}.m4v" >&2
    convertToPortableMp4 "$desktop_file" "$portable_file" || { echo "[WARN] Portable MP4 failed: $dbase" >&2; return 1; }
    validate_output_or_remove "$portable_file" || { echo "[WARN] Portable MP4 broken (removed): $dbase" >&2; return 1; }

    # Poster: reuse the desktop sidecar (poster.jpg, else <stem>.jpg, else embedded art).
    local poster="${desktop_dir}/poster.jpg"
    [[ -f "$poster" ]] || poster="${desktop_dir}/${stem}.jpg"
    if [[ ! -f "$poster" ]]; then
        local _nv
        _nv=$(ffprobe -v error -select_streams v -show_entries stream=index \
            -of csv=p=0 "$desktop_file" 2>/dev/null | wc -l | tr -d ' ') || _nv=0
        if (( ${_nv:-0} > 1 )); then
            poster="${portable_dir}/.poster_from_desktop.jpg"
            ffmpeg -nostdin -v error -i "$desktop_file" -map 0:v:1 -vframes 1 "$poster" 2>/dev/null || poster=""
        else
            poster=""
        fi
    fi

    embed_video_meta "$portable_file" "$poster" "portable" || \
        echo "[WARN] Portable metadata embed failed (non-fatal): $portable_file" >&2

    # Portable sidecar poster.jpg (scaled to the video frame) + Walkman thumbnail.
    if [[ -n "$poster" && -f "$poster" && ! -f "${portable_dir}/poster.jpg" ]]; then
        local _pw="${PORTABLE_VIDEO_WIDTH:-320}" _ph="${PORTABLE_VIDEO_HEIGHT:-240}"
        "${FFMPEG_BIN:-ffmpeg}" -nostdin -y -v error -i "$poster" \
            -vf "scale=${_pw}:${_ph}:force_original_aspect_ratio=decrease" \
            -q:v 3 "${portable_dir}/poster.jpg" 2>/dev/null || cp "$poster" "${portable_dir}/poster.jpg"
    fi
    if [[ "${PORTABLE_VIDEO_SIDECAR_THUMB:-1}" == "1" && -n "$poster" && -f "$poster" && ! -f "${portable_dir}/${pbase}.jpg" ]]; then
        local _tw="${PORTABLE_VIDEO_SIDECAR_THUMB_WIDTH:-240}" _th="${PORTABLE_VIDEO_SIDECAR_THUMB_HEIGHT:-320}"
        "${FFMPEG_BIN:-ffmpeg}" -nostdin -y -v error -i "$poster" \
            -vf "scale=${_tw}:${_th}:force_original_aspect_ratio=decrease" \
            -q:v 3 "${portable_dir}/${pbase}.jpg" 2>/dev/null || true
    fi
    rm -f "${portable_dir}/.poster_from_desktop.jpg" 2>/dev/null || true

    echo "[DONE] Portable derived: ${pbase}.m4v" >&2
}

# Derive one portable camera VIDEO (.m4v, flat date folder — same base name).
portablize_one_camera_video() {
    local desktop_file="$1"
    local desktop_dir portable_dir dbase portable_file
    desktop_dir="$(dirname "$desktop_file")"
    portable_dir="$(_portable_dir_for "$desktop_dir")"
    dbase="$(basename "$desktop_file")"
    portable_file="${portable_dir}/${dbase}"

    if [[ "${SKIP_IF_EXISTS:-1}" == "1" ]] && media_file_valid "$portable_file"; then
        echo "[SKIP] Portable present: ${dbase}" >&2
        return 0
    fi
    validate_output_or_remove "$portable_file" || true
    mkdir -p "$portable_dir"

    echo "[START] Portable from desktop: ${dbase}" >&2
    convertToPortableMp4 "$desktop_file" "$portable_file" || { echo "[WARN] Portable MP4 failed: $dbase" >&2; return 1; }
    validate_output_or_remove "$portable_file" || { echo "[WARN] Portable MP4 broken (removed): $dbase" >&2; return 1; }

    # Copy camera metadata (EXIF/QuickTime) from the desktop output.
    exiftool -m -overwrite_original \
        -TagsFromFile "$desktop_file" \
        -QuickTime:all \
        -EXIF:all \
        "-Keys:Make<Make" \
        "-Keys:Model<Model" \
        "-Keys:CreationDate<CreateDate" \
        "-QuickTime:Make<Make" \
        "-QuickTime:Model<Model" \
        "$portable_file" 2>/dev/null || true

    echo "[DONE] Portable derived: ${dbase}" >&2
}

# Derive one portable AUDIO (.m4a) from a finished desktop .flac.
portablize_one_audio() {
    local desktop_file="$1"
    local desktop_dir portable_dir stem portable_file
    desktop_dir="$(dirname "$desktop_file")"
    portable_dir="$(_portable_dir_for "$desktop_dir")"
    stem="$(basename "${desktop_file%.*}")"
    portable_file="${portable_dir}/${stem}.m4a"

    if [[ "${SKIP_IF_EXISTS:-1}" == "1" ]] && media_file_valid "$portable_file"; then
        echo "[SKIP] Portable present: ${stem}.m4a" >&2
        return 0
    fi
    validate_output_or_remove "$portable_file" || true
    mkdir -p "$portable_dir"

    unset AUDIO_TITLE AUDIO_ARTIST AUDIO_ALBUM_ARTIST AUDIO_ALBUM AUDIO_YEAR AUDIO_TRACK AUDIO_DISC AUDIO_GENRE
    eval "$(read_audio_tags "$desktop_file")" 2>/dev/null || true

    echo "[START] Portable from desktop: ${stem}.m4a" >&2
    convertToAac "$desktop_file" "$portable_file" || { echo "[WARN] Portable AAC failed: $(basename "$desktop_file")" >&2; return 1; }
    validate_output_or_remove "$portable_file" || { echo "[WARN] Portable AAC broken (removed): $(basename "$desktop_file")" >&2; return 1; }

    local cover="${desktop_dir}/cover.jpg"
    embed_audio_meta "$portable_file" "$cover" || echo "[WARN] Portable audio tag embed failed (non-fatal): $portable_file" >&2
    [[ -f "$cover" && ! -f "${portable_dir}/cover.jpg" ]] && cp -n "$cover" "${portable_dir}/cover.jpg"

    echo "[DONE] Portable derived: ${stem}.m4a" >&2
}

# Derive one portable PHOTO (.jpg) from a finished desktop .jpg.
portablize_one_photo() {
    local desktop_file="$1"
    local desktop_dir portable_dir dbase portable_file
    desktop_dir="$(dirname "$desktop_file")"
    portable_dir="$(_portable_dir_for "$desktop_dir")"
    dbase="$(basename "$desktop_file")"
    portable_file="${portable_dir}/${dbase}"

    if [[ "${SKIP_IF_EXISTS:-1}" == "1" ]] && media_file_valid "$portable_file"; then
        echo "[SKIP] Portable present: ${dbase}" >&2
        return 0
    fi
    validate_output_or_remove "$portable_file" || true
    mkdir -p "$portable_dir"

    echo "[START] Portable from desktop: ${dbase}" >&2
    # convertToPortableJpeg re-imports all EXIF from its input (the desktop JPEG),
    # so the portable inherits the desktop's metadata directly.
    convertToPortableJpeg "$desktop_file" "$portable_file" || { echo "[WARN] Portable JPEG failed: $dbase" >&2; return 1; }
    validate_output_or_remove "$portable_file" || { echo "[WARN] Portable JPEG broken (removed): $dbase" >&2; return 1; }

    local cover="${desktop_dir}/cover.jpg"
    [[ -f "$cover" && ! -f "${portable_dir}/cover.jpg" ]] && cp -n "$cover" "${portable_dir}/cover.jpg"

    echo "[DONE] Portable derived: ${dbase}" >&2
}

# ---------------------------------------------------------------------------
# Single-file entry point (spawned per file → unique PID for staging isolation)
# ---------------------------------------------------------------------------
if [[ "${1:-}" == "one" ]]; then
    _kind="$2"; _file="$3"
    [[ -f "$_file" ]] || { echo "[ERROR] Desktop file not found: $_file" >&2; exit 1; }
    if ! media_file_valid "$_file"; then
        echo "[ERROR] Broken/unreadable DESKTOP file — cannot derive portable: $_file" >&2
        exit 1
    fi
    _ext="${_file##*.}"; _ext="$(tr '[:upper:]' '[:lower:]' <<< "$_ext")"
    case "$_kind" in
        video) portablize_one_video "$_file" ;;
        audio) portablize_one_audio "$_file" ;;
        photo)
            case "$_ext" in
                m4v|mp4|mov) portablize_one_camera_video "$_file" ;;
                *)           portablize_one_photo "$_file" ;;
            esac
            ;;
        *) echo "[ERROR] Unknown portablize kind: $_kind" >&2; exit 1 ;;
    esac
    exit $?
fi

# ---------------------------------------------------------------------------
# Dispatcher — walk a desktop root and derive every portable counterpart
# ---------------------------------------------------------------------------
KIND="${1:-}"
DESKTOP_ROOT="${2:-}"
PORTABLE_ROOT="${3:-}"

if [[ -z "$KIND" || -z "$DESKTOP_ROOT" || -z "$PORTABLE_ROOT" ]]; then
    echo "Usage: $0 <video|audio|photo> <desktopRoot> <portableRoot>" >&2
    exit 1
fi
if [[ ! -d "$DESKTOP_ROOT" ]]; then
    echo "[INFO] Desktop root absent, nothing to derive: $DESKTOP_ROOT" >&2
    exit 0
fi

# Which files to walk for each kind.
case "$KIND" in
    video) _find_expr=(-type f -iname '*.m4v') ;;
    audio) _find_expr=(-type f -iname '*.flac') ;;
    photo) _find_expr=(-type f \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.m4v' \)
            # exclude album/poster sidecars and per-file thumbs
            ) ;;
    *) echo "[ERROR] Unknown kind: $KIND" >&2; exit 1 ;;
esac

# Video portable encodes are heavy (a 4K→QVGA baseline encode runs for a long
# time); run them one at a time so several hours-long ffmpeg jobs never
# oversubscribe the CPU. Light photo/audio jobs run up to MAX_PARALLEL_JOBS.
if [[ "$KIND" == "video" ]]; then
    _max_jobs=1
else
    _max_jobs="${MAX_PARALLEL_JOBS:-2}"
fi

echo "[INFO] Deriving ${KIND} portables from: ${DESKTOP_ROOT}  (max ${_max_jobs} parallel)" >&2

_list="$(mktemp /tmp/portablize_XXXXXX)"
find "$DESKTOP_ROOT" "${_find_expr[@]}" -print0 > "$_list"

_pids=()
_total=0
while IFS= read -r -d '' _f; do
    _bn="$(basename "$_f")"
    # Skip sidecar art that lives alongside real media.
    case "$_bn" in
        cover.jpg|poster.jpg) continue ;;
        *.thumb.jpg) continue ;;
    esac
    # For photo kind, skip the per-video sidecar jpgs (named after an .m4v).
    if [[ "$KIND" == "photo" && "$_bn" == *.jpg ]]; then
        _stem="${_bn%.jpg}"
        [[ -f "$(dirname "$_f")/${_stem}.m4v" ]] && continue
    fi

    "${SCRIPT_DIR}/portablize.sh" one "$KIND" "$_f" "$DESKTOP_ROOT" "$PORTABLE_ROOT" < /dev/null &
    _pids+=("$!")
    (( _total++ )) || true

    if (( ${#_pids[@]} >= _max_jobs )); then
        wait "${_pids[0]}" 2>/dev/null || true
        _pids=("${_pids[@]:1}")
    fi
done < "$_list"
rm -f "$_list"

for _p in ${_pids[@]+"${_pids[@]}"}; do
    wait "$_p" 2>/dev/null || true
done

echo "[INFO] Portable derivation complete for ${KIND}: scanned ${_total} desktop file(s) under ${DESKTOP_ROOT}" >&2
