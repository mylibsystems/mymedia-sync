#!/usr/bin/env bash
# config.sh — shared configuration for the v2 media library system
# Sourced by all other scripts; never executed directly.

# ---------------------------------------------------------------------------
# Script directory (base for all relative paths)
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# Cross-platform compatibility layer (macOS + Linux)
# Provides: OS_NAME, cpu_count, image_* wrappers (sips ⇄ ImageMagick)
# ---------------------------------------------------------------------------
source "${SCRIPT_DIR}/platform.sh"

# ---------------------------------------------------------------------------
# ffmpeg binary used for ENCODING — must have libfdk_aac (exact v2 AAC parity).
# build-ffmpeg.sh installs a libfdk_aac build into ./.ffmpeg; if that is absent we
# fall back to a PATH ffmpeg (which may lack libfdk_aac, in which case encoding
# fails until the build is run). ffprobe / decoding elsewhere use system ffmpeg.
# ---------------------------------------------------------------------------
FFMPEG_BIN="${FFMPEG_BIN:-${SCRIPT_DIR}/.ffmpeg/bin/ffmpeg}"
[[ -x "$FFMPEG_BIN" ]] || FFMPEG_BIN="ffmpeg"
export FFMPEG_BIN

# ---------------------------------------------------------------------------
# Source / Inbox paths
# ---------------------------------------------------------------------------
# MEDIA_PATH can be passed as a CLI argument to sync.sh (e.g. MEDIA_PATH=/Volumes/WD-RED).
# Main library root: the router SMB share, which holds UNSORTED (inbox) plus the
# LIBRARY.DESKTOP / LIBRARY.PORTABLE output trees. Override from the environment
# or a `MEDIA_PATH=<dir>` CLI argument to point at a different drive.
MEDIA_PATH="${MEDIA_PATH:-/mnt/router-smb}"
UNSORTED_ROOT="${MEDIA_PATH}/UNSORTED"

CAMERA_SOURCE="${UNSORTED_ROOT}/CAMERA"
DOWNLOADS_SOURCE="${UNSORTED_ROOT}/DOWNLOADS"
MUSIC_SOURCE="${UNSORTED_ROOT}/MUSIC"
MOVIES_SOURCE="${UNSORTED_ROOT}/MOVIES"
TV_SOURCE="${UNSORTED_ROOT}/TV"
PHOTOS_SOURCE="${UNSORTED_ROOT}/PHOTOS"
VIDEO_SOURCE="${UNSORTED_ROOT}/VIDEO"

# ---------------------------------------------------------------------------
# Library destination roots
# ---------------------------------------------------------------------------
# Each root defaults to a subfolder of MEDIA_PATH but can be overridden
# individually from the environment, so the output can be written to a drive
# with free space while the source (UNSORTED) stays on another drive, e.g.:
#     DESKTOP_MOVIES_ROOT=/run/media/roman/MEDIA/LIBRARY.DESKTOP/MOVIES \
#         ENABLE_PORTABLE=0 ./sync.sh movies
DESKTOP_MUSIC_ROOT="${DESKTOP_MUSIC_ROOT:-${MEDIA_PATH}/LIBRARY.DESKTOP/MUSIC}"
DESKTOP_MOVIES_ROOT="${DESKTOP_MOVIES_ROOT:-${MEDIA_PATH}/LIBRARY.DESKTOP/MOVIES}"
DESKTOP_TV_ROOT="${DESKTOP_TV_ROOT:-${MEDIA_PATH}/LIBRARY.DESKTOP/TV}"
DESKTOP_PHOTOS_ROOT="${DESKTOP_PHOTOS_ROOT:-${MEDIA_PATH}/LIBRARY.DESKTOP/PHOTOS}"
DESKTOP_CAMERA_ROOT="${DESKTOP_CAMERA_ROOT:-${MEDIA_PATH}/LIBRARY.DESKTOP/CAMERA}"

PORTABLE_MUSIC_ROOT="${PORTABLE_MUSIC_ROOT:-${MEDIA_PATH}/LIBRARY.PORTABLE/MUSIC}"
PORTABLE_MOVIES_ROOT="${PORTABLE_MOVIES_ROOT:-${MEDIA_PATH}/LIBRARY.PORTABLE/MOVIES}"
PORTABLE_TV_ROOT="${PORTABLE_TV_ROOT:-${MEDIA_PATH}/LIBRARY.PORTABLE/TV}"
PORTABLE_PHOTOS_ROOT="${PORTABLE_PHOTOS_ROOT:-${MEDIA_PATH}/LIBRARY.PORTABLE/PHOTOS}"

# ---------------------------------------------------------------------------
# Output tiers — which library trees to produce
# ---------------------------------------------------------------------------
# Each import can emit a desktop (hi-fi) output and/or a portable (Sony Walkman)
# output. Disable a tier to skip its conversions entirely — e.g. a desktop-only
# run that skips every portable/Walkman encode:
#     ENABLE_PORTABLE=0 ./sync.sh movies
# Incremental skip-detection and output verification only consider the enabled
# tiers. At least one tier must remain enabled.
ENABLE_DESKTOP="${ENABLE_DESKTOP:-1}"
ENABLE_PORTABLE="${ENABLE_PORTABLE:-1}"
if [[ "$ENABLE_DESKTOP" != "1" && "$ENABLE_PORTABLE" != "1" ]]; then
    echo "[ERROR] ENABLE_DESKTOP and ENABLE_PORTABLE cannot both be 0." >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Filename sanitization & length limits  (sanitize_name / truncate_utf8 /
# walkman_sanitize_path in metadata.sh + orginize.sh)
# ---------------------------------------------------------------------------
# Characters that are unsafe in a filename / directory component. Every match is
# replaced with FILENAME_REPLACEMENT by sanitize_name(). This is the *body* of a
# bash bracket expression — list the literal characters, no surrounding [ ].
# (Default set is reserved on Windows/exFAT/VFAT as well as macOS: : / ? * " < > |)
FILENAME_UNSAFE_CHARS="${FILENAME_UNSAFE_CHARS-:/?*\"<>|}"
FILENAME_REPLACEMENT="${FILENAME_REPLACEMENT--}"

# Desktop component limit — APFS / exFAT NAME_MAX is 255 *bytes* (a Cyrillic char
# is 2 bytes, so this is measured in bytes, not characters). The music track title
# is byte-truncated to fit this before the filename is built; exceeding it makes
# `cp` fail with "File name too long".
DESKTOP_FILENAME_MAX_BYTES="${DESKTOP_FILENAME_MAX_BYTES:-255}"

# Portable (Sony Walkman, FAT32/VFAT) limits.
#   PORTABLE_FILENAME_MAX_CHARS — FAT32 LFN cap (255 UTF-16 units ≈ characters)
#   PORTABLE_PATH_MAX_CHARS     — advisory total-path warning threshold
#   PORTABLE_MAX_DEPTH          — max folder depth below the MUSIC/VIDEO/PHOTOS root
PORTABLE_FILENAME_MAX_CHARS="${PORTABLE_FILENAME_MAX_CHARS:-255}"
PORTABLE_PATH_MAX_CHARS="${PORTABLE_PATH_MAX_CHARS:-260}"
PORTABLE_MAX_DEPTH="${PORTABLE_MAX_DEPTH:-8}"

# ---------------------------------------------------------------------------
# Audio — Desktop (FLAC)
# ---------------------------------------------------------------------------
DESKTOP_AUDIO_FORMAT="flac"
DESKTOP_AUDIO_FLAC_LEVEL=8          # 0-12; 8 = best compression

# ---------------------------------------------------------------------------
# Audio — Portable (AAC-LC, Sony NWZ-A720)
# ---------------------------------------------------------------------------
PORTABLE_AUDIO_FORMAT="m4a"
PORTABLE_AUDIO_BITRATE="640k"
PORTABLE_AUDIO_RATE=48000           # Hz
PORTABLE_AUDIO_CHANNELS=2

# ---------------------------------------------------------------------------
# Audio — compilation grouping
# ---------------------------------------------------------------------------
# Canonical album-artist used for multi-artist compilations. When a source
# folder is explicitly named "Various Artists" / "VA" / "Compilation" etc.,
# all of its tracks are filed under this single album-artist (so the album
# stays in ONE folder instead of being scattered one-track-per-performer).
COMPILATION_ALBUM_ARTIST="${COMPILATION_ALBUM_ARTIST:-Various Artists}"

# Album name used for tracks that sit directly inside an artist folder with no
# album subfolder (flat "artist/track" layout) and carry no album tag.
SINGLES_ALBUM="${SINGLES_ALBUM:-Singles}"

# Genre written when no genre can be resolved from the source tags or an online
# lookup. The track is still imported (import-anyway policy); the gap is logged
# as a [WARN] for audit.
GENRE_FALLBACK="${GENRE_FALLBACK:-Unknown}"

# ---------------------------------------------------------------------------
# Video — Desktop (H.264 High Profile)
# ---------------------------------------------------------------------------
# Whitespace-separated list of ISO 639-2 language codes to KEEP in desktop video.
# Tracks in any other language are dropped from the output.
# Leave empty to keep all tracks.
DESKTOP_VIDEO_AUDIO_LANGS="eng ukr rus"

DESKTOP_VIDEO_CODEC="libx264"
DESKTOP_VIDEO_PROFILE="high"
DESKTOP_VIDEO_CRF=12          # Quality-based encode: lower = better quality and larger file size; 18-23 is a reasonable range for good quality; 12 is visually lossless.
DESKTOP_VIDEO_PRESET="slow"
DESKTOP_VIDEO_AUDIO_CODEC="libfdk_aac"
DESKTOP_VIDEO_AUDIO_BITRATE="320k"     # Fallback bitrate when per-stream channel count is unknown
# Per-channel target bitrate. Each re-encoded audio track is given
# (channels × this) kbps so every channel keeps the same quality as a stereo
# track at 320k (160 kbps/channel): mono=160k, stereo=320k, 5.1=960k, 7.1=1280k.
DESKTOP_VIDEO_AUDIO_KBPS_PER_CHANNEL=160
DESKTOP_VIDEO_AUDIO_RATE=48000

# ---------------------------------------------------------------------------
# Video — Portable (H.264 Baseline, Sony NWZ-A720)
# ---------------------------------------------------------------------------
PORTABLE_VIDEO_CODEC="libx264"
PORTABLE_VIDEO_PROFILE="baseline"
PORTABLE_VIDEO_LEVEL="1.3"         # Walkman supports AVC Baseline up to Level 1.3
PORTABLE_VIDEO_WIDTH=320           # Walkman max QVGA 320×240
PORTABLE_VIDEO_HEIGHT=240
PORTABLE_VIDEO_CRF=16              # High quality at QVGA; 768k VBV cap below guarantees spec compliance
PORTABLE_VIDEO_MAXRATE="768k"      # Hard cap: Walkman AVC Baseline L1.3 decoder max 768 kbps
PORTABLE_VIDEO_BUFSIZE="768k"      # VBV buffer = 1s (tight, strict per-second cap ≤768k)
PORTABLE_VIDEO_FPS=30              # Walkman max 30 fps
PORTABLE_VIDEO_REFS=1              # Baseline Profile: 1 ref frame
PORTABLE_VIDEO_BFRAMES=0           # Baseline Profile: no B-frames
PORTABLE_VIDEO_AUDIO_CODEC="libfdk_aac"
PORTABLE_VIDEO_AUDIO_BITRATE="288k" # Walkman AAC-LC max 288 kbps/ch; 288k stereo, within spec, max quality
PORTABLE_VIDEO_AUDIO_RATE=48000    # Walkman max 48 kHz
# Whitespace-separated list of ISO 639-2 language codes to keep in portable video.
# Leave empty to keep all tracks.
PORTABLE_VIDEO_AUDIO_LANGS="eng ukr rus"
# Max audio tracks kept PER LANGUAGE in portable video (device plays one track
# at a time; keeping every dub/commentary bloats the file past the 2 GB limit).
PORTABLE_VIDEO_AUDIO_TRACKS_PER_LANG=1

# Force SDR output for portable video: detect HDR sources (PQ/HLG) and apply
# tone mapping + tag output as BT.709 SDR. Required for devices like the Sony
# Walkman that do not support HDR. 1 = enabled (default); 0 = pass through.
PORTABLE_VIDEO_FORCE_SDR="${PORTABLE_VIDEO_FORCE_SDR:-1}"
# Output full-range (0-255) luma and tag it as such. Old players like the Sony
# Walkman assume full range and render limited-range (16-235) video washed out
# with grey blacks and low contrast. 1 = full range (default); 0 = keep limited.
PORTABLE_VIDEO_FULL_RANGE="${PORTABLE_VIDEO_FULL_RANGE:-1}"
# Tone-mapping algorithm passed to the ffmpeg tonemap filter.
# Options: hable (default), reinhard, mobius, aces, gamma, linear, clip.
PORTABLE_VIDEO_TONEMAP_ALG="${PORTABLE_VIDEO_TONEMAP_ALG:-hable}"
# Nominal peak luminance (nits) used by zscale when linearising HDR.
PORTABLE_VIDEO_TONEMAP_NPL="${PORTABLE_VIDEO_TONEMAP_NPL:-100}"
# Desaturation coefficient for the tonemap filter (0 = no desaturation).
PORTABLE_VIDEO_TONEMAP_DESAT="${PORTABLE_VIDEO_TONEMAP_DESAT:-0}"

# Whether to create a per-episode sidecar <filename>.jpg next to portable video files.
# Required for the Sony Walkman file browser to display video thumbnails.
# 1 = create (default); 0 = skip.
PORTABLE_VIDEO_SIDECAR_THUMB="${PORTABLE_VIDEO_SIDECAR_THUMB:-1}"
# Size of the sidecar thumbnail — portrait, matching typical poster art ratio.
# Sony recommends ~240x320 for the Walkman file browser (not the video frame size).
PORTABLE_VIDEO_SIDECAR_THUMB_WIDTH=240
PORTABLE_VIDEO_SIDECAR_THUMB_HEIGHT=320

# ---------------------------------------------------------------------------
# Photos — Desktop (JPEG full quality)
# ---------------------------------------------------------------------------
# Source JPEGs are copied as-is (no re-encode). This quality value is only
# used when converting non-JPEG sources (RAW, HEIC, PNG, etc.) to JPEG.
# 95 is the archival sweet spot: visually lossless, smaller than 99, and
# avoids inflating HEIC sources (HEIC/HEVC is ~2× more efficient than JPEG).
DESKTOP_PHOTO_QUALITY=95

# ---------------------------------------------------------------------------
# Photos — Portable (JPEG scaled, Sony NWZ-A720)
# ---------------------------------------------------------------------------
PORTABLE_PHOTO_QUALITY=80          # Reasonable quality for a portable device
PORTABLE_PHOTO_LONGEST_EDGE=4000   # Walkman max 4000×4000 pixels
PORTABLE_PHOTO_THUMB_SIZE=160      # embedded EXIF thumbnail px (larger for 4K images)

# ---------------------------------------------------------------------------
# Metadata / API keys (override via environment or set here)
# ---------------------------------------------------------------------------
# Keys are never committed: put them in the git-ignored config.local.sh (or export them).
[[ -f "${SCRIPT_DIR}/config.local.sh" ]] && source "${SCRIPT_DIR}/config.local.sh"
TMDB_API_KEY="${TMDB_API_KEY:-}"
LASTFM_API_KEY="${LASTFM_API_KEY:-}"
ACOUSTID_API_KEY="${ACOUSTID_API_KEY:-}"
METADATA_TIMEOUT=10                # seconds per HTTP request

# ---------------------------------------------------------------------------
# Concurrency
# ---------------------------------------------------------------------------
MAX_PARALLEL_JOBS=$(cpu_count)

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
LOG_DIR="${SCRIPT_DIR}"
IMPORT_LOG="${LOG_DIR}/import.log"
BACKUP_LOG="${LOG_DIR}/backup.log"
SYNC_LOG="${LOG_DIR}/sync.log"

# Per-run full-output archive: sync.sh mirrors the *entire* run (every line,
# including untagged tool stdout) to a timestamped file under LOG_ARCHIVE_DIR so
# nothing is lost when the terminal closes — no manual `| tee` required. The
# tagged SYNC_LOG is still rotated separately for quick "any failures?" checks.
LOG_ARCHIVE_DIR="${LOG_ARCHIVE_DIR:-${LOG_DIR}/logs}"
# How many timestamped run logs (and rotated import.log/sync.log backups) to keep.
LOG_KEEP="${LOG_KEEP:-10}"

# ---------------------------------------------------------------------------
# Metadata cache — persistent album-context store (skips AcoustID/MusicBrainz)
# ---------------------------------------------------------------------------
# When enabled, the result of each album lookup is cached under CACHE_DIR keyed
# by the audio fingerprint of the album's first track. Subsequent runs reuse the
# cached metadata and make ZERO network calls for already-seen albums. The key is
# the acoustic fingerprint (not the folder path), so the cache survives folder
# renames/moves and is shared across the desktop and portable tiers.
CACHE_ENABLED="${CACHE_ENABLED:-1}"
CACHE_DIR="${CACHE_DIR:-${SCRIPT_DIR}/.cache}"
# Bump ALBUM_META_CACHE_VERSION when the cached schema changes to invalidate old entries.
ALBUM_META_CACHE_VERSION="1"
ALBUM_META_CACHE_DIR="${CACHE_DIR}/album-meta"

# ---------------------------------------------------------------------------
# Playlists — per-album + per-artist M3U8 (UTF-8) for music libraries
# ---------------------------------------------------------------------------
# After music import, a "playlist.m3u8" is (re)generated inside every album folder
# and every artist folder, in both the desktop (FLAC) and portable (m4a) trees.
# M3U8 is UTF-8 so Cyrillic / accented track names render correctly.
PLAYLIST_ENABLED="${PLAYLIST_ENABLED:-1}"
PLAYLIST_FILENAME="playlist.m3u8"

# ---------------------------------------------------------------------------
# Misc
# ---------------------------------------------------------------------------
STAGING_SUFFIX=".syncing"          # temp directory suffix during conversion

# STAGING_ROOT: when set, conversions are staged under this directory (on fast
# local disk) instead of next to the destination. ffmpeg — including the
# `+faststart` moov-relocation second pass, which rewrites the whole file — then
# runs entirely on local disk, and commit_staged copies the finished, valid file
# to the destination once. Use this when the destination is a slow/flaky network
# share (e.g. a router SMB mount) where faststart on multi-GB files fails with
# "Error writing trailer: Input/output error". Empty = stage next to destination
# (instant same-fs rename; best when the destination is fast local/external disk).
STAGING_ROOT="${STAGING_ROOT:-}"

# ---------------------------------------------------------------------------
# Debug mode
# ---------------------------------------------------------------------------
# DEBUG_MODE controls log verbosity only:
#   1 (default) = verbose: show ffmpeg progress, debug_log messages
#   0           = quiet:   suppress ffmpeg progress and debug_log output
#
# File overwriting is ALWAYS enabled (not tied to this flag).  To trim video
# for fast test runs set DEBUG_VIDEO_TRIM_SECONDS to a non-zero value.
DEBUG_MODE="${DEBUG_MODE:-0}"

# Delete source file from UNSORTED after a successful import (default: ON —
# the import behaves like a MOVE). A source is removed only after its outputs
# are verified, or when identical outputs already exist in the library (skip
# path). Camera originals are removed only once their archived copy is
# size-verified. Sources are always kept on any failure, when a tier is disabled
# (ENABLE_DESKTOP/ENABLE_PORTABLE=0), or when DEBUG_VIDEO_TRIM_SECONDS is set.
# Set DELETE_AFTER_IMPORT=0 to keep sources (copy-only mode).
DELETE_AFTER_IMPORT="${DELETE_AFTER_IMPORT:-1}"

# When 1 (default): skip files whose destination already exists and is non-empty
# (incremental / re-run safe mode).  Set to 0 to always re-encode everything.
SKIP_IF_EXISTS="${SKIP_IF_EXISTS:-1}"

# Trim video output to this many seconds (0 = no trim, full video).
# Set to e.g. 60 when you want fast test encodes.
DEBUG_VIDEO_TRIM_SECONDS="${DEBUG_VIDEO_TRIM_SECONDS:-0}"

# Print a message only when DEBUG_MODE=1
debug_log() {
    [[ "${DEBUG_MODE:-0}" == "1" ]] && echo "[DEBUG] $*" >&2 || true
}

trace_log() {
    [[ "${DEBUG_MODE:-0}" == "1" ]] && echo "[TRACE] $*" >&2 || true
}

# ---------------------------------------------------------------------------
# Persistent logging
# ---------------------------------------------------------------------------
# Unlike debug_log/trace_log (stderr only, verbosity-gated), these ALWAYS print
# to stderr AND append a timestamped line to SYNC_LOG so that warnings/errors
# survive after the terminal is closed. Safe to call from parallel subprocesses:
# a single short line written with O_APPEND (>>) is atomic on macOS/APFS+Linux,
# so concurrent orginize.sh/convert.sh workers never interleave mid-line.
_log_persist() {
    local level="$1"; shift
    local line="[$level] $*"
    echo "$line" >&2
    if [[ -n "${SYNC_LOG:-}" ]]; then
        printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$line" >> "$SYNC_LOG" 2>/dev/null || true
    fi
}
log_info()  { _log_persist INFO  "$@"; }
log_warn()  { _log_persist WARN  "$@"; }
log_error() { _log_persist ERROR "$@"; }

# Append any [WARN]/[ERROR]/[FAIL] lines from a captured stderr file to SYNC_LOG,
# prefixed with a context label (e.g. the source file). Used by import.sh to
# surface worker warnings that would otherwise be discarded on a successful job.
# Matched tags are configurable via LOG_CAPTURE_TAGS (extended-regex alternation).
LOG_CAPTURE_TAGS="${LOG_CAPTURE_TAGS:-WARN|ERROR|FAIL}"
drain_err_to_log() {
    local errfile="$1" ctx="${2:-}"
    [[ -s "$errfile" ]] || return 0
    [[ -n "${SYNC_LOG:-}" ]] || return 0
    local _ts; _ts="$(date '+%Y-%m-%d %H:%M:%S')"
    # `|| true` on the grep: a clean import has no WARN/ERROR/FAIL lines, so grep
    # exits 1 (no match). Under the caller's `set -e`+`set -o pipefail` that would
    # abort the whole import — so swallow the no-match exit explicitly.
    { grep -E "\[(${LOG_CAPTURE_TAGS})\]" "$errfile" 2>/dev/null || true; } \
        | while IFS= read -r _l; do
            printf '%s %s%s\n' "$_ts" "${ctx:+$ctx: }" "$_l" >> "$SYNC_LOG" 2>/dev/null || true
          done
    return 0
}

# Verify that a required external tool is available
require_tool() {
    local tool="$1"
    if ! command -v "$tool" &>/dev/null; then
        echo "[ERROR] Required tool not found: $tool" >&2
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Create all required directories if they don't exist
# ---------------------------------------------------------------------------
mkdir -p \
    "${CAMERA_SOURCE}" \
    "${DOWNLOADS_SOURCE}" \
    "${MUSIC_SOURCE}" \
    "${MOVIES_SOURCE}" \
    "${TV_SOURCE}" \
    "${PHOTOS_SOURCE}" \
    "${VIDEO_SOURCE}" \
    "${DESKTOP_MUSIC_ROOT}" \
    "${DESKTOP_MOVIES_ROOT}" \
    "${DESKTOP_TV_ROOT}" \
    "${DESKTOP_PHOTOS_ROOT}" \
    "${DESKTOP_CAMERA_ROOT}" \
    "${PORTABLE_MUSIC_ROOT}" \
    "${PORTABLE_MOVIES_ROOT}" \
    "${PORTABLE_TV_ROOT}" \
    "${PORTABLE_PHOTOS_ROOT}"
