#!/usr/bin/env bash
# convert.sh — file converter for the v2 media library system
#
# Usage:
#   ./convert.sh <filePath> <tier> <destDir>
#
# <tier>: desktop | portable

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.sh"
source "${SCRIPT_DIR}/metadata.sh"

# ---------------------------------------------------------------------------
# Utility
# ---------------------------------------------------------------------------

# Resolve ffmpeg binary: prefer local, fall back to Docker.
# All ffmpeg output is shown so progress stats are always visible.
_ffmpeg() {
    local run
    if command -v "${FFMPEG_BIN:-ffmpeg}" &>/dev/null; then
        run=("${FFMPEG_BIN:-ffmpeg}")
    else
        run=(docker run --rm -v "$(pwd):/work" -w /work jrottenberg/ffmpeg:4.4-alpine)
    fi

    debug_log "ffmpeg cmd: $(printf '%q ' "${run[@]}" "$@")"
    local _rc=0
    "${run[@]}" -nostdin "$@" || _rc=$?
    return $_rc
}

# Run _ffmpeg; on failure, remove the staged output file and return 1.
# The staged output path must be the last argument passed.
_ffmpeg_or_fail() {
    local _rc=0
    _ffmpeg "$@" || _rc=$?
    if [[ $_rc -ne 0 ]]; then
        local _staged="${*: -1}"
        echo "[WARN] ffmpeg failed (code ${_rc}) for: $(basename "${_staged}")" >&2
        rm -f "${_staged}"
        return 1
    fi
}

# Suppress tool output unless DEBUG_MODE=1.
# On failure, ALWAYS surface a one-line [WARN] with the tail of the tool's stderr
# (even at DEBUG_MODE=0) so silent sips/exiftool conversion failures are no longer
# swallowed. The warning goes to stderr, which import.sh captures into SYNC_LOG.
_quiet() {
    if [[ "${DEBUG_MODE:-0}" == "1" ]]; then
        "$@"
        return $?
    fi
    local _qerr _rc=0
    _qerr="$(mktemp /tmp/quiet_err_XXXXXX)"
    "$@" >/dev/null 2>"$_qerr" || _rc=$?
    if (( _rc != 0 )); then
        echo "[WARN] ${1##*/} failed (code ${_rc}): $(tr '\n' ' ' < "$_qerr" | tail -c 300)" >&2
    fi
    rm -f "$_qerr"
    return $_rc
}

# ---------------------------------------------------------------------------
# Integrity checks — never silently skip broken media
# ---------------------------------------------------------------------------
# Return 0 if a media file is structurally valid (decodable), 1 otherwise.
# Video/audio: ffprobe must read a duration. Images: dimensions must be > 0.
media_file_valid() {
    local f="$1"
    [[ -f "$f" && -s "$f" ]] || return 1
    local e="${f##*.}"; e="$(tr '[:upper:]' '[:lower:]' <<< "$e")"
    case "$e" in
        m4v|mp4|mov|avi|mkv|m4a|m4b|flac|aac|ogg|opus|wav|mka|wma|webm|ogv|ts|m2ts|mts|3gp|3g2|vob|asf|wv|ape|mp3|mp2|aiff|caf)
            command -v ffprobe &>/dev/null || return 0
            ffprobe -v error -show_entries format=duration \
                -of default=noprint_wrappers=1 "$f" &>/dev/null
            ;;
        jpg|jpeg|png|bmp|webp|heic|heif|avif|orf|rw2|cr2|nef|arw|dng|tiff|tif|psd)
            # exiftool reads dimensions for RAW/HEIC/etc. that ImageMagick cannot
            # decode, so it is the primary "not truncated" check; fall back to
            # ImageMagick identify only when exiftool yields nothing.
            local w="" h="" dims
            if command -v exiftool &>/dev/null; then
                w=$(exiftool -s3 -ImageWidth  "$f" 2>/dev/null | head -1 | tr -dc '0-9')
                h=$(exiftool -s3 -ImageHeight "$f" 2>/dev/null | head -1 | tr -dc '0-9')
            fi
            if [[ -z "$w" || -z "$h" ]]; then
                dims="$(image_dimensions "$f" 2>/dev/null)" || return 1
                w="${dims%% *}"; h="${dims##* }"
            fi
            [[ "$w" =~ ^[0-9]+$ && "$h" =~ ^[0-9]+$ && "$w" -gt 0 && "$h" -gt 0 ]]
            ;;
        *) return 0 ;;
    esac
}

# Validate a SOURCE file before conversion. Broken → LOUD console report + a
# non-zero return so the caller aborts this file (import.sh logs it as a
# failure). Broken sources are NEVER silently skipped.
assert_source_valid() {
    local f="$1"
    if ! media_file_valid "$f"; then
        echo "[ERROR] Broken/unreadable SOURCE file — NOT importing: $f" >&2
        return 1
    fi
    return 0
}

# Validate a freshly-written OUTPUT file. Broken → console report + delete so the
# next sync re-creates it. Returns 1 when the output was broken (and removed).
validate_output_or_remove() {
    local f="$1"
    [[ -f "$f" ]] || return 0
    if ! media_file_valid "$f"; then
        if in_camera_library "$f"; then
            echo "[ERROR] Broken file in camera library — NOT removed: $f" >&2
            return 1
        fi
        echo "[ERROR] Broken CONVERTED output — removing so next sync retries: $f" >&2
        rm -f "$f"
        return 1
    fi
    return 0
}

# Probe audio streams and return global stream indices sorted by language priority:
#   English first, Ukrainian second, all others in original order.
# Echoes space-separated indices; returns 1 if ffprobe is unavailable or no audio found.
_audio_stream_order() {
    local input="$1"
    if ! command -v ffprobe &>/dev/null; then
        debug_log "_audio_stream_order: ffprobe not found, skipping sort"
        return 1
    fi
    local probe
    probe=$(ffprobe -v error -select_streams a \
        -show_entries stream=index:stream_tags=language \
        -of csv=p=0 "$input" 2>/dev/null) || probe=""

    local -a eng=() ukr=() rus=() other=()
    while IFS=',' read -r idx lang; do
        [[ -z "${idx// /}" ]] && continue
        local lang_lower
        lang_lower="$(tr '[:upper:]' '[:lower:]' <<< "$lang")"
        lang_lower="$(_normalize_lang "$lang_lower")"
        _is_lang_allowed "$lang_lower" || continue
        case "$lang_lower" in
            eng) eng+=("$idx") ;;
            ukr) ukr+=("$idx") ;;
            rus) rus+=("$idx") ;;
            *)   other+=("$idx") ;;
        esac
    done <<< "$probe"

    local -a result=(${eng[@]:+"${eng[@]}"} ${ukr[@]:+"${ukr[@]}"} ${rus[@]:+"${rus[@]}"} ${other[@]:+"${other[@]}"})
    (( ${#result[@]} == 0 )) && return 1
    echo "${result[*]}"
}

# Normalize ISO 639-1 (2-letter) codes to ISO 639-2 (3-letter) so that language
# tags in source files ("ru", "uk", "en") match the 3-letter codes in config.
# Covers all languages commonly encountered in movie/TV rips.
_normalize_lang() {
    case "$1" in
        # Germanic
        en)  echo "eng" ;;
        de)  echo "deu" ;;
        nl)  echo "nld" ;;
        sv)  echo "swe" ;;
        no)  echo "nor" ;;
        da)  echo "dan" ;;
        fi)  echo "fin" ;;
        # Romance
        fr)  echo "fra" ;;
        es)  echo "spa" ;;
        it)  echo "ita" ;;
        pt)  echo "por" ;;
        ro)  echo "ron" ;;
        ca)  echo "cat" ;;
        # Slavic
        ru)  echo "rus" ;;
        uk)  echo "ukr" ;;
        pl)  echo "pol" ;;
        cs)  echo "ces" ;;
        sk)  echo "slk" ;;
        sr)  echo "srp" ;;
        hr)  echo "hrv" ;;
        bg)  echo "bul" ;;
        sl)  echo "slv" ;;
        # Baltic
        lt)  echo "lit" ;;
        lv)  echo "lav" ;;
        et)  echo "est" ;;
        # East Asian
        ja)  echo "jpn" ;;
        ko)  echo "kor" ;;
        zh)  echo "zho" ;;
        # South / South-East Asian
        hi)  echo "hin" ;;
        th)  echo "tha" ;;
        vi)  echo "vie" ;;
        id)  echo "ind" ;;
        ms)  echo "msa" ;;
        # Middle Eastern / African
        ar)  echo "ara" ;;
        he)  echo "heb" ;;
        tr)  echo "tur" ;;
        fa)  echo "fas" ;;
        # Other European
        el)  echo "ell" ;;
        hu)  echo "hun" ;;
        # Pass through anything already 3-letter or unknown
        *)   echo "$1"  ;;
    esac
}

# Return 0 if lang is in the allowed list (or the list is empty = allow all).
# $1 = language code; $2 (optional) = space-separated allowed list.
# When $2 is omitted, falls back to DESKTOP_VIDEO_AUDIO_LANGS.
# Accepts both ISO 639-1 (2-letter) and ISO 639-2 (3-letter) codes.
_is_lang_allowed() {
    local _lang
    _lang="$(_normalize_lang "$1")"
    local _allowed="${2:-${DESKTOP_VIDEO_AUDIO_LANGS:-}}"
    [[ -z "$_allowed" ]] && return 0
    local _l
    for _l in $_allowed; do
        [[ "$_l" == "$_lang" ]] && return 0
    done
    return 1
}

# Map a 3-letter ISO 639-2 language code to a human-readable display name.
_lang_to_title() {
    case "$1" in
        eng) echo "English" ;;
        ukr) echo "Ukrainian" ;;
        rus) echo "Russian" ;;
        fra|fre) echo "French" ;;
        deu|ger) echo "German" ;;
        spa) echo "Spanish" ;;
        ita) echo "Italian" ;;
        jpn) echo "Japanese" ;;
        kor) echo "Korean" ;;
        chi|zho) echo "Chinese" ;;
        por) echo "Portuguese" ;;
        pol) echo "Polish" ;;
        nld|dut) echo "Dutch" ;;
        *) echo "$1" ;;
    esac
}

# Populate a named array with ffmpeg duration-limit args.
# Only applies a -t limit when DEBUG_VIDEO_TRIM_SECONDS is set to a
# non-zero value (e.g. export DEBUG_VIDEO_TRIM_SECONDS=60 for fast test runs).
# bash 3.2 compatible — uses eval instead of local -n nameref.
# Usage:  local -a _trim=(); _trim_args _trim
_trim_args() {
    local _varname="$1"
    eval "${_varname}=()"
    local _secs="${DEBUG_VIDEO_TRIM_SECONDS:-0}"
    if [[ "$_secs" != "0" && "$_secs" =~ ^[0-9]+$ ]]; then
        eval "${_varname}=(-t \"\$_secs\")"
        debug_log "trim: -t ${_secs}s"
    fi
}

# Skip if output file already exists and is non-empty.
# SKIP_IF_EXISTS=1 (default): returns 0 so the caller skips conversion (incremental mode).
# SKIP_IF_EXISTS=0: deletes the existing file so the caller re-encodes it (overwrite mode).
skip_if_exists() {
    local dest="$1"
    if [[ -f "$dest" && -s "$dest" ]]; then
        # Library CAMERA files are never deleted or replaced, even when corrupt.
        if in_camera_library "$dest"; then
            echo "[KEEP] Camera library file left untouched: $dest" >&2
            return 0
        fi
        # Existing library files are never overwritten (SKIP_IF_EXISTS=0 is
        # ignored). A corrupt file (e.g. a SIGKILL left a moov-less container)
        # is the only thing that gets replaced.
        if ! media_file_valid "$dest"; then
            echo "[WARN] Corrupt output detected, removing for re-conversion: $(basename "$dest")" >&2
            rm -f "$dest"
            return 1
        fi
        debug_log "Skipping existing output: $dest"
        return 0
    fi
    return 1
}

# Ensure staging dir and return staging path for a destination file.
# By default the temp file is staged on the SAME filesystem as the destination
# so that commit_staged is an instant same-fs rename (no cross-device copy) and
# peak disk usage stays on the destination volume — critical when the
# destination is an external card/disk and the system '/' is nearly full.
# When STAGING_ROOT is set, the temp file is staged there instead (on fast local
# disk) so that ffmpeg — including the `+faststart` second pass that rewrites the
# whole file — never runs against a slow/flaky network share; commit_staged then
# copies the finished, valid file to the destination once. Keyed by PID so
# parallel jobs never share a staging dir.
staging_path() {
    local dest="$1"
    local staging_dir
    if [[ -n "${STAGING_ROOT:-}" ]]; then
        staging_dir="${STAGING_ROOT%/}/.media-sync-staging-$$"
    else
        staging_dir="$(dirname "$dest")/.media-sync-staging-$$"
    fi
    mkdir -p "$staging_dir"
    # Remember it (this runs in a $(...) subshell, so a variable would be lost) so
    # the owning script removes it on exit, however it exits.
    printf '%s\n' "$staging_dir" >> "${TMPDIR:-/tmp}/.media-sync-staging-reg-$$" 2>/dev/null || true
    echo "${staging_dir}/$(basename "$dest")"
}

# Remove the staging dirs created by THIS process (name ends with its own PID).
# Installed as an EXIT trap by orginize.sh / portablize.sh, so a failed
# conversion or a stopped sync never leaves .media-sync-staging-* behind.
cleanup_staging_dirs() {
    local reg="${TMPDIR:-/tmp}/.media-sync-staging-reg-$$" d
    [[ -f "$reg" ]] || return 0
    while IFS= read -r d; do
        [[ "$d" == */.media-sync-staging-$$ ]] && rm -rf -- "$d" 2>/dev/null
    done < "$reg"
    rm -f "$reg"
    return 0
}

# Remove staging dirs left by jobs that are no longer running (killed/crashed).
# sweep_stale_staging ROOT... — only dirs whose PID suffix is not a live process.
sweep_stale_staging() {
    local root d pid n=0
    for root in "$@"; do
        [[ -d "$root" ]] || continue
        while IFS= read -r d; do
            pid="${d##*-}"
            [[ "$pid" =~ ^[0-9]+$ ]] || continue
            kill -0 "$pid" 2>/dev/null && continue
            rm -rf -- "$d" 2>/dev/null && n=$(( n + 1 ))
        done < <(find "$root" -maxdepth 4 -type d -name '.media-sync-staging-*' 2>/dev/null)
    done
    (( n > 0 )) && echo "[INFO] Removed ${n} stale staging folder(s)" >&2
    return 0
}

# Move staged file to final destination; verify non-empty.
# An existing valid destination is never overwritten (an empty unique_dest
# placeholder or a corrupt file is replaced). Pass "replace" as $3 only for
# in-place metadata rewrites of a file this run just created.
commit_staged() {
    local staged="$1"
    local dest="$2"
    local mode="${3:-}"
    if [[ ! -f "$staged" || ! -s "$staged" ]]; then
        echo "[ERROR] Staged file missing or empty: $staged" >&2
        return 1
    fi
    mkdir -p "$(dirname "$dest")"
    if in_camera_library "$dest" && [[ -s "$dest" ]]; then
        echo "[KEEP] Camera library file never overwritten: $dest" >&2
        rm -f "$staged" 2>/dev/null || true
        rmdir "$(dirname "$staged")" 2>/dev/null || true
        return 1
    fi
    if [[ "$mode" != "replace" && -s "$dest" ]] && media_file_valid "$dest"; then
        echo "[KEEP] Destination already exists, not overwritten: $dest" >&2
        rm -f "$staged" 2>/dev/null || true
        rmdir "$(dirname "$staged")" 2>/dev/null || true
        return 1
    fi
    rm -f "$dest"
    # Suppress "set owner/group: Operation not permitted" — harmless on ExFAT/NTFS
    # where POSIX ownership is unsupported. The file is moved correctly regardless.
    if mv "$staged" "$dest" 2>/dev/null || { cp "$staged" "$dest" && rm -f "$staged"; }; then
        echo "[OK] Written: $dest" >&2
        # Remove the now-empty staging dir (harmless if it is not one / not empty)
        rmdir "$(dirname "$staged")" 2>/dev/null || true
    else
        echo "[ERROR] Failed to write (disk full?): $dest" >&2
        rm -f "$staged" 2>/dev/null || true
        rmdir "$(dirname "$staged")" 2>/dev/null || true
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Audio conversion
# ---------------------------------------------------------------------------

# Convert any audio file to FLAC (desktop)
convertToFlac() {
    local input="$1"
    local dest="$2"   # full destination file path

    skip_if_exists "$dest" && return 0

    local input_ext="${input##*.}"
    input_ext="$(tr '[:upper:]' '[:lower:]' <<< "$input_ext")"

    # No re-encode if source is already FLAC
    if [[ "$input_ext" == "flac" ]]; then
        mkdir -p "$(dirname "$dest")"
        cp -n "$input" "$dest"
        echo "[OK] Copied FLAC: $dest" >&2
        return 0
    fi

    local staged
    staged="$(staging_path "$dest")"

    debug_log "Converting to FLAC: $input → $staged"
    _ffmpeg_or_fail -y -i "$input" \
        -c:a flac \
        -compression_level "${DESKTOP_AUDIO_FLAC_LEVEL}" \
        "$staged" || return 1

    commit_staged "$staged" "$dest"
}

# Convert any audio file to AAC-LC M4A (portable)
convertToAac() {
    local input="$1"
    local dest="$2"   # full destination file path

    skip_if_exists "$dest" && return 0

    local input_ext="${input##*.}"
    input_ext="$(tr '[:upper:]' '[:lower:]' <<< "$input_ext")"

    # No re-encode if source is already AAC-LC at or above target bitrate
    if [[ "$input_ext" == "m4a" || "$input_ext" == "aac" ]]; then
        local src_codec src_bitrate
        src_codec=$(exiftool -AudioFormat -S -s "$input" 2>/dev/null | head -1 || true)
        src_bitrate=$(exiftool -AudioBitrate -S -s "$input" 2>/dev/null | head -1 | grep -oE '[0-9]+' || echo 0)
        # Strip 'k' suffix from config value for numeric comparison
        local target_kbps="${PORTABLE_AUDIO_BITRATE//k/}"
        if [[ "$src_codec" == *"aac"* || "$src_codec" == *"AAC"* ]] && \
           [[ "$src_bitrate" -ge "$target_kbps" ]]; then
            mkdir -p "$(dirname "$dest")"
            cp -n "$input" "$dest"
            echo "[OK] Copied AAC: $dest" >&2
            return 0
        fi
    fi

    local staged
    staged="$(staging_path "$dest")"

    debug_log "Converting to AAC: $input → $staged"
    _ffmpeg_or_fail -y -i "$input" \
        -map 0:a \
        -c:a libfdk_aac \
        -b:a "${PORTABLE_AUDIO_BITRATE}" \
        -ar "${PORTABLE_AUDIO_RATE}" \
        -ac "${PORTABLE_AUDIO_CHANNELS}" \
        -movflags +faststart \
        "$staged" || return 1

    commit_staged "$staged" "$dest"
}

# ---------------------------------------------------------------------------
# Video conversion
# ---------------------------------------------------------------------------

# Convert video to H.264 High Profile M4V (desktop)
convertToDesktopMp4() {
    local input="$1"
    local dest="$2"   # full destination file path

    skip_if_exists "$dest" && return 0

    local input_ext="${input##*.}"
    input_ext="$(tr '[:upper:]' '[:lower:]' <<< "$input_ext")"

    # Desktop passthrough: if already H.264/HEVC, remux into MP4 container (no quality loss)
    # All audio tracks preserved, English first. Disposition + language atoms set explicitly
    # so that Apple TV / QuickTime show every track (VLC is lenient; native apps are not).
    if command -v ffprobe &>/dev/null; then
        local src_vcodec
        # csv=p=0 can emit a trailing comma (empty extra field) -> take first
        # field and strip whitespace so the equality test below works.
        src_vcodec=$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name \
            -of csv=p=0 "$input" 2>/dev/null | head -1 | cut -d, -f1 | tr -d '[:space:]' || true)
        if [[ "$src_vcodec" == "h264" || "$src_vcodec" == "hevc" ]]; then
            mkdir -p "$(dirname "$dest")"
            local staged
            staged="$(staging_path "$dest")"

            # Probe all audio streams: global index + channel count + language tag
            local _audio_probe
            _audio_probe=$(ffprobe -v error -select_streams a \
                -show_entries stream=index,channels:stream_tags=language \
                -of csv=p=0 "$input" 2>/dev/null) || _audio_probe=""

            # Sort streams: English first, Ukrainian second, rest in original order
            local -a _eng_idx=() _ukr_idx=() _rus_idx=() _other_idx=()
            local -a _eng_lang=() _ukr_lang=() _rus_lang=() _other_lang=()
            local -a _eng_ch=() _ukr_ch=() _rus_ch=() _other_ch=()
            while IFS=',' read -r _sidx _sch _slang; do
                [[ -z "${_sidx// /}" ]] && continue
                local _ll
                _ll="$(tr '[:upper:]' '[:lower:]' <<< "${_slang:-}")"
                _ll="$(_normalize_lang "$_ll")"
                _is_lang_allowed "$_ll" || continue
                [[ "$_sch" =~ ^[0-9]+$ ]] || _sch=2
                case "$_ll" in
                    eng) _eng_idx+=("$_sidx");   _eng_lang+=("${_ll:-eng}");   _eng_ch+=("$_sch") ;;
                    ukr) _ukr_idx+=("$_sidx");   _ukr_lang+=("${_ll:-ukr}");   _ukr_ch+=("$_sch") ;;
                    rus) _rus_idx+=("$_sidx");   _rus_lang+=("${_ll:-rus}");   _rus_ch+=("$_sch") ;;
                    *)   _other_idx+=("$_sidx"); _other_lang+=("${_ll:-und}"); _other_ch+=("$_sch") ;;
                esac
            done <<< "$_audio_probe"

            local -a _sorted_idx=() _sorted_lang=() _sorted_ch=()
            local _si
            for _si in "${!_eng_idx[@]}";   do _sorted_idx+=("${_eng_idx[$_si]}");   _sorted_lang+=("${_eng_lang[$_si]}");   _sorted_ch+=("${_eng_ch[$_si]}");   done
            for _si in "${!_ukr_idx[@]}";   do _sorted_idx+=("${_ukr_idx[$_si]}");   _sorted_lang+=("${_ukr_lang[$_si]}");   _sorted_ch+=("${_ukr_ch[$_si]}");   done
            for _si in "${!_rus_idx[@]}";   do _sorted_idx+=("${_rus_idx[$_si]}");   _sorted_lang+=("${_rus_lang[$_si]}");   _sorted_ch+=("${_rus_ch[$_si]}");   done
            for _si in "${!_other_idx[@]}"; do _sorted_idx+=("${_other_idx[$_si]}"); _sorted_lang+=("${_other_lang[$_si]}"); _sorted_ch+=("${_other_ch[$_si]}"); done

            # Build -map, -disposition:a:N, -metadata:s:a:N args
            # disposition=default on track 0 only — QuickTime/Apple TV require exactly one default
            local -a map_args=("-map" "0:v:0")
            local -a disp_args=()
            local -a meta_args=()
            local -a abr_args=()
            local _pc_kbps="${DESKTOP_VIDEO_AUDIO_KBPS_PER_CHANNEL:-160}"
            local _out_ai=0
            if (( ${#_sorted_idx[@]} > 0 )); then
                for _si in "${!_sorted_idx[@]}"; do
                    map_args+=("-map" "0:${_sorted_idx[$_si]}")
                    # Per-track bitrate = channels × per-channel target (uniform per-channel quality)
                    local _chn="${_sorted_ch[$_si]:-2}"
                    [[ "$_chn" =~ ^[0-9]+$ ]] && (( _chn > 0 )) || _chn=2
                    abr_args+=("-b:a:${_out_ai}" "$(( _pc_kbps * _chn ))k")
                    # Track 0: mark default so QuickTime/Apple TV plays it first.
                    # Track 1+: explicitly clear to 0 so that the source 'default' flag
                    # (present when the source MKV had the track as its first audio stream)
                    # is NOT inherited. Two 'default' tracks in the same alternate group
                    # causes QuickTime to pick by system language and hide the other track.
                    # disposition=0 does NOT disable the track in ffmpeg 4+ / MP4 muxer;
                    # the tkhd enabled bit defaults to 1 for all audio tracks regardless.
                    if (( _out_ai == 0 )); then
                        disp_args+=("-disposition:a:${_out_ai}" "default")
                    else
                        disp_args+=("-disposition:a:${_out_ai}" "0")
                    fi
                    meta_args+=("-metadata:s:a:${_out_ai}" "language=${_sorted_lang[$_si]}")
                    meta_args+=("-metadata:s:a:${_out_ai}" "title=$(_lang_to_title "${_sorted_lang[$_si]}")")
                    (( _out_ai++ )) || true
                done
                debug_log "Desktop passthrough audio order: ${_sorted_idx[*]} langs: ${_sorted_lang[*]}"
            else
                map_args+=("-map" "0:a?")
            fi

            # Check if ALL audio tracks are already AAC (safe to copy without re-encode)
            local _all_aac=1 _acodec
            while IFS= read -r _acodec; do
                [[ -z "$_acodec" ]] && continue
                if [[ "$_acodec" != "aac" && "$_acodec" != "mp4a" ]]; then
                    _all_aac=0; break
                fi
            done < <(ffprobe -v error -select_streams a \
                -show_entries stream=codec_name -of csv=p=0 "$input" 2>/dev/null)

            local -a _trim=()
            _trim_args _trim

            if [[ "$_all_aac" == "1" ]]; then
                # Pure remux: video + all audio already MP4-compatible, zero re-encode
                # -f mp4 forces the mp4 muxer; .m4v extension would pick 'ipod' which rejects HEVC
                # -fflags +igndts: derive DTS from PTS to suppress non-monotonic DTS warnings
                _ffmpeg_or_fail -y -fflags +igndts -i "$input" \
                    "${map_args[@]}" \
                    ${disp_args[@]+"${disp_args[@]}"} \
                    ${meta_args[@]+"${meta_args[@]}"} \
                    ${_trim[@]+"${_trim[@]}"} \
                    -c copy -movflags +faststart -f mp4 "$staged" || return 1
            else
                # Video copy, re-encode all audio tracks to AAC.
                # Per-track bitrate scales with channel count (abr_args) so every
                # channel keeps stereo-at-320k quality. Falls back to the global
                # bitrate only when the stream probe yielded no per-track channel data.
                # -f mp4 forces the mp4 muxer; .m4v extension would pick 'ipod' which rejects HEVC
                # -fflags +igndts: derive DTS from PTS to suppress non-monotonic DTS warnings
                local -a _abr=()
                if (( ${#abr_args[@]} > 0 )); then
                    _abr=("${abr_args[@]}")
                else
                    _abr=("-b:a" "${DESKTOP_VIDEO_AUDIO_BITRATE}")
                fi
                _ffmpeg_or_fail -y -fflags +igndts -i "$input" \
                    "${map_args[@]}" \
                    ${disp_args[@]+"${disp_args[@]}"} \
                    ${meta_args[@]+"${meta_args[@]}"} \
                    ${_trim[@]+"${_trim[@]}"} \
                    -c:v copy \
                    -c:a "${DESKTOP_VIDEO_AUDIO_CODEC}" \
                    "${_abr[@]}" \
                    -ar "${DESKTOP_VIDEO_AUDIO_RATE}" \
                    -movflags +faststart -f mp4 "$staged" || return 1
            fi
            commit_staged "$staged" "$dest"
            echo "[OK] Remuxed desktop (no re-encode): $dest" >&2
            return 0
        fi
    fi

    local staged
    staged="$(staging_path "$dest")"

    # Build explicit audio map: all tracks, English first, Ukrainian second, rest after
    local -a map_args=("-map" "0:v:0")
    local _stream_order
    if _stream_order="$(_audio_stream_order "$input")"; then
        local -a _streams
        read -ra _streams <<< "$_stream_order"
        for _idx in "${_streams[@]}"; do
            map_args+=("-map" "0:${_idx}")
        done
        debug_log "Desktop audio stream order (global indices): ${_streams[*]}"
    else
        map_args+=("-map" "0:a?")
    fi

    local -a _trim=()
    _trim_args _trim

    debug_log "Converting to desktop MP4: $input → $staged"
    _ffmpeg_or_fail -y -i "$input" \
        "${map_args[@]}" \
        ${_trim[@]+"${_trim[@]}"} \
        -c:v "${DESKTOP_VIDEO_CODEC}" \
        -profile:v "${DESKTOP_VIDEO_PROFILE}" \
        -pix_fmt yuv420p \
        -crf "${DESKTOP_VIDEO_CRF}" \
        -preset "${DESKTOP_VIDEO_PRESET}" \
        -c:a "${DESKTOP_VIDEO_AUDIO_CODEC}" \
        -b:a "${DESKTOP_VIDEO_AUDIO_BITRATE}" \
        -ar "${DESKTOP_VIDEO_AUDIO_RATE}" \
        -ac 2 \
        -movflags +faststart \
        "$staged" || return 1

    commit_staged "$staged" "$dest"
}

# Convert video to H.264 Baseline 320×240 MP4 (portable, Sony NWZ-A720)
convertToPortableMp4() {
    local input="$1"
    local dest="$2"   # full destination file path

    skip_if_exists "$dest" && return 0

    local W="${PORTABLE_VIDEO_WIDTH}"
    local H="${PORTABLE_VIDEO_HEIGHT}"
    local staged
    staged="$(staging_path "$dest")"

    # Include all allowed audio tracks, English first then Ukrainian then rest —
    # same ordering as desktop so the player default track is always English.
    local -a audio_map=("-map" "0:v:0")
    local -a p_disp_args=() p_meta_args=()
    if command -v ffprobe &>/dev/null; then
        local _p_probe
        _p_probe=$(ffprobe -v error -select_streams a \
            -show_entries stream=index:stream_tags=language \
            -of csv=p=0 "$input" 2>/dev/null) || _p_probe=""

        local -a _p_eng_idx=() _p_ukr_idx=() _p_rus_idx=() _p_other_idx=()
        local -a _p_eng_lang=() _p_ukr_lang=() _p_rus_lang=() _p_other_lang=()
        local _p_sidx _p_slang _p_ll
        while IFS=',' read -r _p_sidx _p_slang; do
            [[ -z "${_p_sidx// /}" ]] && continue
            _p_ll="$(tr '[:upper:]' '[:lower:]' <<< "${_p_slang:-}")"
            _p_ll="$(_normalize_lang "$_p_ll")"
            _is_lang_allowed "$_p_ll" "${PORTABLE_VIDEO_AUDIO_LANGS:-}" || continue
            case "$_p_ll" in
                eng) _p_eng_idx+=("$_p_sidx");   _p_eng_lang+=("${_p_ll:-eng}") ;;
                ukr) _p_ukr_idx+=("$_p_sidx");   _p_ukr_lang+=("${_p_ll:-ukr}") ;;
                rus) _p_rus_idx+=("$_p_sidx");   _p_rus_lang+=("${_p_ll:-rus}") ;;
                *)   _p_other_idx+=("$_p_sidx"); _p_other_lang+=("${_p_ll:-und}") ;;
            esac
        done <<< "$_p_probe"

        # Keep at most N tracks per language (default 1). The portable device
        # plays a single audio track at a time; retaining every dub/commentary
        # track needlessly multiplies file size and can breach the 2 GB device
        # file-size limit. First track per language = the primary (commentary
        # tracks are muxed after the main track).
        local _p_max_per_lang="${PORTABLE_VIDEO_AUDIO_TRACKS_PER_LANG:-1}"
        local -a _p_sorted_idx=() _p_sorted_lang=()
        local _psi _pn
        _pn=0; for _psi in "${!_p_eng_idx[@]}";   do (( _pn < _p_max_per_lang )) || break; _p_sorted_idx+=("${_p_eng_idx[$_psi]}");   _p_sorted_lang+=("${_p_eng_lang[$_psi]}");   (( _pn++ )) || true; done
        _pn=0; for _psi in "${!_p_ukr_idx[@]}";   do (( _pn < _p_max_per_lang )) || break; _p_sorted_idx+=("${_p_ukr_idx[$_psi]}");   _p_sorted_lang+=("${_p_ukr_lang[$_psi]}");   (( _pn++ )) || true; done
        _pn=0; for _psi in "${!_p_rus_idx[@]}";   do (( _pn < _p_max_per_lang )) || break; _p_sorted_idx+=("${_p_rus_idx[$_psi]}");   _p_sorted_lang+=("${_p_rus_lang[$_psi]}");   (( _pn++ )) || true; done
        _pn=0; for _psi in "${!_p_other_idx[@]}"; do (( _pn < _p_max_per_lang )) || break; _p_sorted_idx+=("${_p_other_idx[$_psi]}"); _p_sorted_lang+=("${_p_other_lang[$_psi]}"); (( _pn++ )) || true; done

        if (( ${#_p_sorted_idx[@]} > 0 )); then
            local _p_out_ai=0
            for _psi in "${!_p_sorted_idx[@]}"; do
                audio_map+=("-map" "0:${_p_sorted_idx[$_psi]}")
                if (( _p_out_ai == 0 )); then
                    p_disp_args+=("-disposition:a:${_p_out_ai}" "default")
                else
                    p_disp_args+=("-disposition:a:${_p_out_ai}" "0")
                fi
                p_meta_args+=("-metadata:s:a:${_p_out_ai}" "language=${_p_sorted_lang[$_psi]}")
                p_meta_args+=("-metadata:s:a:${_p_out_ai}" "title=$(_lang_to_title "${_p_sorted_lang[$_psi]}")")
                (( _p_out_ai++ )) || true
            done
            debug_log "Portable audio streams: ${_p_sorted_idx[*]} langs: ${_p_sorted_lang[*]}"
        else
            echo "[WARN] No audio track matched PORTABLE_VIDEO_AUDIO_LANGS=\"${PORTABLE_VIDEO_AUDIO_LANGS}\"; falling back to first audio track." >&2
            audio_map+=("-map" "0:a:0")
        fi
    else
        audio_map+=("-map" "0:a:0")
    fi

    local -a _trim=()
    _trim_args _trim

    # Only downscale — never upscale. Read source dimensions and skip the
    # scale/pad filter entirely when the video already fits within the target.
    # Also detect HDR transfer function for tone mapping.
    local _src_vw _src_vh _src_color_trc
    _src_vw=$(ffprobe -v error -select_streams v:0 \
        -show_entries stream=width  -of csv=p=0 "$input" 2>/dev/null | head -1 | tr -dc '0-9')
    _src_vh=$(ffprobe -v error -select_streams v:0 \
        -show_entries stream=height -of csv=p=0 "$input" 2>/dev/null | head -1 | tr -dc '0-9')
    _src_color_trc=$(ffprobe -v error -select_streams v:0 \
        -show_entries stream=color_transfer -of csv=p=0 "$input" 2>/dev/null | head -1)

    local _scale_filter="" _hdr_filter=""
    if [[ -n "$_src_vw" && -n "$_src_vh" ]] && (( _src_vw > W || _src_vh > H )); then
        debug_log "Downscaling portable video ${_src_vw}x${_src_vh} → ${W}x${H}: $input"
        _scale_filter="scale=${W}:${H}:force_original_aspect_ratio=decrease,pad=${W}:${H}:(ow-iw)/2:(oh-ih)/2"
    elif [[ -z "$_src_vw" || -z "$_src_vh" ]]; then
        debug_log "Could not read source dimensions; applying scale filter as fallback: $input"
        _scale_filter="scale=${W}:${H}:force_original_aspect_ratio=decrease,pad=${W}:${H}:(ow-iw)/2:(oh-ih)/2"
    else
        debug_log "Portable video ${_src_vw}x${_src_vh} fits within ${W}x${H} — no upscale: $input"
    fi

    # HDR→SDR tone mapping (PQ/HLG → BT.709 SDR via zscale+tonemap).
    # setparams at the end clears all color metadata so the output SPS has no
    # color VUI — identical to SDR-source output (color_range/space/trc=unknown).
    if [[ "${PORTABLE_VIDEO_FORCE_SDR:-1}" == "1" ]]; then
        case "${_src_color_trc:-}" in
            smpte2084|arib-std-b67)
                debug_log "HDR source (trc=${_src_color_trc}); applying tone mapping: $input"
                _hdr_filter="zscale=transfer=linear:npl=${PORTABLE_VIDEO_TONEMAP_NPL:-100},format=gbrpf32le,zscale=p=bt709,tonemap=${PORTABLE_VIDEO_TONEMAP_ALG:-hable}:desat=${PORTABLE_VIDEO_TONEMAP_DESAT:-0},zscale=t=bt709:m=bt709:r=tv,format=yuv420p,setparams=color_primaries=unknown:color_trc=unknown:colorspace=unknown:range=unknown,sidedata=mode=delete:type=MASTERING_DISPLAY_METADATA,sidedata=mode=delete:type=CONTENT_LIGHT_LEVEL"
                ;;
        esac
    fi

    # Expand to full range (0-255) for players that assume it (Sony Walkman);
    # limited-range pixels otherwise render washed out with grey blacks.
    local _range_filter=""
    local -a _range_tag=()
    if [[ "${PORTABLE_VIDEO_FULL_RANGE:-1}" == "1" ]]; then
        _range_filter="scale=in_range=auto:out_range=pc"
        _range_tag=(-color_range pc)
    fi

    local -a _vf_args=()
    local _vf_chain="" _f
    for _f in "$_scale_filter" "$_hdr_filter" "$_range_filter"; do
        [[ -z "$_f" ]] && continue
        _vf_chain="${_vf_chain:+${_vf_chain},}${_f}"
    done
    [[ -n "$_vf_chain" ]] && _vf_args=("-vf" "$_vf_chain")

    debug_log "Converting to portable MP4 (max ${W}x${H}): $input → $staged"
    _ffmpeg_or_fail -y -i "$input" \
        "${audio_map[@]}" \
        ${p_disp_args[@]+"${p_disp_args[@]}"} \
        ${p_meta_args[@]+"${p_meta_args[@]}"} \
        -map_chapters 0 \
        ${_trim[@]+"${_trim[@]}"} \
        ${_vf_args[@]+"${_vf_args[@]}"} \
        -c:v "${PORTABLE_VIDEO_CODEC}" \
        -profile:v "${PORTABLE_VIDEO_PROFILE}" \
        -level "${PORTABLE_VIDEO_LEVEL}" \
        -pix_fmt yuv420p \
        ${_range_tag[@]+"${_range_tag[@]}"} \
        -crf "${PORTABLE_VIDEO_CRF}" \
        -maxrate "${PORTABLE_VIDEO_MAXRATE}" \
        -bufsize "${PORTABLE_VIDEO_BUFSIZE}" \
        -r "${PORTABLE_VIDEO_FPS}" \
        -refs "${PORTABLE_VIDEO_REFS}" \
        -bf "${PORTABLE_VIDEO_BFRAMES}" \
        -af "aresample=async=1:min_hard_comp=0.100000:first_pts=0" \
        -c:a "${PORTABLE_VIDEO_AUDIO_CODEC}" \
        -b:a "${PORTABLE_VIDEO_AUDIO_BITRATE}" \
        -ar "${PORTABLE_VIDEO_AUDIO_RATE}" \
        -ac 2 \
        -movflags +faststart -f mp4 \
        "$staged" || return 1

    commit_staged "$staged" "$dest"
}

# ---------------------------------------------------------------------------
# Photo conversion
# ---------------------------------------------------------------------------

# Convert RAW / HEIC / JPEG to full-quality JPEG (desktop)
convertToDesktopJpeg() {
    local input="$1"
    local dest="$2"   # full destination path including filename

    skip_if_exists "$dest" && return 0

    local input_ext="${input##*.}"
    input_ext="$(tr '[:upper:]' '[:lower:]' <<< "$input_ext")"
    local staged
    staged="$(staging_path "$dest")"
    mkdir -p "$(dirname "$staged")"

    case "$input_ext" in
        jpg|jpeg)
            # No re-compression; just copy and ensure DateTimeOriginal is set
            cp -n "$input" "$staged"
            ;;
        png|bmp|webp|heic|heif|avif|orf|rw2|cr2|nef|arw|dng|tiff|tif|psd)
            # Convert to JPEG (sips on macOS, ImageMagick on Linux)
            debug_log "image→JPEG desktop: $input"
            _quiet image_to_jpeg "$input" "$staged" "${DESKTOP_PHOTO_QUALITY}"
            # Restore all EXIF from original (-m suppresses "Maker notes could not be parsed" minor warning)
            _quiet exiftool -m -overwrite_original -TagsFromFile "$input" \
                -all:all \
                "$staged" || true
            ;;
        *)
            echo "[WARN] Unsupported photo format for desktop: $input" >&2
            rm -f "$staged"
            return 1
            ;;
    esac

    # Ensure DateTimeOriginal is present; attempt to derive from filename
    local has_dt
    has_dt=$(exiftool -DateTimeOriginal -S -s "$staged" 2>/dev/null | head -1)
    if [[ -z "$has_dt" ]]; then
        local bn
        bn="$(basename "$input")"
        if [[ "$bn" =~ ([0-9]{4})-?([0-9]{2})-?([0-9]{2}) ]]; then
            local dt="${BASH_REMATCH[1]}:${BASH_REMATCH[2]}:${BASH_REMATCH[3]} 00:00:00"
            exiftool -overwrite_original -DateTimeOriginal="$dt" "$staged" &>/dev/null || true
        else
            echo "[WARN] DateTimeOriginal absent and not derivable for: $input" >&2
        fi
    fi

    # Bake EXIF orientation into the pixels (portrait shots) and normalise the
    # tag, so the image displays upright on every viewer. Must run AFTER the
    # metadata restore above (which re-imports the original Orientation tag).
    _quiet image_auto_orient "$staged"

    debug_log "Desktop JPEG ready: $dest"
    commit_staged "$staged" "$dest"
}

# Convert to scaled JPEG (portable, Sony NWZ-A720)
convertToPortableJpeg() {
    local input="$1"
    local dest="$2"   # full destination path including filename

    skip_if_exists "$dest" && return 0

    local input_ext="${input##*.}"
    input_ext="$(tr '[:upper:]' '[:lower:]' <<< "$input_ext")"
    local staged
    staged="$(staging_path "$dest")"
    local thumb_path="${staged}.thumb.jpg"
    mkdir -p "$(dirname "$staged")"

    # Step 1: produce a temporary full-size JPEG (reuse desktop logic on a temp file)
    local tmp_full="${staged}.full.jpg"
    case "$input_ext" in
        jpg|jpeg)
            cp "$input" "$tmp_full"
            ;;
        png|bmp|webp|heic|heif|avif|orf|rw2|cr2|nef|arw|dng|tiff|tif|psd)
            debug_log "image→JPEG portable (tmp): $input"
            _quiet image_to_jpeg "$input" "$tmp_full" 95
            _quiet exiftool -m -overwrite_original -TagsFromFile "$input" \
                -all:all "$tmp_full" || true
            ;;
        *)
            echo "[WARN] Unsupported photo format for portable: $input" >&2
            return 1
            ;;
    esac

    # Step 2: scale down to longest edge — never upscale
    local _src_w _src_h _src_longest _src_dims
    _src_dims="$(image_dimensions "$tmp_full")"
    _src_w="${_src_dims%% *}"
    _src_h="${_src_dims##* }"
    [[ "$_src_w" =~ ^[0-9]+$ ]] || _src_w=0
    [[ "$_src_h" =~ ^[0-9]+$ ]] || _src_h=0
    _src_longest=$(( _src_w > _src_h ? _src_w : _src_h ))
    if (( _src_longest > PORTABLE_PHOTO_LONGEST_EDGE )); then
        debug_log "Scaling portable photo ${_src_longest}px → ${PORTABLE_PHOTO_LONGEST_EDGE}px: $staged"
        _quiet image_scale_jpeg "$tmp_full" "$staged" "${PORTABLE_PHOTO_LONGEST_EDGE}" "${PORTABLE_PHOTO_QUALITY}"
    else
        debug_log "Portable photo ${_src_longest}px ≤ ${PORTABLE_PHOTO_LONGEST_EDGE}px — no upscale, copy as-is: $staged"
        _quiet image_to_jpeg "$tmp_full" "$staged" "${PORTABLE_PHOTO_QUALITY}"
    fi

    # Step 3: copy all metadata from source (same as desktop)
    _quiet exiftool -m -overwrite_original \
        -TagsFromFile "$input" \
        -all:all \
        "$staged" || true

    # Bake EXIF orientation into the pixels + normalise the tag, so portrait
    # shots display upright even on players that ignore the orientation tag.
    # Runs after the restore (which re-imports the original Orientation tag) and
    # before the thumbnail below, so the embedded thumbnail is upright too.
    _quiet image_auto_orient "$staged"

    # Step 4: generate 96×96 thumbnail and embed it
    _quiet image_scale_jpeg "$staged" "$thumb_path" "${PORTABLE_PHOTO_THUMB_SIZE}" 85
    _quiet exiftool -m -overwrite_original \
        "-ThumbnailImage<=${thumb_path}" \
        "$staged" || true

    rm -f "$tmp_full" "$thumb_path"
    commit_staged "$staged" "$dest"
}

# ---------------------------------------------------------------------------
# Main dispatch (when called as a script)
# ---------------------------------------------------------------------------

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    if [[ $# -lt 3 ]]; then
        echo "Usage: $0 <filePath> <tier> <destDir>" >&2
        exit 1
    fi

    FILE_PATH="$1"
    TIER="$2"
    DEST_DIR="$3"

    if [[ ! -f "$FILE_PATH" ]]; then
        echo "[ERROR] File not found: $FILE_PATH" >&2
        exit 1
    fi

    EXT="${FILE_PATH##*.}"
    EXT="$(tr '[:upper:]' '[:lower:]' <<< "$EXT")"

    case "$EXT" in
        flac|mp3|m4a|m4b|aac|ogg|opus|wav|aiff|wv|ape|mka|wma|caf|mp2)
            BASE="$(basename "${FILE_PATH%.*}")"
            if [[ "$TIER" == "desktop" ]]; then
                convertToFlac "$FILE_PATH" "${DEST_DIR}/${BASE}.flac"
            else
                convertToAac "$FILE_PATH" "${DEST_DIR}/${BASE}.m4a"
            fi
            ;;
        mp4|mov|avi|mkv|mpeg|avc|m4v|m2v|wmv|ts|m2ts|mts|flv|webm|ogv|3gp|3g2|vob|asf)
            BASE="$(basename "${FILE_PATH%.*}")"
            if [[ "$TIER" == "desktop" ]]; then
                convertToDesktopMp4 "$FILE_PATH" "${DEST_DIR}/${BASE}.m4v"
            else
                convertToPortableMp4 "$FILE_PATH" "${DEST_DIR}/${BASE}.m4v"
            fi
            ;;
        jpg|jpeg|png|bmp|webp|heic|heif|avif|orf|rw2|cr2|nef|arw|dng|tiff|tif|psd)
            DEST_FILE="${DEST_DIR}/$(basename "${FILE_PATH%.*}").jpg"
            if [[ "$TIER" == "desktop" ]]; then
                convertToDesktopJpeg "$FILE_PATH" "$DEST_FILE"
            else
                convertToPortableJpeg "$FILE_PATH" "$DEST_FILE"
            fi
            ;;
        *)
            echo "[WARN] Unknown extension '$EXT', skipping: $FILE_PATH" >&2
            exit 0
            ;;
    esac
fi
