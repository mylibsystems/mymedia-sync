#!/usr/bin/env bash
# orginize.sh — per-file organizer: detects type, converts, moves to library
#
# Usage:
#   ./orginize.sh <filePath> <folderLabel> <mediaRootDir>

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.sh"
source "${SCRIPT_DIR}/metadata.sh"
source "${SCRIPT_DIR}/convert.sh"

FILE_PATH="$1"
FOLDER_LABEL="${2:-misc}"
MEDIA_ROOT="$3"    # library root, e.g. /Volumes/WD-ELEMENTS/LIBRARY.DESKTOP/MUSIC
SOURCE_ROOT="${4:-}"   # artist folder (import source root) for layout resolution

if [[ ! -f "$FILE_PATH" ]]; then
    echo "[ERROR] File not found: $FILE_PATH" >&2
    exit 1
fi

EXT="${FILE_PATH##*.}"
EXT_LOWER="$(tr '[:upper:]' '[:lower:]' <<< "$EXT")"

debug_log "Processing file: $FILE_PATH  ext=$EXT_LOWER  label=$FOLDER_LABEL  root=$MEDIA_ROOT"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Pad a number to 2 digits
# 10# prefix forces base-10 so leading-zero strings like "08"/"09" are not
# misinterpreted as invalid octal literals by bash's arithmetic evaluation.
pad2() { printf '%02d' "$((10#${1:-0}))"; }

# Truncate a string so its UTF-8 byte length does not exceed max_bytes, without
# splitting a multibyte character. The filesystem NAME_MAX is 255 *bytes* on
# APFS/exFAT/VFAT, so length must be measured in bytes (a 250-char Cyrillic
# string is 500 bytes and would still trigger ENAMETOOLONG / "File name too
# long"). Trailing spaces and dashes left by the cut are trimmed.
# Usage: safe="$(truncate_utf8 "$name" 240)"
truncate_utf8() {
    local s="$1" max="${2:-255}" cur
    cur=$(printf '%s' "$s" | wc -c | tr -d ' ')
    if (( cur <= max )); then
        printf '%s' "$s"
        return
    fi
    local out="" ch clen bytes=0 i len=${#s}
    for (( i = 0; i < len; i++ )); do
        ch="${s:i:1}"
        clen=$(printf '%s' "$ch" | wc -c | tr -d ' ')
        (( bytes + clen > max )) && break
        out+="$ch"
        (( bytes += clen ))
    done
    printf '%s' "$out" | sed 's/[[:space:]-]*$//'
}

# ---------------------------------------------------------------------------
# Sony Walkman NWZ-A720 compliance sanitizer for portable output paths.
# Spec constraints (from 41646131M.pdf), all tunable in config.sh:
#   - Folder depth: max PORTABLE_MAX_DEPTH levels from the MUSIC/VIDEO/PHOTOS root
#   - Filename component: max PORTABLE_FILENAME_MAX_CHARS chars (FAT32 LFN) — auto-truncated
#   - Total path length: max PORTABLE_PATH_MAX_CHARS chars (safe FAT32 threshold) — warned
#   - Extension: .m4a / .mp4 / .jpg only (device-supported formats)
# Truncates any over-long path component (preserving extension on the final
# component), warns on stderr for all violations, and echoes the (possibly
# corrected) destination path.
# Usage: portable_dest="$(walkman_sanitize_path <portable_root> <full_dest_path>)"
walkman_sanitize_path() {
    local root="$1"
    local dest="$2"
    local _max_depth="${PORTABLE_MAX_DEPTH:-8}"
    local _max_chars="${PORTABLE_FILENAME_MAX_CHARS:-255}"
    local _max_path="${PORTABLE_PATH_MAX_CHARS:-260}"

    # Depth check (cannot auto-fix folder layout)
    local rel="${dest#$root/}"
    local depth
    depth=$(echo "$rel" | tr '/' '\n' | wc -l | tr -d ' ')
    if (( depth > _max_depth )); then
        echo "[WARN] Sony Walkman: path exceeds ${_max_depth}-level depth (depth=$depth): $dest" >&2
    fi

    # Truncate each component to max PORTABLE_FILENAME_MAX_CHARS chars (FAT32 LFN limit)
    local components=() fixed_parts=()
    IFS='/' read -ra components <<< "$rel"
    local last_idx=$(( ${#components[@]} - 1 ))
    local i
    for (( i=0; i<${#components[@]}; i++ )); do
        local comp="${components[$i]}"
        if (( ${#comp} > _max_chars )); then
            if (( i == last_idx )); then
                # Final component: preserve extension
                local fext="${comp##*.}"
                local fstem="${comp%.*}"
                local max_stem=$(( _max_chars - ${#fext} - 1 ))
                echo "[WARN] Sony Walkman: filename truncated to ${_max_chars} chars: ${comp}" >&2
                comp="${fstem:0:$max_stem}.${fext}"
            else
                echo "[WARN] Sony Walkman: directory name truncated to ${_max_chars} chars: ${comp}" >&2
                comp="${comp:0:$_max_chars}"
            fi
        fi
        fixed_parts+=("$comp")
    done

    # Rebuild dest from root + (possibly truncated) relative path
    local fixed_rel
    fixed_rel="$(IFS='/'; echo "${fixed_parts[*]}")"
    dest="${root}/${fixed_rel}"

    # Total path length advisory (informational; cannot shrink without context)
    if (( ${#dest} > _max_path )); then
        echo "[WARN] Sony Walkman: total path still long (${#dest} chars): $dest" >&2
    fi

    # Extension check
    local ext="${dest##*.}"
    ext="$(echo "$ext" | tr '[:upper:]' '[:lower:]')"
    case "$ext" in
        m4a|m4v|mp4|mp3|jpg|jpeg) ;;
        *)
            echo "[WARN] Sony Walkman: unsupported file extension '.${ext}': $dest" >&2
            ;;
    esac

    echo "$dest"
}

# Unique destination path: if path exists, append _1, _2, ...
# Uses mkdir spin-lock (atomic on macOS/Linux) to prevent races between parallel jobs.
unique_dest() {
    local path="$1"
    local dir result
    dir="$(dirname "$path")"
    mkdir -p "$dir"
    local lock_dir="${dir}/.unique_dest.lock"
    # Spin-lock using mkdir (atomic on macOS/Linux)
    while ! mkdir "$lock_dir" 2>/dev/null; do sleep 0.05; done
    if [[ ! -e "$path" ]]; then
        result="$path"
    else
        local base ext i=1
        base="${path##*/}"; ext="${base##*.}"; base="${base%.*}"
        while [[ -e "${dir}/${base}_${i}.${ext}" ]]; do (( i++ )); done
        result="${dir}/${base}_${i}.${ext}"
    fi
    touch "$result"   # reserve the slot before releasing the lock
    rmdir "$lock_dir"
    echo "$result"
}

# Verify both desktop and portable outputs exist and are non-empty; return 0 on success
verify_outputs() {
    local desktop_out="$1"
    local portable_out="$2"
    if [[ "${ENABLE_DESKTOP:-1}" == "1" ]]; then
        [[ -f "$desktop_out"  && -s "$desktop_out"  ]] || { echo "[ERROR] Desktop output missing: $desktop_out" >&2;  return 1; }
    fi
    if [[ "${ENABLE_PORTABLE:-1}" == "1" ]]; then
        [[ -f "$portable_out" && -s "$portable_out" ]] || { echo "[ERROR] Portable output missing: $portable_out" >&2; return 1; }
    fi
    return 0
}

# True (0) if every ENABLED tier's output already exists and is non-empty.
# Used by incremental skip-detection so a disabled tier's missing output does
# not force needless re-encoding of the enabled tier.
outputs_present() {
    local desktop_out="$1"
    local portable_out="$2"
    if [[ "${ENABLE_DESKTOP:-1}" == "1" ]]; then
        [[ -f "$desktop_out"  && -s "$desktop_out"  ]] || return 1
    fi
    if [[ "${ENABLE_PORTABLE:-1}" == "1" ]]; then
        [[ -f "$portable_out" && -s "$portable_out" ]] || return 1
    fi
    return 0
}

# True (0) if an audio file already carries an embedded cover-art picture.
audio_has_embedded_art() {
    local f="$1"
    [[ -f "$f" ]] || return 1
    local c
    c="$(ffprobe -v error -select_streams v -show_entries stream=codec_name -of csv=p=0 "$f" 2>/dev/null)"
    [[ -n "$c" ]]
}

# Idempotently guarantee the present tier outputs carry embedded cover art.
# Runs on EVERY import pass BEFORE the skip-gate, so a track re-tried after a
# transient parallel-embed race still gets its art (mirrors the camera
# archive_camera_original pattern, which the skip-gate would otherwise bypass).
# No-op when the present outputs already have art; only then does it resolve the
# cover (reusing the cover.jpg sidecar, no needless network) and embed. Relies on
# AUDIO_* tags already populated by the caller.
ensure_audio_cover_embedded() {
    local src="$1" desktop_dest="$2" portable_dest="$3" desktop_dir="$4" portable_dir="$5"

    local need=()
    if [[ "${ENABLE_DESKTOP:-1}" == "1" && -f "$desktop_dest" ]] && ! audio_has_embedded_art "$desktop_dest"; then
        need+=("$desktop_dest")
    fi
    if [[ "${ENABLE_PORTABLE:-1}" == "1" && -f "$portable_dest" ]] && ! audio_has_embedded_art "$portable_dest"; then
        need+=("$portable_dest")
    fi
    if (( ${#need[@]} == 0 )); then return 0; fi

    local cover_path="${desktop_dir}/cover.jpg"
    # Reuse the sidecar; else extract embedded art from the source; else fetch online.
    if [[ ! -f "$cover_path" || ! -s "$cover_path" ]]; then
        ffmpeg -nostdin -y -i "$src" -map 0:v -map -0:V -vframes 1 "$cover_path" 2>/dev/null || true
    fi
    if [[ ! -f "$cover_path" || ! -s "$cover_path" ]]; then
        fetch_audio_cover "$cover_path"
    fi
    if [[ ! -f "$cover_path" || ! -s "$cover_path" ]]; then
        echo "[WARN] Missing cover art (none embedded in source or fetched online): $src" >&2
        return 0
    fi

    # Normalize to a baseline JPEG (metaflac/AtomicParsley reject PNG, progressive
    # JPEG, and alpha; source art and Last.fm both serve these) so the embed never
    # silently fails.
    local _cover_norm="${cover_path%.jpg}.__norm.jpg"
    if "${FFMPEG_BIN:-ffmpeg}" -nostdin -y -v error -i "$cover_path" \
            -map 0:v:0 -frames:v 1 -c:v mjpeg -pix_fmt yuvj420p "$_cover_norm" 2>/dev/null \
       && [[ -s "$_cover_norm" ]]; then
        mv -f "$_cover_norm" "$cover_path"
    else
        rm -f "$_cover_norm" 2>/dev/null || true
    fi

    local _f
    for _f in "${need[@]}"; do
        embed_audio_cover_only "$_f" "$cover_path" || echo "[WARN] Cover embed failed (non-fatal): $(basename "$_f")" >&2
    done

    if [[ -f "$cover_path" && ! -f "${portable_dir}/cover.jpg" ]]; then
        cp -n "$cover_path" "${portable_dir}/cover.jpg"
    fi
}

# Delete source file when DELETE_AFTER_IMPORT=1 (default).
# Called only after verify_outputs has confirmed both outputs are present, or
# when identical outputs were already in the library (skip path).
# _ARCHIVE_OK is set to 0 when a camera original could not be archived.
_ARCHIVE_OK=1

# Hard safety net: a file may only be deleted when it resolves to a path inside
# UNSORTED_ROOT and not inside any library root. Library files are never removed.
source_is_removable() {
    local src="$1" real unsorted root rroot
    [[ -n "${UNSORTED_ROOT:-}" && -f "$src" ]] || return 1
    real="$(realpath -- "$src" 2>/dev/null)" || return 1
    unsorted="$(realpath -- "$UNSORTED_ROOT" 2>/dev/null)" || return 1
    [[ -n "$unsorted" && "$unsorted" != "/" && "$real" == "$unsorted"/* ]] || return 1
    # Music and movie sources are never deleted.
    for root in "${MUSIC_SOURCE:-}" "${MOVIES_SOURCE:-}"; do
        [[ -n "$root" ]] || continue
        rroot="$(realpath -- "$root" 2>/dev/null)" || continue
        [[ "$real" == "$rroot"/* ]] && return 1
    done
    for root in \
        "${DESKTOP_MUSIC_ROOT:-}" "${DESKTOP_MOVIES_ROOT:-}" "${DESKTOP_TV_ROOT:-}" \
        "${DESKTOP_PHOTOS_ROOT:-}" "${DESKTOP_CAMERA_ROOT:-}" "${PORTABLE_MUSIC_ROOT:-}" \
        "${PORTABLE_MOVIES_ROOT:-}" "${PORTABLE_TV_ROOT:-}" "${PORTABLE_PHOTOS_ROOT:-}" \
        "${MEDIA_PATH:-}/LIBRARY.DESKTOP" "${MEDIA_PATH:-}/LIBRARY.PORTABLE"; do
        [[ -n "$root" ]] || continue
        rroot="$(realpath -- "$root" 2>/dev/null)" || continue
        [[ "$real" == "$rroot" || "$real" == "$rroot"/* ]] && return 1
    done
    return 0
}

remove_source_if_enabled() {
    local src="$1"
    if [[ "${DELETE_AFTER_IMPORT:-1}" != "1" ]]; then
        debug_log "Source preserved (DELETE_AFTER_IMPORT=0): $src"
        return 0
    fi
    if [[ "${ENABLE_DESKTOP:-1}" != "1" || "${ENABLE_PORTABLE:-1}" != "1" ]]; then
        echo "[KEEP] Source kept (a library tier is disabled): $(basename "$src")" >&2
        return 0
    fi
    if [[ "${DEBUG_VIDEO_TRIM_SECONDS:-0}" != "0" ]]; then
        echo "[KEEP] Source kept (DEBUG_VIDEO_TRIM_SECONDS is set): $(basename "$src")" >&2
        return 0
    fi
    if [[ "$_ARCHIVE_OK" != "1" ]]; then
        echo "[KEEP] Source kept (camera original not archived): $(basename "$src")" >&2
        return 0
    fi
    if ! source_is_removable "$src"; then
        echo "[KEEP] Source kept (not safely inside UNSORTED): $src" >&2
        return 0
    fi
    if rm -f "$src"; then
        echo "[MOVED] Source removed after import: $(basename "$src")" >&2
    else
        echo "[WARN] Could not remove source: $src" >&2
    fi
}

# Portable file size in bytes (GNU stat, then BSD/macOS stat).
file_bytes() { stat -c '%s' "$1" 2>/dev/null || stat -f '%z' "$1" 2>/dev/null || echo 0; }

# Resolve the file the PORTABLE tier should transcode FROM.
# NEW ARCHITECTURE: the portable output is always derived from the finished
# DESKTOP output — never re-encoded from the original UNSORTED source — so its
# metadata and cover art can be COPIED from the desktop tier instead of being
# fetched from the network a second time. Echoes the desktop output path when it
# exists and is non-empty; returns 1 (with a loud report) when it is missing so
# the caller can skip the portable tier for this file.
resolve_portable_source() {
    local desktop_dest="$1" orig="$2"
    if [[ -f "$desktop_dest" && -s "$desktop_dest" ]]; then
        printf '%s' "$desktop_dest"
        return 0
    fi
    echo "[ERROR] Portable derives from the desktop output, but it is missing: ${desktop_dest} (source: ${orig}). Run the desktop tier first." >&2
    return 1
}

# Archive a camera original verbatim into DESKTOP_CAMERA_ROOT/YYYY/MM/DD/.
# Runs for every CAMERA_SOURCE file on every pass, independent of the conversion
# skip logic, so a re-run backfills any originals missed earlier. Idempotent
# (size-checked), retries transient SMB copy errors, and never aborts the worker.
archive_camera_original() {
    local src="$1"
    _ARCHIVE_OK=1
    [[ "$src" == "${CAMERA_SOURCE%/}/"* ]] || return 0
    local dir="${DESKTOP_CAMERA_ROOT}/${DATE_YEAR}/${DATE_MONTH}/${DATE_DAY}"
    local name base ext cand i=0 partial attempt
    name="$(basename "$src")"
    base="${name%.*}"; ext="${name##*.}"
    [[ "$base" == "$name" ]] && ext=""
    local sz; sz="$(file_bytes "$src")"
    [[ "$sz" != "0" ]] || { _ARCHIVE_OK=0; return 0; }

    # Never overwrite or delete anything already in the camera library: an
    # identical copy means "already archived"; a different file with the same
    # name is a collision, so the original is stored under a _N name instead.
    while :; do
        if (( i == 0 )); then cand="${dir}/${name}"; else cand="${dir}/${base}_${i}${ext:+.$ext}"; fi
        if [[ -e "$cand" ]]; then
            cmp -s "$src" "$cand" && return 0
            (( i++ )); continue
        fi
        break
    done

    partial="${dir}/.${name}.partial-$$"
    for attempt in 1 2 3; do
        mkdir -p "$dir" 2>/dev/null || true
        if cp "$src" "$partial" 2>/dev/null && [[ "$(file_bytes "$partial")" == "$sz" ]] \
           && cmp -s "$src" "$partial" && mv -n "$partial" "$cand" 2>/dev/null && [[ ! -e "$partial" ]]; then
            echo "[DONE] Camera original archived: $(basename "$cand") → ${DATE_YEAR}/${DATE_MONTH}/${DATE_DAY}" >&2
            return 0
        fi
        rm -f "$partial" 2>/dev/null || true
    done
    echo "[WARN] Camera archive failed after retries: $name" >&2
    _ARCHIVE_OK=0
    return 0
}

# ---------------------------------------------------------------------------
# Organization strategies
# ---------------------------------------------------------------------------

orginizeByDate() {
    local file="$1"

    # Detect if this is a video or a photo
    local input_ext="${file##*.}"
    input_ext="$(tr '[:upper:]' '[:lower:]' <<< "$input_ext")"
    local is_video=0
    case "$input_ext" in
        mp4|mov|avi|mkv|m4v|3gp|3g2|mts|m2ts|ts) is_video=1 ;;
    esac

    # Read capture date (tries DateTimeOriginal → QuickTime:CreateDate → FileModifyDate)
    read_photo_date "$file" || {
        echo "[WARN] Skipping file with unknown date: $file" >&2
        return 0
    }

    # Archive the untouched original first, before any skip/convert logic, so the
    # CAMERA library always holds every captured file organized by date — even on
    # a re-run where the converted outputs already exist and conversion is skipped.
    archive_camera_original "$file"

    # Desktop: flat YYYY-MM-DD folder (same as portable) — consistent browsing across both libraries.
    # Portable: flat YYYY-MM-DD folder — Walkman photo browser only shows
    # one subfolder level, so all photos for a day must sit directly inside
    # a single folder (e.g. PICTURES/2006-12-16/photo.jpg).
    local desktop_rel_dir="${DATE_YEAR}-${DATE_MONTH}-${DATE_DAY}"
    local portable_rel_dir="${DATE_YEAR}-${DATE_MONTH}-${DATE_DAY}"
    local base_name filename
    base_name="$(basename "${file%.*}")"
    if (( is_video )); then
        filename="${base_name}.m4v"
    else
        filename="${base_name}.jpg"
    fi

    # Derive desktop and portable roots from MEDIA_ROOT convention
    # MEDIA_ROOT may be the desktop root; portable root is the sibling
    local desktop_root portable_root
    desktop_root="${MEDIA_ROOT/LIBRARY.PORTABLE/LIBRARY.DESKTOP}"
    portable_root="${MEDIA_ROOT/LIBRARY.DESKTOP/LIBRARY.PORTABLE}"

    local desktop_dir="${desktop_root}/${desktop_rel_dir}"
    local portable_dir="${portable_root}/${portable_rel_dir}"
    mkdir -p "$desktop_dir" "$portable_dir"

    # Incremental: skip if both outputs already exist and are non-empty.
    # Must be checked before unique_dest, which would create a _N variant instead
    # of reusing the existing file.
    if [[ "${SKIP_IF_EXISTS:-1}" == "1" ]] \
       && outputs_present "${desktop_dir}/${filename}" "${portable_dir}/${filename}"; then
        echo "[SKIP] Already in library: ${filename} (source kept)" >&2
        return 0
    fi

    local desktop_dest portable_dest
    desktop_dest="$(unique_dest "${desktop_dir}/${filename}")"
    portable_dest="$(unique_dest "${portable_dir}/${filename}")"

    # Sony Walkman compliance: truncate oversized components and validate
    portable_dest="$(walkman_sanitize_path "$portable_root" "$portable_dest")"

    if (( is_video )); then
        echo "[START] Camera video converting: $(basename "$file") → $desktop_rel_dir" >&2
        local _cv_ok=0
        # Desktop is encoded from the untouched source; the portable is then
        # derived from that finished desktop output (metadata included).
        if [[ "${ENABLE_DESKTOP:-1}" == "1" ]]; then
            if convertToDesktopMp4 "$file" "$desktop_dest"; then
                validate_output_or_remove "$desktop_dest" || { echo "[WARN] Desktop MP4 broken (removed): $(basename "$file")" >&2; _cv_ok=1; }
            else
                echo "[WARN] Desktop MP4 failed: $(basename "$file")" >&2; _cv_ok=1
            fi
        fi

        # Restore all camera metadata from the source into the DESKTOP output.
        # ffmpeg re-encode drops QuickTime user data atoms and EXIF; restore via exiftool.
        # -QuickTime:all  → CreateDate, GPS, Make/Model, orientation, camera identifiers, keywords, etc.
        # -EXIF:all       → DateTimeOriginal, GPS (EXIF group), lens info, etc. (iPhones embed both)
        # Cameras like the Panasonic FZ1000 store Make/Model in EXIF IFD0, which
        # cannot be written to an MP4 container — map them into the QuickTime
        # Keys/ItemList groups so players still see the camera identity.
        if [[ "${ENABLE_DESKTOP:-1}" == "1" && -f "$desktop_dest" ]]; then
            exiftool -m -overwrite_original \
                -TagsFromFile "$file" \
                -QuickTime:all \
                -EXIF:all \
                "-Keys:Make<Make" \
                "-Keys:Model<Model" \
                "-Keys:CreationDate<CreateDate" \
                "-QuickTime:Make<Make" \
                "-QuickTime:Model<Model" \
                "$desktop_dest" 2>/dev/null || true
        fi

        if [[ "${ENABLE_PORTABLE:-1}" == "1" ]]; then
            local _cam_port_src
            if _cam_port_src="$(resolve_portable_source "$desktop_dest" "$file")"; then
                if convertToPortableMp4 "$_cam_port_src" "$portable_dest"; then
                    validate_output_or_remove "$portable_dest" || { echo "[WARN] Portable MP4 broken (removed): $(basename "$file")" >&2; _cv_ok=1; }
                    # Copy camera metadata from the desktop output into the portable.
                    [[ -f "$portable_dest" ]] && exiftool -m -overwrite_original \
                        -TagsFromFile "$_cam_port_src" \
                        -QuickTime:all \
                        -EXIF:all \
                        "-Keys:Make<Make" \
                        "-Keys:Model<Model" \
                        "-Keys:CreationDate<CreateDate" \
                        "-QuickTime:Make<Make" \
                        "-QuickTime:Model<Model" \
                        "$portable_dest" 2>/dev/null || true
                else
                    echo "[WARN] Portable MP4 failed: $(basename "$file")" >&2; _cv_ok=1
                fi
            else
                _cv_ok=1
            fi
        fi
        [[ "$_cv_ok" == "0" ]] || return 1
    else
        echo "[START] Photo converting: $(basename "$file") → $desktop_rel_dir" >&2
        if [[ "${ENABLE_DESKTOP:-1}" == "1" ]]; then
            convertToDesktopJpeg "$file" "$desktop_dest" || { echo "[WARN] Desktop JPEG failed: $(basename "$file")" >&2; return 1; }
            validate_output_or_remove "$desktop_dest" || { echo "[WARN] Desktop JPEG broken (removed): $(basename "$file")" >&2; return 1; }
        fi
        if [[ "${ENABLE_PORTABLE:-1}" == "1" ]]; then
            # Portable JPEG is scaled from the finished desktop JPEG (full EXIF
            # already restored there), so metadata is copied, not re-derived.
            local _cam_pj_src
            if _cam_pj_src="$(resolve_portable_source "$desktop_dest" "$file")"; then
                convertToPortableJpeg "$_cam_pj_src" "$portable_dest" || { echo "[WARN] Portable JPEG failed: $(basename "$file")" >&2; return 1; }
                validate_output_or_remove "$portable_dest" || { echo "[WARN] Portable JPEG broken (removed): $(basename "$file")" >&2; return 1; }
            else
                return 1
            fi
        fi
    fi

    verify_outputs "$desktop_dest" "$portable_dest" || return 1

    # Copy cover.jpg to album folder (photos only)
    if (( ! is_video )); then
        local cover_src
        cover_src="$(dirname "$file")/cover.jpg"
        for tier_dir in "$desktop_dir" "$portable_dir"; do
            if [[ -f "$cover_src" && ! -f "${tier_dir}/cover.jpg" ]]; then
                cp -n "$cover_src" "${tier_dir}/cover.jpg"
            fi
        done
    fi

    remove_source_if_enabled "$file"
    if (( is_video )); then
        echo "[DONE] Camera video organized: $(basename "$file") → $desktop_rel_dir" >&2
    else
        echo "[DONE] Photo organized: $(basename "$file") → $desktop_rel_dir" >&2
    fi
}

# Load per-album context (album/year/album-artist/tracklist) written by import.sh's
# fetch_album_meta_for_folder loop. Cache-backed and network-free. The context file
# is keyed by the MD5 hash of the file's immediate parent directory. Stale
# ALBUM_CTX_* from a previous lookup are reset first.
_load_album_ctx_for_file() {
    local _f="$1"
    unset ALBUM_CTX_ALBUM ALBUM_CTX_ALBUM_ARTIST ALBUM_CTX_YEAR ALBUM_CTX_RELEASE_ID ALBUM_CTX_TRACKLIST
    if [[ -n "${ALBUM_CTX_DIR:-}" && -d "${ALBUM_CTX_DIR}" ]]; then
        local _ctx_hash _ctx_file
        _ctx_hash=$(printf '%s' "$(dirname "$_f")" | md5 2>/dev/null \
                    || printf '%s' "$(dirname "$_f")" | cksum | awk '{print $1}')
        _ctx_file="${ALBUM_CTX_DIR}/${_ctx_hash}.sh"
        # shellcheck source=/dev/null
        [[ -f "$_ctx_file" ]] && source "$_ctx_file"
    fi
}

orginizeByTags() {
    trace_log "orginizeByTags called with file: $1"
    local file="$1"
    debug_log "orginizeByTags: $file"

    # Embedded tags — fallback only; API data takes priority
    eval "$(read_audio_tags "$file")" 2>/dev/null || true

    # Snapshot original embedded tags before API calls override them.
    # Used below to restore any field that comes back empty or as a
    # MusicBrainz bracket placeholder ([unknown], [no artist], etc.)
    local _src_artist="${AUDIO_ARTIST:-}"
    local _src_album_artist="${AUDIO_ALBUM_ARTIST:-}"
    local _src_album="${AUDIO_ALBUM:-}"
    local _src_year="${AUDIO_YEAR:-}"
    local _src_track="${AUDIO_TRACK:-}"
    local _src_disc="${AUDIO_DISC:-}"
    local _src_title="${AUDIO_TITLE:-}"
    local _src_genre="${AUDIO_GENRE:-}"

    trace_log "Embedded tags: artist='${AUDIO_ARTIST:-}' album_artist='${AUDIO_ALBUM_ARTIST:-}' album='${AUDIO_ALBUM:-}' year='${AUDIO_YEAR:-}' track='${AUDIO_TRACK:-}' title='${AUDIO_TITLE:-}'"

    # Resolve the source layout independently of folder depth so album/disc
    # placement is correct for every supported structure under the artist root
    # (artist/album/track, artist/<year - album>/track, artist/album/<CD1|Disc 2|
    # DVD1>/track with disc subfolders collapsed, and flat artist/track). When
    # SOURCE_ROOT was not passed (legacy 3-arg call), assume the grandparent of
    # the file is the artist root (matches the canonical artist/album/track shape).
    resolve_source_layout "$file" "${SOURCE_ROOT:-$(dirname "$(dirname "$file")")}"
    local _path_album="${SRC_ALBUM_RAW:-}"
    local _path_disc="${SRC_DISC_FROM_PATH:-}"
    local _path_year="${SRC_YEAR_FROM_PATH:-}"

    # ------------------------------------------------------------------------
    # Fast early-skip probe (NO per-track network lookup).
    #
    # When the source already carries album + track + title tags, the final
    # library path is fully determined by embedded metadata: the AcoustID/
    # MusicBrainz result is discarded for path purposes in this case (see the
    # album `else` branch below, which overwrites AUDIO_ALBUM/DISC/TRACK/TITLE
    # back to the embedded values). So if both tier outputs already exist we can
    # skip WITHOUT the expensive, rate-limited fpcalc + AcoustID + MusicBrainz
    # round-trip. This turns a multi-hour re-sync into a multi-minute one.
    #
    # The probe uses only the deterministic, network-free album-artist cases of
    # resolve_album_artist (compilation marker, or a concrete source folder
    # name). Anything ambiguous falls through to the full import path below, and
    # any future divergence in the naming convention only makes the probe path
    # not-exist (→ no skip → re-import), never a wrong skip.
    # ------------------------------------------------------------------------
    if [[ "${SKIP_IF_EXISTS:-1}" == "1" \
       && -n "$_src_album" && ! "$_src_album" =~ ^\[.*\]$ \
       && -n "$_src_track" \
       && -n "$_src_title" && ! "$_src_title" =~ ^\[.*\]$ ]]; then
        # Mirror resolve_album_artist's network-free precedence (steps 0–2,
        # tags-first) so the probed path matches where the file will actually
        # land. The embedded album-artist tag wins over the folder hint; an
        # explicit "Various Artists" folder still forces the compilation artist.
        # Track-artist / Last.fm cases (steps 3–4) are not deterministic offline,
        # so _p_aa stays empty there and the probe falls through to a full import
        # (a miss, never a wrong skip).
        local _p_hint="${FOLDER_LABEL:-}" _p_tag_aa="${AUDIO_ALBUM_ARTIST:-}" _p_aa=""
        if _is_compilation "$_p_hint"; then
            _p_aa="${COMPILATION_ALBUM_ARTIST:-Various Artists}"
        elif _is_compilation "$_p_tag_aa"; then
            _p_aa="${COMPILATION_ALBUM_ARTIST:-Various Artists}"
        elif [[ -n "$_p_tag_aa" && ! "$_p_tag_aa" =~ ^\[.*\]$ ]] && ! _is_generic "$_p_tag_aa"; then
            _p_aa="$_p_tag_aa"
        elif ! _is_generic "$_p_hint"; then
            _p_aa="$_p_hint"
        fi

        if [[ -n "$_p_aa" ]]; then
            # Album context (album/year) — cache-backed, network-free.
            _load_album_ctx_for_file "$file"

            local _p_year=""
            local _p_folder_year="$_path_year"
            if   [[ -n "$_p_folder_year"     ]]; then _p_year="$_p_folder_year"
            elif [[ -n "${ALBUM_CTX_YEAR:-}" ]]; then _p_year="${ALBUM_CTX_YEAR}"
            elif [[ -n "$_src_year"          ]]; then _p_year="$_src_year"
            fi

            local _p_album _p_aa_s _p_disc _p_track _p_title
            _p_album="$(sanitize_name "$(resolve_album_name "$_src_album" "$_path_album")")"
            _p_aa_s="$(sanitize_name "$_p_aa")"
            _p_disc="$(pad2 "${_path_disc:-${_src_disc:-1}}")"
            _p_track="$(pad2 "$(echo "$_src_track" | grep -oE '^[0-9]+' || true)")"

            local _p_album_folder="${_p_aa_s}/${_p_year:+${_p_year} - }${_p_album}"
            local _p_prefix="${_p_disc}.${_p_track} - "
            local _p_ext_d=".${DESKTOP_AUDIO_FORMAT:-flac}" _p_ext_p=".${PORTABLE_AUDIO_FORMAT:-m4a}"
            local _p_ext_len=$(( ${#_p_ext_d} > ${#_p_ext_p} ? ${#_p_ext_d} : ${#_p_ext_p} ))
            local _p_budget=$(( ${DESKTOP_FILENAME_MAX_BYTES:-255} - ${#_p_prefix} - _p_ext_len ))
            (( _p_budget < 1 )) && _p_budget=1
            _p_title="$(truncate_utf8 "$(sanitize_name "$_src_title")" "$_p_budget")"
            local _p_track_name="${_p_disc}.${_p_track} - ${_p_title}"

            local _p_desktop_root _p_portable_root
            _p_desktop_root="${MEDIA_ROOT/LIBRARY.PORTABLE/LIBRARY.DESKTOP}"
            _p_portable_root="${MEDIA_ROOT/LIBRARY.DESKTOP/LIBRARY.PORTABLE}"
            local _p_desktop_dest="${_p_desktop_root}/${_p_album_folder}/${_p_track_name}.flac"
            local _p_portable_dest="${_p_portable_root}/${_p_album_folder}/${_p_track_name}.m4a"
            _p_portable_dest="$(walkman_sanitize_path "$_p_portable_root" "$_p_portable_dest")"

            # Reset ALBUM_CTX_* loaded above so the full import path below starts
            # from the same clean state as before — in particular, AcoustID must
            # not see ALBUM_CTX_TRACKLIST (preserves existing behavior exactly).
            unset ALBUM_CTX_ALBUM ALBUM_CTX_ALBUM_ARTIST ALBUM_CTX_YEAR ALBUM_CTX_RELEASE_ID ALBUM_CTX_TRACKLIST

            if [[ -f "$_p_desktop_dest" && -s "$_p_desktop_dest" \
               && -f "$_p_portable_dest" && -s "$_p_portable_dest" ]]; then
                # Retry-safe cover backfill: this fast-path skips BEFORE AcoustID,
                # so AUDIO_* tags are unresolved here — embed cover art ONLY (never
                # rewrite tags, which are already correct on the existing outputs).
                ensure_audio_cover_embedded "$file" "$_p_desktop_dest" "$_p_portable_dest" \
                    "$(dirname "$_p_desktop_dest")" "$(dirname "$_p_portable_dest")"
                echo "[SKIP] Already in library: ${_p_track_name}" >&2
                remove_source_if_enabled "$file"
                return 0
            fi
        fi
    fi

    # AcoustID/MusicBrainz: authoritative for TITLE, ARTIST, TRACK, DISC.
    # Also looks up ALBUM_CTX_TRACKLIST for the correct track/disc position within this release.
    fetch_audio_meta_acoustid "$file"

    # Load per-album context written by import.sh's fetch_album_meta_for_folder loop.
    _load_album_ctx_for_file "$file"

    # Album-level context: only override when source has NO album tag.
    # AcoustID/MusicBrainz matches a recording to *any* release it appears on — including
    # compilations — so the API album is unreliable when the source already has an album tag.
    # When source has a valid album, also trust its disc/track numbers (they are relative to
    # that album, not to the API-matched release, which may be a different single-disc comp).
    if [[ -z "$_src_album" || "$_src_album" =~ ^\[.*\]$ ]]; then
        [[ -n "${ALBUM_CTX_ALBUM:-}" ]] && AUDIO_ALBUM="${ALBUM_CTX_ALBUM}"
        [[ -n "${ALBUM_CTX_YEAR:-}"  ]] && AUDIO_YEAR="${ALBUM_CTX_YEAR}"
        # Source subfolder name overrides API: strips "YYYY - " prefix and preserves
        # edition info (e.g. "[Expanded Edition]", "(CIS Edition)") that MusicBrainz drops.
        local _folder_name _folder_year _folder_album
        _folder_name="$_path_album"
        _folder_year="$_path_year"
        # Album-name fallback (used only when the source has no album tag): strip a
        # leading or trailing year token plus its separator so "2008 - X",
        # "X - 2008" and "X (2008)" all reduce to "X".
        _folder_album="$(echo "$_folder_name" \
                         | sed -E 's/^(19|20)[0-9]{2}[[:space:]]*[-_.][[:space:]]*//' \
                         | sed -E 's/[[:space:]]*[-(][[:space:]]*(19|20)[0-9]{2}\)?[[:space:]]*$//' \
                         | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
        [[ -n "$_folder_year"  ]] && AUDIO_YEAR="$_folder_year"
        [[ -n "$_folder_album" ]] && AUDIO_ALBUM="$_folder_album"
        # Flat layout (track directly inside the artist folder, no album subfolder):
        # file it under the configured singles album so it still lands in one place.
        if [[ -z "$_path_album" && ( -z "${AUDIO_ALBUM:-}" || "${AUDIO_ALBUM}" =~ ^\[.*\]$ ) ]]; then
            AUDIO_ALBUM="${SINGLES_ALBUM:-Singles}"
        fi
    else
        AUDIO_ALBUM="$(resolve_album_name "$_src_album" "$_path_album")"
        # Year: folder name has highest priority (e.g. "2008 - Album Name"), then the
        # per-folder album context (one consistent year for the whole folder), then the
        # source tag. The per-track embedded year is the LAST resort because a single
        # album folder can hold tracks with different original-release years (e.g. a
        # rarities/"unreleased" compilation) — trusting it scatters one album across
        # many "YYYY - Album" folders.
        local _folder_year="$_path_year"
        if [[ -n "$_folder_year" ]]; then
            AUDIO_YEAR="$_folder_year"
        elif [[ -n "${ALBUM_CTX_YEAR:-}" ]]; then
            AUDIO_YEAR="${ALBUM_CTX_YEAR}"
        elif [[ -n "$_src_year" ]]; then
            AUDIO_YEAR="$_src_year"
        fi
        [[ -n "$_src_disc"  ]] && AUDIO_DISC="$_src_disc"
        [[ -n "$_src_track" ]] && AUDIO_TRACK="$_src_track"
        # AcoustID may match to a compilation/remix and return a different title for the
        # same recording; the source embedded title is more reliable when album is known.
        [[ -n "$_src_title" ]] && AUDIO_TITLE="$_src_title"
    fi

    # Resolve album artist: FOLDER_LABEL (user-curated source folder) → API result → embedded → Last.fm → track artist
    # FOLDER_LABEL is the explicit source directory name (e.g. "Aes Dana", "Aes Dana feat MikTek")
    # and is always used as-is for folder organization. This means:
    #   - A source folder named "Artist feat Collab" produces a library folder of the same name.
    #   - Per-track feat credits in AUDIO_ARTIST do not affect folder placement; only AUDIO_ALBUM_ARTIST
    #     (resolved here from FOLDER_LABEL) determines which artist folder the album lands in.
    local _aa_hint="${FOLDER_LABEL:-$ALBUM_CTX_ALBUM_ARTIST}"
    resolve_album_artist "$_aa_hint"

    # Restore original embedded tag for any field where the API returned empty
    # or a MusicBrainz bracket-notation placeholder ([unknown], [no artist], etc.)
    [[ -z "${AUDIO_ARTIST:-}"       || "${AUDIO_ARTIST}"       =~ ^\[.*\]$ ]] && [[ -n "$_src_artist"       ]] && AUDIO_ARTIST="$_src_artist"
    [[ -z "${AUDIO_ALBUM_ARTIST:-}" || "${AUDIO_ALBUM_ARTIST}" =~ ^\[.*\]$ ]] && [[ -n "$_src_album_artist" ]] && AUDIO_ALBUM_ARTIST="$_src_album_artist"
    [[ -z "${AUDIO_ALBUM:-}"        || "${AUDIO_ALBUM}"        =~ ^\[.*\]$ ]] && [[ -n "$_src_album"        ]] && AUDIO_ALBUM="$_src_album"
    [[ -z "${AUDIO_YEAR:-}"         || "${AUDIO_YEAR}"         =~ ^\[.*\]$ ]] && [[ -n "$_src_year"         ]] && AUDIO_YEAR="$_src_year"
    [[ -z "${AUDIO_TRACK:-}"        || "${AUDIO_TRACK}"        =~ ^\[.*\]$ ]] && [[ -n "$_src_track"        ]] && AUDIO_TRACK="$_src_track"
    [[ -z "${AUDIO_DISC:-}"         || "${AUDIO_DISC}"         =~ ^\[.*\]$ ]] && [[ -n "$_src_disc"         ]] && AUDIO_DISC="$_src_disc"
    [[ -z "${AUDIO_TITLE:-}"        || "${AUDIO_TITLE}"        =~ ^\[.*\]$ ]] && [[ -n "$_src_title"        ]] && AUDIO_TITLE="$_src_title"
    [[ -z "${AUDIO_GENRE:-}"        || "${AUDIO_GENRE}"        =~ ^\[.*\]$ ]] && [[ -n "$_src_genre"        ]] && AUDIO_GENRE="$_src_genre"

    # Disc number from a disc subfolder (CD1 / Disc 2 / DVD1) is authoritative for
    # placement and tagging: multi-disc albums then number correctly even when the
    # embedded disc tag is missing or wrong.
    [[ -n "$_path_disc" ]] && AUDIO_DISC="$_path_disc"

    local artist="${AUDIO_ARTIST:-Unknown Artist}"
    local album_artist="${AUDIO_ALBUM_ARTIST:-Unknown Artist}"
    local album="${AUDIO_ALBUM:-Unknown Album}"
    local year="${AUDIO_YEAR:-}"
    local track="${AUDIO_TRACK:-0}"
    local disc="${AUDIO_DISC:-1}"
    local title="${AUDIO_TITLE:-$(basename "${file%.*}")}"

    # Surface degraded metadata: each missing field falls back to a placeholder
    # (Unknown Artist / Unknown Album / filename / 0). These [WARN] lines are
    # captured by import.sh into SYNC_LOG so metadata gaps are auditable.
    [[ -z "${AUDIO_ARTIST:-}" ]]      && echo "[WARN] Missing artist tag → 'Unknown Artist': $file" >&2
    [[ -z "${AUDIO_ALBUM:-}" ]]       && echo "[WARN] Missing album tag → 'Unknown Album': $file" >&2
    [[ -z "${AUDIO_TITLE:-}" ]]       && echo "[WARN] Missing title tag → using filename: $file" >&2
    [[ -z "${AUDIO_TRACK:-}" ]]       && echo "[WARN] Missing track number → 0: $file" >&2
    [[ -z "${AUDIO_DISC:-}" ]]        && echo "[WARN] Missing disc number → 1: $file" >&2
    [[ -z "${AUDIO_GENRE:-}" ]]       && echo "[WARN] Missing genre tag → '${GENRE_FALLBACK:-Unknown}': $file" >&2
    [[ -z "${AUDIO_YEAR:-}" ]]        && echo "[WARN] Missing year tag (unresolved): $file" >&2
    [[ "${album_artist}" == "Unknown Artist" ]] && echo "[WARN] Album-artist unresolved → filed under 'Unknown Artist': $file" >&2

    # Guarantee the full mandatory tag set is populated before embedding. The
    # locals above feed the FILENAME; these writes feed the embedded TAGS via
    # embed_audio_meta. Every output then carries album, year (when known), track,
    # disc, artist, album-artist, genre and (below) cover art. Fields that fell
    # back to a placeholder are logged above for audit (import-anyway policy).
    AUDIO_ARTIST="${AUDIO_ARTIST:-Unknown Artist}"
    AUDIO_ALBUM_ARTIST="${album_artist:-Unknown Artist}"
    AUDIO_ALBUM="${AUDIO_ALBUM:-Unknown Album}"
    AUDIO_TITLE="${AUDIO_TITLE:-$(basename "${file%.*}")}"
    AUDIO_TRACK="${AUDIO_TRACK:-0}"
    AUDIO_DISC="${AUDIO_DISC:-1}"
    AUDIO_GENRE="${AUDIO_GENRE:-${GENRE_FALLBACK:-Unknown}}"

    artist="$(sanitize_name "$artist")"
    album_artist="$(sanitize_name "$album_artist")"
    album="$(sanitize_name "$album")"
    title="$(sanitize_name "$title")"

    local album_folder="${album_artist}/${year:+${year} - }${album}"
    local track_padded disc_padded
    disc_padded="$(pad2 "$disc")"
    track_padded="$(pad2 "$(echo "$track" | grep -oE '^[0-9]+' || true)")"
    # Cap the title so the final filename fits the desktop NAME_MAX (bytes) on every
    # tier. Budget = DESKTOP_FILENAME_MAX_BYTES − prefix "DD.TT - " − longest extension.
    # Some sources embed degenerate megamix titles (a whole side concatenated into one
    # tag); without this the desktop `cp` fails outright with "File name too long".
    local _name_prefix="${disc_padded}.${track_padded} - "
    local _ext_d=".${DESKTOP_AUDIO_FORMAT:-flac}" _ext_p=".${PORTABLE_AUDIO_FORMAT:-m4a}"
    local _ext_len=$(( ${#_ext_d} > ${#_ext_p} ? ${#_ext_d} : ${#_ext_p} ))
    local _title_budget=$(( ${DESKTOP_FILENAME_MAX_BYTES:-255} - ${#_name_prefix} - _ext_len ))
    (( _title_budget < 1 )) && _title_budget=1
    title="$(truncate_utf8 "$title" "$_title_budget")"
    local track_name="${disc_padded}.${track_padded} - ${title}"

    debug_log "Audio tags: artist='${artist}' album_artist='${album_artist}' album='${album}' year='${year}' track='${track}' title='${title}'"
    debug_log "Track path: ${album_folder}/${track_name}"

    # Derive roots
    local desktop_root portable_root
    desktop_root="${MEDIA_ROOT/LIBRARY.PORTABLE/LIBRARY.DESKTOP}"
    portable_root="${MEDIA_ROOT/LIBRARY.DESKTOP/LIBRARY.PORTABLE}"

    local desktop_dir="${desktop_root}/${album_folder}"
    local portable_dir="${portable_root}/${album_folder}"
    mkdir -p "$desktop_dir" "$portable_dir"

    local desktop_dest="${desktop_dir}/${track_name}.flac"
    local portable_dest="${portable_dir}/${track_name}.m4a"

    # Sony Walkman compliance: truncate oversized components and validate
    portable_dest="$(walkman_sanitize_path "$portable_root" "$portable_dest")"

    # Retry-safe cover backfill: if the outputs already exist (e.g. this is a
    # retry after a transient parallel-embed race) re-embed any missing art now,
    # BEFORE the skip-gate returns and bypasses the embed path below.
    if outputs_present "$desktop_dest" "$portable_dest"; then
        ensure_audio_cover_embedded "$file" "$desktop_dest" "$portable_dest" "$desktop_dir" "$portable_dir"
    fi

    # Incremental: skip if both outputs already exist and are non-empty.
    if [[ "${SKIP_IF_EXISTS:-1}" == "1" ]] \
       && outputs_present "$desktop_dest" "$portable_dest"; then
        echo "[SKIP] Already in library: ${track_name}" >&2
        remove_source_if_enabled "$file"
        return 0
    fi

    echo "[START] Audio converting: $(basename "$file") → ${album_folder}/${track_name}" >&2
    # Desktop is encoded from the original source; the portable AAC is then
    # derived from the finished desktop FLAC (never the source again), so tags
    # and cover art are copied across rather than re-fetched.
    if [[ "${ENABLE_DESKTOP:-1}" == "1" ]]; then
        convertToFlac "$file" "$desktop_dest" || { echo "[WARN] Desktop FLAC failed: $(basename "$file")" >&2; return 1; }
        validate_output_or_remove "$desktop_dest" || { echo "[WARN] Desktop FLAC broken (removed): $(basename "$file")" >&2; return 1; }
    fi
    if [[ "${ENABLE_PORTABLE:-1}" == "1" ]]; then
        local _aud_port_src
        if _aud_port_src="$(resolve_portable_source "$desktop_dest" "$file")"; then
            convertToAac "$_aud_port_src" "$portable_dest" || { echo "[WARN] Portable AAC failed: $(basename "$file")" >&2; return 1; }
            validate_output_or_remove "$portable_dest" || { echo "[WARN] Portable AAC broken (removed): $(basename "$file")" >&2; return 1; }
        else
            return 1
        fi
    fi

    # Embed metadata + cover art
    local cover_path="${desktop_dir}/cover.jpg"
    # Extract embedded cover art from source file first (v1 approach)
    if [[ ! -f "$cover_path" ]]; then
        ffmpeg -nostdin -y -i "$file" -map 0:v -map -0:V -vframes 1 "$cover_path" 2>/dev/null || true
    fi
    # Fall back to online fetch if source had no embedded art
    if [[ ! -f "$cover_path" || ! -s "$cover_path" ]]; then
        fetch_audio_cover "$cover_path"
    fi

    # Mandatory cover art: warn (import-anyway) when none could be embedded or fetched.
    if [[ ! -f "$cover_path" || ! -s "$cover_path" ]]; then
        echo "[WARN] Missing cover art (none embedded in source or fetched online): $file" >&2
    fi

    # Normalize the cover to a baseline JPEG before embedding. metaflac and
    # AtomicParsley reject PNGs, progressive JPEGs, and alpha channels; source
    # extraction and Last.fm fetches can yield any of these (Last.fm serves
    # 300x300 PNGs), which silently drops the cover art from otherwise-tagged
    # tracks. Re-encoding to baseline yuvj420p JPEG guarantees embeddability.
    if [[ -f "$cover_path" && -s "$cover_path" ]]; then
        local _cover_norm="${cover_path%.jpg}.__norm.jpg"
        if "${FFMPEG_BIN:-ffmpeg}" -nostdin -y -v error -i "$cover_path" \
                -map 0:v:0 -frames:v 1 -c:v mjpeg -pix_fmt yuvj420p "$_cover_norm" 2>/dev/null \
           && [[ -s "$_cover_norm" ]]; then
            mv -f "$_cover_norm" "$cover_path"
        else
            rm -f "$_cover_norm" 2>/dev/null || true
        fi
    fi

    [[ -f "$desktop_dest"  ]] && embed_audio_meta "$desktop_dest"  "$cover_path"
    [[ -f "$portable_dest" ]] && embed_audio_meta "$portable_dest" "$cover_path"

    # Copy cover to portable folder
    if [[ -f "$cover_path" && ! -f "${portable_dir}/cover.jpg" ]]; then
        cp -n "$cover_path" "${portable_dir}/cover.jpg"
    fi

    verify_outputs "$desktop_dest" "$portable_dest" || return 1

    remove_source_if_enabled "$file"
    echo "[DONE] Audio organized: $(basename "$file") → ${album_folder}/${track_name}" >&2
}

orginizeByVideoMeta() {
    local file="$1"
    debug_log "orginizeByVideoMeta: $file"

    # Populate VIDEO_* from existing tags
    eval "$(read_video_tags "$file")" 2>/dev/null || true

    detect_video_type "$file"

    # When the file comes from the TV library root, force TV mode regardless
    # of whether the filename contains an S##E## marker (e.g. "1-01 Title.mp4").
    # FOLDER_LABEL is the show directory name passed in from import.sh, so it
    # is a reliable show-name seed even when the filename carries no SxxExx tag.
    if [[ "${MEDIA_ROOT}" == *"/TV"* ]]; then
        VIDEO_TYPE="tv"
        [[ -z "${VIDEO_TVSHOW:-}" ]] && VIDEO_TVSHOW="${FOLDER_LABEL}"
    fi

    # Probe source resolution and best audio language for filename suffixes
    probe_video_info "$file"

    local base_name
    base_name="$(basename "${file%.*}")"

    # res suffixes — desktop uses source resolution, portable is always downscaled to SD
    local desk_suffix=" [${VIDEO_RES_LABEL:-SD}]"
    local port_suffix=" [SD]"

    local desktop_rel portable_rel

    if [[ "${VIDEO_TYPE:-movie}" == "tv" ]]; then
        local season="" episode=""

        # ------------------------------------------------------------------
        # Extract season + episode number from the filename using multiple
        # naming conventions, tried in order of specificity.
        # ------------------------------------------------------------------

        # Pattern 1: SxxExx  S##.E##  S##_E##  (standard + dot/underscore)
        #   e.g. S01E01  S01.E01  s01_e01
        if [[ "$base_name" =~ [Ss]([0-9]{1,2})[._]?[Ee]([0-9]{1,2}) ]]; then
            season="${BASH_REMATCH[1]}"
            episode="${BASH_REMATCH[2]}"
            # Series name = text before the SxxExx token, dots/dashes → spaces
            local raw_series="${base_name%%[Ss][0-9]*}"
            raw_series="${raw_series//[._-]/ }"
            raw_series="$(echo "$raw_series" | sed 's/  */ /g; s/^[[:space:]]*//; s/[[:space:]]*$//')"
            [[ -z "${VIDEO_TVSHOW:-}" ]] && [[ -n "$raw_series" ]] && VIDEO_TVSHOW="$raw_series"

        # Pattern 2: ##x##  S##x##  (e.g. 1x01, 01x02, S01x01)
        elif [[ "$base_name" =~ [Ss]?([0-9]{1,2})x([0-9]{2})([^0-9]|$) ]]; then
            season="${BASH_REMATCH[1]}"
            episode="${BASH_REMATCH[2]}"
            local raw_series="${base_name%%[0-9]*x[0-9]*}"
            raw_series="${raw_series//[._-]/ }"
            raw_series="$(echo "$raw_series" | sed 's/  */ /g; s/^[[:space:]]*//; s/[[:space:]]*$//')"
            [[ -z "${VIDEO_TVSHOW:-}" ]] && [[ -n "$raw_series" ]] && VIDEO_TVSHOW="$raw_series"

        # Pattern 3: N-NN Title  (e.g. "1-01 Title", "05-01 Title", "21-01. Title" — Air Crash Investigation)
        elif [[ "$base_name" =~ ^([0-9]{1,2})-([0-9]{2})([[:space:].]|$) ]]; then
            season="${BASH_REMATCH[1]}"
            episode="${BASH_REMATCH[2]}"
            # Series name comes from FOLDER_LABEL (already seeded into VIDEO_TVSHOW)

        # Pattern 4: SSEE 4-digit compact  (e.g. "0101 - Title" — Sex and the City)
        # Only matches 0x prefix to avoid false-positives with year-style filenames (2006 …).
        elif [[ "$base_name" =~ ^(0[0-9])([0-9]{2})[[:space:]-] ]]; then
            season="${BASH_REMATCH[1]}"
            episode="${BASH_REMATCH[2]}"

        # Pattern 5: NN. Title  (e.g. "01. Львята" — Lego City Adventures)
        elif [[ "$base_name" =~ ^([0-9]{2})\.[[:space:]] ]]; then
            season="1"
            episode="${BASH_REMATCH[1]}"

        # Pattern 6: NN Title  or  NN - Title  (plain leading episode number, season assumed 1)
        #   e.g. "03 - Episode Title", "12 Episode Title"
        elif [[ "$base_name" =~ ^([0-9]{2})[[:space:]-] ]]; then
            season="1"
            episode="${BASH_REMATCH[1]}"

        # Pattern 7: Exx  Epxx  anywhere  (e.g. "Show E05", "Show Ep12")
        elif [[ "$base_name" =~ [Ee][Pp]?([0-9]{2,3})([^0-9]|$) ]]; then
            season="1"
            episode="${BASH_REMATCH[1]}"
        fi

        if [[ -n "$season" && -n "$episode" ]]; then
            # Extract episode title from source filename (text after SxxExx, before quality markers).
            # Used as fallback when TMDB returns nothing.
            local ep_title_hint="" ep_title_from_paren=0
            if [[ "$base_name" =~ [Ss][0-9]{1,2}[._-]?[Ee][0-9]{1,2}[._[:space:]-]?(.*) ]]; then
                local _sfx="${BASH_REMATCH[1]}"
                local _sfx_lc
                _sfx_lc="$(printf '%s' "$_sfx" | tr '[:upper:]' '[:lower:]')"
                local _qpos
                _qpos="$(printf '%s' "$_sfx_lc" | \
                    grep -ob '[._-]\(720p\|1080p\|2160p\|4k\|8k\|hdr\|sdr\|web\|blu\|hdtv\|dvd\|x264\|x265\|hevc\|h264\|h265\|aac\|dts\|remux\|repack\|proper\)' \
                    2>/dev/null | head -1 | cut -d: -f1)" || true
                [[ -n "$_qpos" && "$_qpos" =~ ^[0-9]+$ ]] && _sfx="${_sfx:0:$_qpos}"
                _sfx="${_sfx//[._-]/ }"
                ep_title_hint="$(printf '%s' "$_sfx" | sed 's/  */ /g; s/^[[:space:]]*//; s/[[:space:]]*$//')"
            # Pattern 3 N-NN format: prefer English title in parentheses, fallback to full suffix
            # Store patterns in variables for bash 3.2 compatibility (inline [. ] character classes break)
            elif [[ "$base_name" =~ ^[0-9]{1,2}-[0-9]{2}(.+) ]]; then
                local _nnn_prefix_pat='^[0-9]{1,2}-[0-9]{2}[. ]+'
                local _nnn_paren_pat='\(([^)]+)\)[^(]*$'
                local _nnn_suffix_pat='^[0-9]{1,2}-[0-9]{2}[. ]+(.+)'
                if [[ "$base_name" =~ $_nnn_paren_pat ]]; then
                    ep_title_hint="${BASH_REMATCH[1]}"
                    ep_title_from_paren=1
                elif [[ "$base_name" =~ $_nnn_prefix_pat ]] && [[ "$base_name" =~ $_nnn_suffix_pat ]]; then
                    ep_title_hint="${BASH_REMATCH[1]}"
                    ep_title_hint="$(printf '%s' "$ep_title_hint" | sed 's/  */ /g; s/^[[:space:]]*//; s/[[:space:]]*$//')"
                fi
            fi

            # Clear source-file tags so TMDB is authoritative for episode title/year/desc
            VIDEO_TITLE="" VIDEO_YEAR="" VIDEO_DESC=""
            # Probe source file duration (seconds) for duration-confirmed title matching.
            local _src_dur_secs=0
            if command -v ffprobe &>/dev/null; then
                local _dur_raw
                _dur_raw=$(ffprobe -v error -show_entries format=duration \
                    -of csv=p=0 "$file" 2>/dev/null | cut -d. -f1)
                [[ "$_dur_raw" =~ ^[0-9]+$ ]] && _src_dur_secs="$_dur_raw"
            fi
            # For N-NN files with English title in (parens): search TMDB by title to get
            # the correct episode number (Russian releases often use different ordering).
            if [[ "$ep_title_from_paren" == "1" ]] && \
               fetch_video_meta_tv_by_title "${VIDEO_TVSHOW}" "$((10#$season))" "$ep_title_hint" "$_src_dur_secs"; then
                # TMDB matched by title — use TMDB only for description/poster/genre.
                # Season and episode number come from the filename: it is the true
                # source of truth (Russian releases often use different numbering).
                # Title also stays as the filename's English paren title.
                VIDEO_TITLE="$ep_title_hint"
            else
                fetch_video_meta_tv "${VIDEO_TVSHOW}" "$((10#$season))" "$((10#$episode))"
            fi

            # Fall back to filename-extracted title when TMDB returns nothing
            [[ -z "${VIDEO_TITLE:-}" ]] && VIDEO_TITLE="${ep_title_hint}"

            local series_safe season_pad ep_pad ep_title_safe
            series_safe="$(sanitize_name "${VIDEO_TVSHOW:-Unknown Series}")"
            season_pad="$(pad2 "$((10#$season))")"
            ep_pad="$(pad2 "$((10#$episode))")"
            ep_title_safe="$(sanitize_name "${VIDEO_TITLE:-}")"

            local ep_base="S${season_pad}E${ep_pad}${ep_title_safe:+ - ${ep_title_safe}}"
            desktop_rel="${series_safe}/${ep_base}${desk_suffix}"
            portable_rel="${series_safe}/${ep_base}${port_suffix}"
        else
            # No recognizable episode pattern — fall back to original name with suffixes
            local show_safe
            show_safe="$(sanitize_name "${VIDEO_TVSHOW:-Unknown Series}")"
            desktop_rel="${show_safe}/${base_name}${desk_suffix}"
            portable_rel="${show_safe}/${base_name}${port_suffix}"
        fi
    else
        # Movie — parse filename for clean title/year hints (handles dot-separated scene names)
        parse_video_filename "$base_name"
        # Use filename-parsed hint for TMDB — source tags on rips are unreliable garbage
        local title_hint="${VIDEO_TITLE_HINT:-$base_name}"
        local year_hint="${VIDEO_YEAR_HINT:-}"

        # Clear source-read fields so TMDB is authoritative for movies
        VIDEO_TITLE="" VIDEO_YEAR="" VIDEO_GENRE="" VIDEO_DESC=""

        fetch_video_meta_movie "$title_hint" "$year_hint"

        # If filename-based lookup failed (e.g. non-English/Russian filename),
        # retry using the folder label (FOLDER_LABEL) as the title hint.
        if [[ -z "${VIDEO_TITLE:-}" && -n "${FOLDER_LABEL:-}" && "$FOLDER_LABEL" != "$title_hint" ]]; then
            fetch_video_meta_movie "$FOLDER_LABEL" "$year_hint"
        fi

        # Fallback to filename-parsed values when TMDB is unavailable or returns nothing
        VIDEO_TITLE="${VIDEO_TITLE:-${FOLDER_LABEL:-$title_hint}}"
        VIDEO_YEAR="${VIDEO_YEAR:-$year_hint}"

        local title_safe year_str
        title_safe="$(sanitize_name "${VIDEO_TITLE}")"
        year_str="${VIDEO_YEAR:+ (${VIDEO_YEAR})}"
        local folder_name="${title_safe}${year_str}"
        local file_base="${title_safe}${year_str}"

        # Folder and file both use clean TMDB title + year
        desktop_rel="${folder_name}/${file_base}${desk_suffix}"
        portable_rel="${folder_name}/${file_base}${port_suffix}"
    fi

    # Derive roots
    local desktop_root portable_root
    desktop_root="${MEDIA_ROOT/LIBRARY.PORTABLE/LIBRARY.DESKTOP}"
    portable_root="${MEDIA_ROOT/LIBRARY.DESKTOP/LIBRARY.PORTABLE}"

    local desktop_dir portable_dir
    desktop_dir="${desktop_root}/$(dirname "$desktop_rel")"
    portable_dir="${portable_root}/$(dirname "$portable_rel")"
    mkdir -p "$desktop_dir" "$portable_dir"

    local desktop_out portable_out
    desktop_out="$(basename "$desktop_rel")"
    portable_out="$(basename "$portable_rel")"

    local desktop_dest="${desktop_dir}/${desktop_out}.m4v"
    local portable_dest="${portable_dir}/${portable_out}.m4v"

    # Sony Walkman compliance: truncate oversized components and validate
    portable_dest="$(walkman_sanitize_path "$portable_root" "$portable_dest")"

    # # Detect stale same-episode files: a prior import may have used a different TMDB
    # # title for this SxxExx slot. Stale files have the same SxxExx prefix but a
    # # different base name.  Stored here so post-encode cleanup can remove them.
    # local _ep_prefix _stale_desktop="" _stale_portable=""
    # _ep_prefix=$(basename "${desktop_dest%.m4v}" | grep -oE '^S[0-9]{2}E[0-9]{2}')
    # if [[ -n "$_ep_prefix" ]]; then
    #     _stale_desktop=$(find "$desktop_dir"  -maxdepth 1 \
    #         -name "${_ep_prefix} - *.m4v" ! -name "$(basename "$desktop_dest")" 2>/dev/null | head -1)
    #     _stale_portable=$(find "$portable_dir" -maxdepth 1 \
    #         -name "${_ep_prefix} - *.m4v" ! -name "$(basename "$portable_dest")" 2>/dev/null | head -1)
    # fi

    # Incremental: skip if both outputs already exist, are non-empty, and valid.
    # Also validates with ffprobe so a corrupt file (moov atom missing from a
    # prior SIGKILL) doesn't get silently skipped and left in the library.
    # Secondary check: if the exact targets are missing but a stale same-episode
    # file exists in BOTH libraries, treat it as already done to avoid re-encoding.
    local _check_desktop="$desktop_dest" _check_portable="$portable_dest"
    # if [[ "${SKIP_IF_EXISTS:-1}" == "1" \
    #    && ! -f "$desktop_dest" && -n "$_stale_desktop" \
    #    && ! -f "$portable_dest" && -n "$_stale_portable" ]]; then
    #     _check_desktop="$_stale_desktop"
    #     _check_portable="$_stale_portable"
    # fi
    if [[ "${SKIP_IF_EXISTS:-1}" == "1" ]] \
       && outputs_present "$_check_desktop" "$_check_portable"; then
        local _outer_valid=1
        if command -v ffprobe &>/dev/null; then
            [[ "${ENABLE_DESKTOP:-1}" == "1" ]] && { ffprobe -v error -show_entries format=duration \
                -of default=noprint_wrappers=1 "$_check_desktop" &>/dev/null 2>&1 || _outer_valid=0; }
            [[ "${ENABLE_PORTABLE:-1}" == "1" ]] && { ffprobe -v error -show_entries format=duration \
                -of default=noprint_wrappers=1 "$_check_portable" &>/dev/null 2>&1 || _outer_valid=0; }
        fi
        if (( _outer_valid )); then
            if [[ "$_check_desktop" != "$desktop_dest" ]]; then
                echo "[SKIP] Already in library (title changed): $(basename "$_check_desktop")" >&2
            else
                echo "[SKIP] Already in library: ${desktop_out}.m4v" >&2
                # Exact targets confirmed present — clean up any stale same-episode
                # files left over from a prior broken run (different TMDB title).
                # if [[ -n "$_stale_desktop" && -f "$_stale_desktop" ]]; then
                #     rm -f "$_stale_desktop" "${_stale_desktop%.m4v}.jpg"
                #     echo "[INFO] Removed stale desktop: $(basename "$_stale_desktop")" >&2
                # fi
                # if [[ -n "$_stale_portable" && -f "$_stale_portable" ]]; then
                #     rm -f "$_stale_portable" "${_stale_portable%.m4v}.jpg"
                #     echo "[INFO] Removed stale portable: $(basename "$_stale_portable")" >&2
                # fi
            fi
            remove_source_if_enabled "$file"
            return 0
        fi
        echo "[WARN] Corrupt file(s) in library, re-processing: $(basename "$_check_desktop")" >&2
    fi

    echo "[START] Video converting: $(basename "$file") → ${desktop_out}.m4v" >&2
    local _vv_ok=0
    if [[ "${ENABLE_DESKTOP:-1}" == "1" ]]; then
        if convertToDesktopMp4 "$file" "$desktop_dest"; then
            validate_output_or_remove "$desktop_dest" || { echo "[WARN] Desktop MP4 broken (removed): $(basename "$file")" >&2; _vv_ok=1; }
        else
            echo "[WARN] Desktop MP4 failed: $(basename "$file")" >&2; _vv_ok=1
        fi
    fi
    if [[ "${ENABLE_PORTABLE:-1}" == "1" ]]; then
        # Portable is transcoded from the finished desktop output, not the
        # original source; poster + metadata below are shared from the same
        # single lookup, so nothing is requested a second time.
        local _port_src
        if _port_src="$(resolve_portable_source "$desktop_dest" "$file")"; then
            if convertToPortableMp4 "$_port_src" "$portable_dest"; then
                validate_output_or_remove "$portable_dest" || { echo "[WARN] Portable MP4 broken (removed): $(basename "$file")" >&2; _vv_ok=1; }
            else
                echo "[WARN] Portable MP4 failed: $(basename "$file")" >&2; _vv_ok=1
            fi
        else
            _vv_ok=1
        fi
    fi
    [[ "$_vv_ok" == "0" ]] || return 1

    # Fetch and embed poster/metadata
    local poster_path="${desktop_dir}/poster.jpg"
    if [[ ! -f "$poster_path" ]]; then
        fetch_video_poster "$poster_path"
    fi

    # Fallback: extract cover art already embedded in the m4v (from a prior run)
    # so the sidecar poster.jpg is always present even when TMDB fetch fails.
    if [[ ! -f "$poster_path" ]] && [[ -f "$desktop_dest" ]]; then
        local _nv
        _nv=$(ffprobe -v error -select_streams v -show_entries stream=index \
            -of csv=p=0 "$desktop_dest" 2>/dev/null | wc -l | tr -d ' ') || _nv=0
        if (( ${_nv:-0} > 1 )); then
            ffmpeg -nostdin -v error -i "$desktop_dest" -map 0:v:1 -vframes 1 \
                "$poster_path" 2>/dev/null || true
            [[ -f "$poster_path" ]] && \
                echo "[INFO] Poster extracted from embedded cover art: $poster_path" >&2
        fi
    fi

    # embed is non-fatal — a metadata failure must not abort the whole file
    if [[ -f "$desktop_dest" ]]; then
        embed_video_meta "$desktop_dest"  "$poster_path" "full" || \
            echo "[WARN] Desktop metadata embed failed (non-fatal): $desktop_dest" >&2
    fi
    if [[ -f "$portable_dest" ]]; then
        embed_video_meta "$portable_dest" "$poster_path" "portable" || \
            echo "[WARN] Portable metadata embed failed (non-fatal): $portable_dest" >&2
    fi

    # Desktop sidecar: <video_base>.jpg (full resolution) — recognized by Infuse, Jellyfin, Kodi, etc.
    local desktop_thumb="${desktop_dir}/${desktop_out}.jpg"
    if [[ -f "$poster_path" && ! -f "$desktop_thumb" ]]; then
        cp "$poster_path" "$desktop_thumb"
    fi

    # Portable poster.jpg — scaled to fit within the video frame size (PORTABLE_VIDEO_WIDTH×PORTABLE_VIDEO_HEIGHT).
    # Same dimensions as the cover art embedded inside the M4V file.
    local portable_poster="${portable_dir}/poster.jpg"
    if [[ -f "$poster_path" && ! -f "$portable_poster" ]]; then
        local _pw="${PORTABLE_VIDEO_WIDTH:-320}"
        local _ph="${PORTABLE_VIDEO_HEIGHT:-240}"
        "${FFMPEG_BIN:-ffmpeg}" -nostdin -y -v error -i "$poster_path" \
            -vf "scale=${_pw}:${_ph}:force_original_aspect_ratio=decrease" \
            -q:v 3 "$portable_poster" 2>/dev/null || cp "$poster_path" "$portable_poster"
    fi

    # Per-episode sidecar .jpg next to portable video — required for Walkman file browser thumbnails.
    # Enabled by default (PORTABLE_VIDEO_SIDECAR_THUMB=1); set to 0 to disable.
    if [[ "${PORTABLE_VIDEO_SIDECAR_THUMB:-1}" == "1" && -f "$poster_path" ]]; then
        local portable_thumb="${portable_dir}/${portable_out}.jpg"
        if [[ ! -f "$portable_thumb" ]]; then
            local _tw="${PORTABLE_VIDEO_SIDECAR_THUMB_WIDTH:-240}"
            local _th="${PORTABLE_VIDEO_SIDECAR_THUMB_HEIGHT:-320}"
            "${FFMPEG_BIN:-ffmpeg}" -nostdin -y -v error -i "$poster_path" \
                -vf "scale=${_tw}:${_th}:force_original_aspect_ratio=decrease" \
                -q:v 3 "$portable_thumb" 2>/dev/null || true
        fi
    fi

    verify_outputs "$desktop_dest" "$portable_dest" || return 1

    # # Remove stale same-episode files replaced by this encode (TMDB title changed).
    # if [[ -n "$_stale_desktop" && -f "$_stale_desktop" ]]; then
    #     rm -f "$_stale_desktop" "${_stale_desktop%.m4v}.jpg"
    #     echo "[INFO] Removed stale desktop: $(basename "$_stale_desktop")" >&2
    # fi
    # if [[ -n "$_stale_portable" && -f "$_stale_portable" ]]; then
    #     rm -f "$_stale_portable" "${_stale_portable%.m4v}.jpg"
    #     echo "[INFO] Removed stale portable: $(basename "$_stale_portable")" >&2
    # fi

    remove_source_if_enabled "$file"
    echo "[DONE] Video organized: $(basename "$file") → $(dirname "$desktop_rel")/${desktop_out}.m4v" >&2
}

orginizeDefault() {
    local file="$1"
    local label="${FOLDER_LABEL:-misc}"

    local desktop_root portable_root
    desktop_root="${MEDIA_ROOT/LIBRARY.PORTABLE/LIBRARY.DESKTOP}"
    portable_root="${MEDIA_ROOT/LIBRARY.DESKTOP/LIBRARY.PORTABLE}"

    local desktop_dir="${desktop_root}/${label}"
    local portable_dir="${portable_root}/${label}"
    mkdir -p "$desktop_dir" "$portable_dir"

    local filename
    filename="$(basename "$file")"

    cp -n "$file" "${desktop_dir}/${filename}" 2>/dev/null || true
    cp -n "$file" "${portable_dir}/${filename}" 2>/dev/null || true

    if cmp -s "$file" "${desktop_dir}/${filename}" && cmp -s "$file" "${portable_dir}/${filename}"; then
        remove_source_if_enabled "$file"
        echo "[DONE] Default copy: $filename → $label" >&2
    else
        echo "[KEEP] Source kept (library copy missing or different): $filename" >&2
    fi
}

# ---------------------------------------------------------------------------
# Route by extension
# ---------------------------------------------------------------------------

case "$EXT_LOWER" in
    m4a|m4b|flac|mp3|aac|ogg|opus|wav|aiff|wv|ape|mka|wma|caf|mp2)
        assert_source_valid "$FILE_PATH" || exit 1
        orginizeByTags "$FILE_PATH"
        ;;
    jpg|jpeg|png|bmp|webp|heic|heif|avif|orf|rw2|cr2|nef|arw|dng|tiff|tif|psd)
        # Images inside a MUSIC root are cover art — skip them (embedded by audio pipeline)
        if [[ "$MEDIA_ROOT" == *"MUSIC"* ]]; then
            echo "[INFO] Skipping cover art in music source: $FILE_PATH" >&2
            exit 0
        fi
        assert_source_valid "$FILE_PATH" || exit 1
        orginizeByDate "$FILE_PATH"
        ;;
    mp4|mov|avi|mkv|mpeg|avc|m4v|m2v|wmv|ts|m2ts|mts|flv|webm|ogv|3gp|3g2|vob|asf)
        assert_source_valid "$FILE_PATH" || exit 1
        # Files arriving via CAMERA_SOURCE land in a PHOTOS root — treat as camera footage
        # (date-based organizer, preserve GPS/EXIF, no TMDB lookup)
        if [[ "$MEDIA_ROOT" == *"PHOTOS"* ]]; then
            orginizeByDate "$FILE_PATH"
        else
            orginizeByVideoMeta "$FILE_PATH"
        fi
        ;;
    *)
        # Unknown extension — not a supported media type, silently ignore.
        debug_log "Skipping unsupported extension '$EXT_LOWER': $FILE_PATH"
        exit 0
        ;;
esac
