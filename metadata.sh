#!/usr/bin/env bash
# metadata.sh — metadata fetch and embed helpers
# Sourced by orginize.sh and convert.sh; never executed directly.

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Sanitize a string for use as a filename / directory component.
# Preserves printable Unicode (Cyrillic, accented letters, superscripts, etc.):
# only control characters and filesystem-unsafe chars are removed/replaced,
# runs of whitespace/dashes are collapsed. Unicode is safe on both APFS (desktop)
# and VFAT/exFAT (Sony Walkman portable); walkman_sanitize_path() handles length.
sanitize_name() {
    local s="$1"
    # Replace filesystem-unsafe characters (configurable via FILENAME_UNSAFE_CHARS
    # in config.sh) with FILENAME_REPLACEMENT. The variable holds the body of a
    # bash bracket expression, e.g. ':/?*"<>|'.
    local _unsafe="${FILENAME_UNSAFE_CHARS-:/?*\"<>|}"
    local _repl="${FILENAME_REPLACEMENT--}"
    s="${s//[$_unsafe]/$_repl}"
    # Strip C0 control characters (0x00-0x1F) and DEL (0x7F); keep all printable
    # Unicode. UTF-8 multibyte sequences use bytes >= 0x80, so byte-wise deletion
    # in the C locale never touches them.
    s="$(printf '%s' "$s" | LC_ALL=C tr -d '\000-\037\177')"
    # Collapse multiple spaces/dashes, trim edges
    s="$(echo "$s" | sed 's/  */ /g; s/--*/-/g; s/^[[:space:]-]*//; s/[[:space:]-]*$//')"
    echo "$s"
}

# Cross-process API rate limiter.
# Guarantees at most 1 request per $min_sec seconds for the given API key,
# shared across ALL parallel orginize.sh subprocesses.
# Uses mkdir as an atomic lock — works on macOS (APFS/HFS+) and Linux.
# Usage: _api_rate_limit <key> [min_sec]
_api_rate_limit() {
    local _key="$1" _min="${2:-1}"
    local _lk="/tmp/media-sync-ratelimit-${_key}.lock"
    local _ts="/tmp/media-sync-ratelimit-${_key}.ts"

    # Spin until we acquire the lock (mkdir is atomic on POSIX)
    local _tries=0
    while ! mkdir "$_lk" 2>/dev/null; do
        sleep 0.1
        (( _tries++ )) || true
        (( _tries > 150 )) && break   # abandon after ~15s rather than deadlock
    done

    local _last _now _wait
    _last=$(cat "$_ts" 2>/dev/null || echo 0)
    _now=$(date +%s)
    _wait=$(( _min - (_now - _last) ))
    if (( _wait > 0 )); then
        sleep "$_wait"
    fi
    date +%s > "$_ts"

    rmdir "$_lk" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# HTTP helpers — retry with exponential back-off
# ---------------------------------------------------------------------------
# Maximum number of attempts for any HTTP request (initial + retries).
HTTP_MAX_RETRIES="${HTTP_MAX_RETRIES:-4}"
# Initial back-off in seconds; doubles on each retry; multiplied by 4 on 429.
HTTP_BACKOFF_INITIAL="${HTTP_BACKOFF_INITIAL:-2}"

# Fetch a URL and print the response body to stdout.
# Usage: http_get [curl-opts] URL
# Returns 0 on HTTP 2xx, 1 after all retries are exhausted (non-fatal to caller
# because every call site uses: result=$(http_get ...) || <fallback>).
# Returns true if an HTTP status code is worth retrying.
_http_should_retry() {
    local code="$1"
    # Retry on: network error (empty code), 429 (rate limit), 5xx (server error)
    # Do NOT retry on 4xx client errors (404, 401, 403, etc.) — they are permanent.
    [[ -z "$code" || "$code" == "429" || "$code" =~ ^5 ]]
}

http_get() {
    local attempt=1 delay="${HTTP_BACKOFF_INITIAL:-2}" http_code rc

    # First arg is optional pre-delay in ms
    if [[ "$1" =~ ^[0-9]+$ ]]; then
        pre_delay="$1"
        shift
    else
        pre_delay=300
    fi

    [[ "$pre_delay" -gt 0 ]] && sleep "$(echo "scale=3; $pre_delay/1000" | bc)"

    local tmp
    tmp="$(mktemp /tmp/meta_curl_XXXXXX)"
    while [[ $attempt -le ${HTTP_MAX_RETRIES:-4} ]]; do
        http_code=$(curl -s --compressed -w '%{http_code}' -o "$tmp" \
            --max-time "${METADATA_TIMEOUT:-10}" "$@" 2>/dev/null)  
        rc=$?
        if [[ "$http_code" =~ ^4 ]] || [[ "$http_code" =~ ^5 ]]; then
            echo "[ERROR] HTTP ${http_code:-network-err}: $(cat "$tmp")" >&2
        fi
        if [[ $rc -eq 0 && ("$http_code" =~ ^2 || "$http_code" =~ ^3) ]]; then
            cat "$tmp"; rm -f "$tmp"; return 0
        fi
        if ! _http_should_retry "$http_code"; then
            rm -f "$tmp"; return 1
        fi
        if [[ $attempt -lt ${HTTP_MAX_RETRIES:-4} ]]; then
            [[ "$http_code" == "429" ]] && delay=$(( delay * 4 ))
            echo "[WARN] HTTP ${http_code:-network-err} (attempt ${attempt}/${HTTP_MAX_RETRIES:-4}), retrying in ${delay}s" >&2
            sleep "$delay"
            delay=$(( delay * 2 ))
        fi
        (( attempt++ )) || true
    done
    rm -f "$tmp"
    return 1
}

http_post() {
    local attempt=1 delay="${HTTP_BACKOFF_INITIAL:-2}" http_code rc
    local tmp data_args=()
    tmp="$(mktemp /tmp/meta_curl_XXXXXX)"

    # Separate --data/--data-urlencode args from URL
    # Caller passes data args first, then URL last (same as curl convention)
    while [[ $attempt -le ${HTTP_MAX_RETRIES:-4} ]]; do
        http_code=$(curl -s --compressed -X POST -w '%{http_code}' -o "$tmp" \
            --max-time "${METADATA_TIMEOUT:-10}" "$@" 2>/dev/null)
        rc=$?
       if [[ "$http_code" =~ ^4 ]] || [[ "$http_code" =~ ^5 ]]; then
            echo "[ERROR] HTTP ${http_code:-network-err}: $(cat "$tmp")" >&2
        fi
        if [[ $rc -eq 0 && ("$http_code" =~ ^2 || "$http_code" =~ ^3) ]]; then
            cat "$tmp"; rm -f "$tmp"; return 0
        fi
        if ! _http_should_retry "$http_code"; then
            rm -f "$tmp"; return 1
        fi
        if [[ $attempt -lt ${HTTP_MAX_RETRIES:-4} ]]; then
            [[ "$http_code" == "429" ]] && delay=$(( delay * 4 ))
            echo "[WARN] HTTP ${http_code:-network-err} (attempt ${attempt}/${HTTP_MAX_RETRIES:-4}), retrying in ${delay}s" >&2
            sleep "$delay"
            delay=$(( delay * 2 ))
        fi
        (( attempt++ )) || true
    done
    rm -f "$tmp"
    return 1
}

# Download a URL to a file (follows redirects).
# Usage: http_download DEST_PATH [curl-opts] URL
# Returns 0 on HTTP 2xx, 1 after all retries are exhausted.
http_download() {
    local dest="$1"; shift
    local attempt=1 delay="${HTTP_BACKOFF_INITIAL:-2}" http_code rc
    while [[ $attempt -le ${HTTP_MAX_RETRIES:-4} ]]; do
        http_code=$(curl -sL -w '%{http_code}' -o "$dest" \
            --max-time "${METADATA_TIMEOUT:-10}" "$@" 2>/dev/null)
        rc=$?
        if [[ $rc -eq 0 && "$http_code" =~ ^2 ]]; then
            return 0
        fi
        rm -f "$dest"
        if ! _http_should_retry "$http_code"; then
            return 1
        fi
        if [[ $attempt -lt ${HTTP_MAX_RETRIES:-4} ]]; then
            [[ "$http_code" == "429" ]] && delay=$(( delay * 4 ))
            echo "[WARN] HTTP ${http_code:-network-err} (attempt ${attempt}/${HTTP_MAX_RETRIES:-4}), retrying in ${delay}s" >&2
            sleep "$delay"
            delay=$(( delay * 2 ))
        fi
        (( attempt++ )) || true
    done
    return 1
}

# ---------------------------------------------------------------------------
# Audio metadata — MusicBrainz + AcoustID (PRESERVE-FIRST)
# ---------------------------------------------------------------------------

# Helper: returns true (0) when a value is a generic/placeholder album-artist.
# Used by fetch_audio_meta_acoustid and resolve_album_artist.
# Also treats MusicBrainz bracket placeholders ([unknown], [no artist], [various],
# [data]) as generic so they never become a literal artist folder name.
_is_generic() {
    local v
    v="$(echo "${1:-}" | tr '[:upper:]' '[:lower:]' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    [[ -z "$v" || "$v" == "various artists" || "$v" == "various" || "$v" == "misc" ]] && return 0
    # Any bracket placeholder, e.g. [unknown], [no artist], [various], [data]
    [[ "$v" =~ ^\[.*\]$ ]]
}

# Helper: returns true (0) when a value is an EXPLICIT compilation marker
# (e.g. a source folder deliberately named "Various Artists" / "VA" / "OST").
# Distinct from _is_generic: empty and "misc" are NOT compilations — they mean
# "unknown", whereas these markers mean "a real multi-artist album". Used by
# resolve_album_artist to keep all tracks of such an album in one folder.
_is_compilation() {
    local v
    v="$(echo "${1:-}" | tr '[:upper:]' '[:lower:]' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    [[ -z "$v" ]] && return 1
    case "$v" in
        "various artists"|various|va|"v.a."|"v/a"|compilation|compilations)
            return 0 ;;
        *) return 1 ;;
    esac
}

# Helper: if a folder name denotes a disc subfolder (CD1, CD 1, CD-01, Disc 1,
# Disc01, Disk 2, DVD1, ...), echo the disc number and return 0; else return 1.
# Case-insensitive; accepts space / dot / dash / underscore between word and digits.
_disc_from_name() {
    local n
    n="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')"
    if [[ "$n" =~ ^(cd|disc|disk|dvd)[[:space:]._-]*([0-9]{1,2})$ ]]; then
        printf '%s' "$((10#${BASH_REMATCH[2]}))"
        return 0
    fi
    return 1
}

# Helper: extract a 4-digit year token (1900–2099) from a folder name, wherever
# it appears — leading ("2008 - X"), trailing ("X - 2008") or parenthesized
# ("X (2008)"). Echoes the year and returns 0 on match; returns 1 otherwise.
_year_token() {
    local s="${1:-}"
    if [[ "$s" =~ (^|[^0-9])((19|20)[0-9]{2})([^0-9]|$) ]]; then
        printf '%s' "${BASH_REMATCH[2]}"
        return 0
    fi
    return 1
}

# Resolve the source layout for an audio file independently of how the source is
# nested. Tags are authoritative for naming (artist / album-artist / album /
# year); the PATH is used only to (a) detect a disc number, (b) identify the
# album-grouping folder, and (c) supply a fallback year/album when a tag is
# missing. This copes with every observed structure, e.g.:
#   <artist>/<album>/track
#   <artist>/<year - album>/track            (or "album - year", "album (year)")
#   <artist + album [+ year]>/track          (tracks directly in the top folder)
#   <album [+ year]>/track                    (no artist in the path → from tags)
#   <…>/<CD1|Disc 2|Disk03|DVD1>/track        (disc folder at ANY level)
#   <artist>/track                            (flat: no album subfolder)
# Sets (always defined after the call):
#   SRC_ALBUM_RAW        — deepest non-disc directory below the root (album-name
#                          fallback), or empty when the track sits in the root
#   SRC_DISC_FROM_PATH   — disc number from the deepest disc folder, or empty
#   SRC_YEAR_FROM_PATH   — year token found in the path (album folder → ancestor
#                          dirs → top-folder basename), or empty
# Usage: resolve_source_layout <file> <source_root>
resolve_source_layout() {
    local file="$1" root="${2%/}"
    SRC_ALBUM_RAW=""
    SRC_DISC_FROM_PATH=""
    SRC_YEAR_FROM_PATH=""

    local rel="${file#$root/}"
    local -a comp=()
    if [[ "$rel" == "$file" ]]; then
        # File not under the given root → best-effort: its parent is the album.
        comp=( "$(basename "$(dirname "$file")")" "$(basename "$file")" )
    else
        local _ifs_save="$IFS"
        IFS='/' read -ra comp <<< "$rel"
        IFS="$_ifs_save"
    fi
    local n=${#comp[@]}

    # Directory components below the root (everything except the filename).
    local -a dirs=()
    local i
    if (( n >= 2 )); then
        for (( i=0; i<n-1; i++ )); do dirs+=( "${comp[$i]}" ); done
    fi
    local nd=${#dirs[@]}

    # Disc number: deepest directory that names a disc (CD1, Disc 2, DVD1, ...),
    # whether it sits directly under the root or below an album folder.
    local d
    for (( i=nd-1; i>=0; i-- )); do
        if d="$(_disc_from_name "${dirs[$i]}")"; then SRC_DISC_FROM_PATH="$d"; break; fi
    done

    # Album-grouping folder: deepest directory that is NOT a disc folder.
    for (( i=nd-1; i>=0; i-- )); do
        if ! _disc_from_name "${dirs[$i]}" >/dev/null 2>&1; then SRC_ALBUM_RAW="${dirs[$i]}"; break; fi
    done

    # Year fallback: prefer the album folder, then any ancestor dir, then the
    # top-folder basename (which may be "album+year" when there is no subfolder).
    local _cand
    if [[ -n "$SRC_ALBUM_RAW" ]] && _cand="$(_year_token "$SRC_ALBUM_RAW")"; then
        SRC_YEAR_FROM_PATH="$_cand"
    else
        for (( i=nd-1; i>=0; i-- )); do
            if _cand="$(_year_token "${dirs[$i]}")"; then SRC_YEAR_FROM_PATH="$_cand"; break; fi
        done
        if [[ -z "$SRC_YEAR_FROM_PATH" ]] && _cand="$(_year_token "$(basename "$root")")"; then
            SRC_YEAR_FROM_PATH="$_cand"
        fi
    fi
    return 0
}

# Resolve the final album TITLE from the embedded album tag, preserving an edition
# qualifier that lives only in the source folder name. There is NO dedicated edition
# tag in common formats — the edition is part of the ALBUM tag when present at all
# (e.g. "Interstellar (Illuminated Star Projection Edition)"). When a source omits it
# from the tag, distinct editions of one release share the same embedded album tag
# (e.g. "Batman Begins" for both the regular and "(Expanded Score)" releases) and the
# qualifier in the folder name is the ONLY thing that keeps them apart.
#
# An "edition qualifier" is one or more trailing parenthetical/bracket groups on the
# folder name, e.g. "(Expanded Score)", "[Deluxe]", "(Deluxe Edition) (Remastered)".
# It is appended to the embedded album whenever it is present in the folder AND not
# already part of the embedded album tag. The non-qualifier part of the folder must be
# compatible with the embedded album (one a case-insensitive prefix of the other, to
# tolerate truncated tags/folders); otherwise the embedded tag wins unchanged so an
# unrelated folder name can never inject a bogus edition.
# Usage: resolve_album_name <embedded_album> <album_folder_basename>
resolve_album_name() {
    local album="$1" folder="$2"
    [[ -z "$album" ]] && { printf '%s' "$album"; return 0; }

    # Year-strip the folder name (leading "YYYY - " or trailing year token).
    local fa
    fa="$(printf '%s' "$folder" \
        | sed -E 's/^(19|20)[0-9]{2}[[:space:]]*[-_.][[:space:]]*//' \
        | sed -E 's/[[:space:]]*[-(][[:space:]]*(19|20)[0-9]{2}\)?[[:space:]]*$//' \
        | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    [[ -z "$fa" ]] && { printf '%s' "$album"; return 0; }

    # The folder is an edition variant when it reads "<embedded album> <qualifier-run>"
    # (case-insensitive prefix) and the trailing part is one or more parenthetical/
    # bracket groups. Slice the suffix off by the album's length so the WHOLE trailing
    # run is captured (e.g. "(Deluxe Edition) (Remastered)"), not just the last group.
    local fl al
    fl="$(printf '%s' "$fa"    | tr '[:upper:]' '[:lower:]')"
    al="$(printf '%s' "$album" | tr '[:upper:]' '[:lower:]')"
    if [[ "$fl" == "$al"* ]]; then
        local suffix="${fa:${#album}}"
        suffix="$(printf '%s' "$suffix" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
        # Qualifier run must start with ( or [ and not already be in the embedded tag.
        if [[ -n "$suffix" && ( "${suffix:0:1}" == "(" || "${suffix:0:1}" == "[" ) \
           && "$album" != *"$suffix"* ]]; then
            printf '%s %s' "$album" "$suffix"
            return 0
        fi
    fi
    printf '%s' "$album"
}

# Returns true (0) when a string contains CJK script (Han ideographs, Japanese
# kana, or Korean Hangul) — scripts that have no native Latin form, so the
# romanized MusicBrainz sort-name is the only sensible display value.
# NB: deliberately does NOT match Cyrillic, Greek, or accented Latin — those are
# real alphabets the user wants preserved as-is (e.g. "НеАнгелы", "Björk", "Σ").
_has_cjk() {
    printf '%s' "${1:-}" | perl -CSD -ne 'exit(/[\p{Han}\p{Hiragana}\p{Katakana}\p{Hangul}]/ ? 0 : 1)' 2>/dev/null
}

# Choose the display form of an artist name coming from MusicBrainz.
# Only CJK names are romanized via the sort-name (e.g. Japanese "梅林茂" →
# "Umebayashi, Shigeru" → "Shigeru Umebayashi"); every other script — Cyrillic,
# Greek, accented Latin — is PRESERVED in its native form. Romanizing those
# scripts used to split one artist across two folders (e.g. "НеАнгелы" some
# tracks vs the romanized "neAngely" sort-name for others).
# Usage: _prefer_ascii_artist <name> <sort-name>
_prefer_ascii_artist() {
    local name="$1" sort_name="$2"
    [[ -z "$name" ]] && echo "" && return
    # If name is all printable ASCII, use it as-is
    if ! echo "$name" | LC_ALL=C grep -q '[^ -~]'; then
        echo "$name"; return
    fi
    # Only romanize CJK scripts (no usable native Latin form). Cyrillic/Greek/
    # accented Latin keep their native name to avoid split-artist folders.
    if _has_cjk "$name" && [[ -n "$sort_name" ]] && ! echo "$sort_name" | LC_ALL=C grep -q '[^ -~]'; then
        if [[ "$sort_name" == *", "* ]]; then
            local _last="${sort_name%%, *}" _first="${sort_name#*, }"
            echo "${_first} ${_last}"
        else
            echo "$sort_name"
        fi
        return
    fi
    # Non-CJK (or no ASCII sort-name): keep the native name.
    echo "$name"
}

# ---------------------------------------------------------------------------
# Album-context cache (persistent, keyed by acoustic fingerprint)
# ---------------------------------------------------------------------------
# Resolve the versioned cache directory for album metadata.
_album_cache_dir() {
    printf '%s/v%s' "${ALBUM_META_CACHE_DIR}" "${ALBUM_META_CACHE_VERSION:-1}"
}

# Derive a stable, filesystem-safe cache key from an acoustic fingerprint.
_album_cache_key() {
    printf '%s' "$1" | md5 2>/dev/null || printf '%s' "$1" | cksum | awk '{print $1}'
}

# Emit album context for downstream track processing: either write a per-folder
# shell-sourceable context file (when ctx_dir is given) or export ALBUM_CTX_*.
# Usage: _album_ctx_emit <folder> <ctx_dir> <album> <album_artist> <year> <release_id> <tracklist_json>
_album_ctx_emit() {
    local folder="$1" ctx_dir="$2" album="$3" album_artist="$4" year="$5" release_id="$6" tracklist_json="$7"
    if [[ -n "$ctx_dir" ]]; then
        local folder_hash tracklist_file ctx_file
        folder_hash=$(printf '%s' "$folder" | md5 2>/dev/null || printf '%s' "$folder" | cksum | awk '{print $1}')
        tracklist_file="${ctx_dir}/${folder_hash}_tracklist.json"
        ctx_file="${ctx_dir}/${folder_hash}.sh"
        printf '%s\n' "$tracklist_json" > "$tracklist_file"
        {
            [[ -n "$album"        ]] && printf 'ALBUM_CTX_ALBUM=%q\n'        "$album"
            [[ -n "$album_artist" ]] && printf 'ALBUM_CTX_ALBUM_ARTIST=%q\n' "$album_artist"
            [[ -n "$year"         ]] && printf 'ALBUM_CTX_YEAR=%q\n'         "$year"
            printf 'ALBUM_CTX_RELEASE_ID=%q\n' "$release_id"
            printf 'ALBUM_CTX_TRACKLIST=%q\n'  "$tracklist_file"
        } > "$ctx_file"
    else
        local tracklist_file
        tracklist_file=$(mktemp /tmp/album_ctx_tracklist_XXXXXX.json)
        printf '%s\n' "$tracklist_json" > "$tracklist_file"
        [[ -n "$album"        ]] && export ALBUM_CTX_ALBUM="$album"
        [[ -n "$album_artist" ]] && export ALBUM_CTX_ALBUM_ARTIST="$album_artist"
        [[ -n "$year"         ]] && export ALBUM_CTX_YEAR="$year"
        export ALBUM_CTX_RELEASE_ID="$release_id"
        export ALBUM_CTX_TRACKLIST="$tracklist_file"
    fi
}

# Store a resolved album lookup in the persistent cache (no-op when disabled).
# Usage: _album_cache_store <key> <album> <album_artist> <year> <release_id> <tracklist_json>
_album_cache_store() {
    [[ "${CACHE_ENABLED:-1}" == "1" ]] || return 0
    local key="$1" album="$2" album_artist="$3" year="$4" release_id="$5" tracklist_json="$6"
    [[ -n "$key" ]] || return 0
    local dir; dir="$(_album_cache_dir)"
    mkdir -p "$dir" 2>/dev/null || return 0
    printf '%s\n' "$tracklist_json" > "${dir}/${key}_tracklist.json"
    {
        printf 'CALBUM=%q\n'        "$album"
        printf 'CALBUM_ARTIST=%q\n' "$album_artist"
        printf 'CYEAR=%q\n'         "$year"
        printf 'CRELEASE_ID=%q\n'   "$release_id"
    } > "${dir}/${key}.sh"
}

# Read existing embedded tags from an audio file.
# Outputs shell variable assignments; eval the result to populate:
#   AUDIO_TITLE, AUDIO_ARTIST, AUDIO_ALBUM, AUDIO_YEAR, AUDIO_TRACK,
#   AUDIO_DISC, AUDIO_DISC_TOTAL, AUDIO_GENRE, AUDIO_ALBUM_ARTIST
read_audio_tags() {
    local file="$1"
    local out
    # -PartOfSet: MP3 stores the disc number in the ID3v2 TPOS frame, which exiftool
    #   exposes as "PartOfSet" (NOT DiscNumber). Without it, every multi-disc MP3 set
    #   loses its disc number and collapses onto disc 1.
    # The jq strips a "/total" suffix (e.g. Track "7/9", PartOfSet "2/2") from the
    #   TRACK and DISC values so they are always clean integers — pad2 does integer
    #   arithmetic and would mis-evaluate "2/2" as 1.
    out=$(exiftool -json \
        -Title -Artist -Album -AlbumArtist -Year -Date -Track -TrackNumber -DiscNumber -DiskNumber -PartOfSet -Genre \
        "$file" 2>/dev/null | jq -r '.[0] | to_entries[] |
        (.key | ascii_upcase | gsub("TRACKNUMBER";"TRACK") | gsub("PARTOFSET";"DISC") | gsub("DISCNUMBER";"DISC") | gsub("DISKNUMBER";"DISC") | gsub("DATE";"YEAR") | gsub("ALBUMARTIST";"ALBUM_ARTIST")) as $k |
        (.value | tostring) as $v |
        "AUDIO_\($k)=" + ((if ($k == "TRACK" or $k == "DISC") then ($v | split("/")[0]) else $v end) | @sh)' 2>/dev/null)
    
    trace_log "audio tags: $out"

    echo "$out"
}

# ---------------------------------------------------------------------------
# Album-context fetch — called ONCE per album folder from import.sh
# ---------------------------------------------------------------------------
# Fingerprints the first audio file in the folder, identifies the MusicBrainz
# release, and writes per-album context consumed by every track in that folder.
#
# Usage: fetch_album_meta_for_folder <folder> [folder_label] [ctx_dir]
#
#   ctx_dir — when supplied, a shell-sourceable context file is written to
#             ${ctx_dir}/<folder-hash>.sh  (orginize.sh sources it at runtime).
#             The tracklist JSON is also stored inside ctx_dir.
#             When omitted (legacy), ALBUM_CTX_* vars are exported directly.
#
# Context variables (whether via file or exports):
#   ALBUM_CTX_ALBUM        — album title
#   ALBUM_CTX_ALBUM_ARTIST — album artist
#   ALBUM_CTX_YEAR         — release year (of THIS release, not original recording)
#   ALBUM_CTX_RELEASE_ID   — MusicBrainz release UUID
#   ALBUM_CTX_TRACKLIST    — path to JSON file: recording_id → {disc, position}
fetch_album_meta_for_folder() {
    local folder="$1"
    local folder_label="${2:-}"
    local ctx_dir="${3:-}"   # optional: dir to write per-album shell context files

    if ! command -v fpcalc &>/dev/null; then
        echo "[WARN] fpcalc not found; skipping album context lookup: $folder" >&2
        return 0
    fi

    # First audio file in the folder (sorted, maxdepth 1 — this IS the album dir)
    local first_file
    first_file=$(find "$folder" -maxdepth 1 -type f \
        \( -iname '*.flac' -o -iname '*.m4a' -o -iname '*.mp3' \
           -o -iname '*.aac' -o -iname '*.wav' -o -iname '*.ogg' \) \
        | sort | head -1)
    [[ -z "$first_file" ]] && return 0

    # Fingerprint
    local fp_json duration fingerprint
    fp_json=$(fpcalc -json "$first_file" 2>/dev/null) || return 0
    duration=$(echo "$fp_json" | jq -r '.duration | round' 2>/dev/null)
    fingerprint=$(echo "$fp_json" | jq -r '.fingerprint' 2>/dev/null)
    [[ -z "$fingerprint" || -z "$duration" ]] && return 0

    # Cache lookup — keyed by acoustic fingerprint (survives folder renames and is
    # shared across desktop/portable tiers). A hit skips BOTH AcoustID and MusicBrainz.
    local _cache_key=""
    if [[ "${CACHE_ENABLED:-1}" == "1" ]]; then
        _cache_key="$(_album_cache_key "$fingerprint")"
        local _cdir; _cdir="$(_album_cache_dir)"
        if [[ -f "${_cdir}/${_cache_key}.sh" && -f "${_cdir}/${_cache_key}_tracklist.json" ]]; then
            local CALBUM="" CALBUM_ARTIST="" CYEAR="" CRELEASE_ID="" _ctl
            # shellcheck source=/dev/null
            source "${_cdir}/${_cache_key}.sh"
            _ctl="$(cat "${_cdir}/${_cache_key}_tracklist.json")"
            _album_ctx_emit "$folder" "$ctx_dir" "$CALBUM" "$CALBUM_ARTIST" "$CYEAR" "$CRELEASE_ID" "$_ctl"
            echo "[CACHE] Album context hit: '${CALBUM_ARTIST:-?} — ${CALBUM:-?}' (${CYEAR:-?}) release=${CRELEASE_ID:-?}" >&2
            return 0
        fi
    fi

    # AcoustID lookup
    local acoustid_resp
    _api_rate_limit "acoustid"
    acoustid_resp=$(http_get \
        "https://api.acoustid.org/v2/lookup?client=${ACOUSTID_API_KEY}&duration=${duration}&fingerprint=${fingerprint}&meta=recordings+releasegroups+compress") || return 0

    local mb_recording_id
    mb_recording_id=$(echo "$acoustid_resp" | jq -r '.results[0].recordings[0].id // empty' 2>/dev/null)
    [[ -z "$mb_recording_id" ]] && return 0

    # MusicBrainz recording → get list of releases it appears on
    _api_rate_limit "musicbrainz"
    local mb_rec_resp
    mb_rec_resp=$(http_get \
        -H "User-Agent: mylibsystems/2.0 (https://github.com/user/mylibsystems)" \
        "https://musicbrainz.org/ws/2/recording/${mb_recording_id}?inc=releases&fmt=json") || return 0

    # Pick the release whose track-count is closest to the number of files in THIS folder
    local file_count
    file_count=$(find "$folder" -maxdepth 1 -type f \
        \( -iname '*.flac' -o -iname '*.m4a' -o -iname '*.mp3' \
           -o -iname '*.aac' -o -iname '*.wav' \) | wc -l | tr -d ' ')

    local release_id
    release_id=$(echo "$mb_rec_resp" | jq -r --argjson fc "$file_count" '
        (.releases // []) |
        sort_by((.["track-count"] // 0) - $fc | if . < 0 then -. else . end) |
        .[0].id // empty
    ' 2>/dev/null)
    [[ -z "$release_id" ]] && return 0

    # Fetch full release: album title, album artist, year, and complete tracklist
    _api_rate_limit "musicbrainz"
    local mb_release_resp
    mb_release_resp=$(http_get \
        -H "User-Agent: mylibsystems/2.0 (https://github.com/user/mylibsystems)" \
        "https://musicbrainz.org/ws/2/release/${release_id}?inc=artist-credits+recordings&fmt=json") || return 0

    local album album_artist year
    album=$(echo "$mb_release_resp"       | jq -r '.title // empty' 2>/dev/null)
    local _aa_name _aa_sort
    _aa_name=$(echo "$mb_release_resp" | jq -r '.["artist-credit"][0].artist.name // empty' 2>/dev/null)
    _aa_sort=$(echo "$mb_release_resp" | jq -r '.["artist-credit"][0].artist["sort-name"] // empty' 2>/dev/null)
    album_artist=$(_prefer_ascii_artist "$_aa_name" "$_aa_sort")
    year=$(echo "$mb_release_resp"         | jq -r '.date // empty' 2>/dev/null | cut -c1-4)

    # Build recording_id → {disc, position} map
    local tracklist_json
    tracklist_json=$(echo "$mb_release_resp" | jq '
        [.media[] | . as $medium |
         .tracks[] | {
             key: .recording.id,
             value: { disc: $medium.position, position: .position }
         }] | from_entries
    ' 2>/dev/null)

    # Emit per-folder context for the import run, and persist to the cache so future
    # runs reuse it without any network calls.
    _album_ctx_emit "$folder" "$ctx_dir" "$album" "$album_artist" "$year" "$release_id" "$tracklist_json"
    _album_cache_store "$_cache_key" "$album" "$album_artist" "$year" "$release_id" "$tracklist_json"

    echo "[INFO] Album context: '${album_artist:-?} — ${album:-?}' (${year:-?}) tracks=${file_count} release=${release_id}" >&2
}

# Ensure a per-folder album context exists even when AcoustID/MusicBrainz found
# no match. Without this, every track in a folder whose name lacks a year prefix
# falls back to its OWN embedded year — scattering a single album (e.g. a
# rarities/"unreleased" compilation whose tracks span several years) across many
# "YYYY - Album" folders. This derives ONE consensus album + year from the
# folder's embedded tags and writes a minimal context so all tracks stay unified.
# No-op when a real context (from MusicBrainz) was already written for the folder.
ensure_album_ctx_fallback() {
    local folder="$1" ctx_dir="$2"
    [[ -n "$ctx_dir" ]] || return 0

    local folder_hash
    folder_hash=$(printf '%s' "$folder" | md5 2>/dev/null || printf '%s' "$folder" | cksum | awk '{print $1}')
    local ctx_file="${ctx_dir}/${folder_hash}.sh"
    [[ -f "$ctx_file" ]] && return 0   # real MusicBrainz context already present

    # Most frequent embedded album name and year across the folder's audio files.
    # `-exec ... +` + a plain pipe avoids process substitution (bash 3.2.57 heap
    # corruption); trailing `|| true` swallows grep/head no-match + SIGPIPE under
    # `set -e`/`pipefail`.
    local _find_types=( -iname '*.flac' -o -iname '*.m4a' -o -iname '*.mp3' -o -iname '*.aac' -o -iname '*.wav' -o -iname '*.ogg' )
    local album year
    album=$(find "$folder" -maxdepth 1 -type f \( "${_find_types[@]}" \) \
        -exec exiftool -m -s3 -Album {} + 2>/dev/null \
        | sed '/^[[:space:]]*$/d' | sort | uniq -c | sort -rn | head -1 \
        | sed -E 's/^[[:space:]]*[0-9]+[[:space:]]+//' || true)
    year=$(find "$folder" -maxdepth 1 -type f \( "${_find_types[@]}" \) \
        -exec exiftool -m -s3 -Year -Date {} + 2>/dev/null \
        | grep -oE '[12][0-9]{3}' | sort | uniq -c | sort -rn | head -1 \
        | sed -E 's/^[[:space:]]*[0-9]+[[:space:]]+//' || true)

    [[ -z "$album" && -z "$year" ]] && return 0

    _album_ctx_emit "$folder" "$ctx_dir" "$album" "" "$year" "" "{}"
    echo "[INFO] Album context (fallback from embedded tags): '${album:-?}' (${year:-?}) folder='$folder'" >&2
}

# Fetch metadata from MusicBrainz via AcoustID fingerprint.
# Sets AUDIO_* variables (only those not already set by caller).
fetch_audio_meta_acoustid() {
    local file="$1"

    # Require fpcalc
    if ! command -v fpcalc &>/dev/null; then
        echo "[WARN] fpcalc not found; skipping AcoustID lookup for: $file" >&2
        return 0
    fi

    local fp_json duration fingerprint
    fp_json=$(fpcalc -json "$file" 2>/dev/null) || return 0
    duration=$(echo "$fp_json" | jq -r '.duration | round' 2>/dev/null)
    fingerprint=$(echo "$fp_json" | jq -r '.fingerprint' 2>/dev/null)

    [[ -z "$fingerprint" || -z "$duration" ]] && return 0

    # AcoustID lookup (no API key required for fingerprint+duration)
    local acoustid_url="https://api.acoustid.org/v2/lookup?client=${ACOUSTID_API_KEY}&duration=${duration}&fingerprint=${fingerprint}&meta=recordings+releasegroups+compress"
    local acoustid_resp
    _api_rate_limit "acoustid"
    acoustid_resp=$(http_get "$acoustid_url") || return 0

    local mb_recording_id
    mb_recording_id=$(echo "$acoustid_resp" | jq -r '.results[0].recordings[0].id // empty' 2>/dev/null)
    [[ -z "$mb_recording_id" ]] && return 0

    # Track/disc position from the album-context tracklist (built once per folder by fetch_album_meta_for_folder).
    # This gives the correct position within the IMPORTED release, not the original recording release.
    if [[ -n "${ALBUM_CTX_TRACKLIST:-}" && -f "${ALBUM_CTX_TRACKLIST}" ]]; then
        local _pos_data
        _pos_data=$(jq -r --arg rid "$mb_recording_id" '.[$rid] // empty' "${ALBUM_CTX_TRACKLIST}" 2>/dev/null)
        if [[ -n "$_pos_data" ]]; then
            local _pos_disc _pos_track
            _pos_disc=$(echo "$_pos_data"  | jq -r '.disc     // empty' 2>/dev/null)
            _pos_track=$(echo "$_pos_data" | jq -r '.position // empty' 2>/dev/null)
            [[ -n "$_pos_disc"  ]] && AUDIO_DISC="$_pos_disc"
            [[ -n "$_pos_track" ]] && AUDIO_TRACK="$_pos_track"
            debug_log "Track position from album tracklist: disc=${AUDIO_DISC} track=${AUDIO_TRACK}"
        fi
    fi

    # MusicBrainz recording lookup
    local mb_url="https://musicbrainz.org/ws/2/recording/${mb_recording_id}?inc=artists+releases+genres&fmt=json"
    local mb_resp

    _api_rate_limit "musicbrainz"
    mb_resp=$(http_get \
        -H "User-Agent: mylibsystems/2.0 (https://github.com/user/mylibsystems)" \
        "$mb_url") || return 0

    # Extract fields from MusicBrainz recording response
    local fetched_title fetched_artist fetched_album fetched_year fetched_genre
    fetched_title=$(echo "$mb_resp" | jq -r '.title // empty' 2>/dev/null)
    local _fa_name _fa_sort
    _fa_name=$(echo "$mb_resp" | jq -r '.["artist-credit"][0].artist.name // empty' 2>/dev/null)
    _fa_sort=$(echo "$mb_resp" | jq -r '.["artist-credit"][0].artist["sort-name"] // empty' 2>/dev/null)
    fetched_artist=$(_prefer_ascii_artist "$_fa_name" "$_fa_sort")
    fetched_album=$(echo "$mb_resp" | jq -r '.releases[0].title // empty' 2>/dev/null)
    fetched_year=$(echo "$mb_resp" | jq -r '.releases[0].date // empty' 2>/dev/null | cut -c1-4)
    fetched_genre=$(echo "$mb_resp" | jq -r '.genres[0].name // empty' 2>/dev/null)

    # Fetch album artist from the MusicBrainz release artist-credit.
    # This is the only reliable source for "Various Artists" soundtracks where
    # the track ARTIST differs from the album composer/curator.
    # Only queried when the embedded ALBUMARTIST is missing or generic.
    if _is_generic "${AUDIO_ALBUM_ARTIST:-}"; then
        local release_id
        release_id=$(echo "$mb_resp" | jq -r '.releases[0].id // empty' 2>/dev/null)
        if [[ -n "$release_id" ]]; then
            local mb_release_url="https://musicbrainz.org/ws/2/release/${release_id}?inc=artist-credits&fmt=json"
            _api_rate_limit "musicbrainz"
            local mb_release_resp
            mb_release_resp=$(http_get \
                -H "User-Agent: mylibsystems/2.0 (https://github.com/user/mylibsystems)" \
                "$mb_release_url") || true
            local fetched_album_artist _faa_name _faa_sort
            _faa_name=$(echo "$mb_release_resp" | jq -r '.["artist-credit"][0].artist.name // empty' 2>/dev/null)
            _faa_sort=$(echo "$mb_release_resp" | jq -r '.["artist-credit"][0].artist["sort-name"] // empty' 2>/dev/null)
            fetched_album_artist=$(_prefer_ascii_artist "$_faa_name" "$_faa_sort")
            if ! _is_generic "$fetched_album_artist"; then
                AUDIO_ALBUM_ARTIST="$fetched_album_artist"
                echo "[INFO] Album artist from MusicBrainz release: '${AUDIO_ALBUM_ARTIST}' for album '${fetched_album:-${AUDIO_ALBUM:-}}'" >&2
            fi
        fi
    fi

    # AcoustID identifies the ORIGINAL RECORDING — its title and performer are
    # authoritative for per-track tags (TITLE, ARTIST).
    # ALBUM and YEAR come from the ALBUM CONTEXT (embedded tags or folder), never
    # from the original recording release — a track on a soundtrack may have been
    # first released in 1962 but the album we are importing is from 2010.

    # TITLE — authoritative from MusicBrainz (AcoustID identifies the exact recording)
    if [[ -n "$fetched_title" ]]; then
        if [[ -n "${AUDIO_TITLE:-}" && "${AUDIO_TITLE}" != "$fetched_title" ]]; then
            echo "[INFO] AcoustID: updating title '${AUDIO_TITLE}' → '${fetched_title}' for: $(basename "$file")" >&2
        fi
        AUDIO_TITLE="$fetched_title"
    fi

    # ARTIST — update from MusicBrainz (performer is recording-specific)
    if [[ -n "$fetched_artist" ]]; then
        if [[ -z "${AUDIO_ARTIST:-}" ]]; then
            AUDIO_ARTIST="$fetched_artist"
        elif [[ "${AUDIO_ARTIST}" != "$fetched_artist" ]]; then
            echo "[INFO] AcoustID: updating artist '${AUDIO_ARTIST}' → '${fetched_artist}' for: $(basename "$file")" >&2
            AUDIO_ARTIST="$fetched_artist"
        fi
    fi

    # ALBUM — PRESERVE-FIRST: embedded album is the album context, never overwrite
    [[ -z "${AUDIO_ALBUM:-}" && -n "$fetched_album" ]] && AUDIO_ALBUM="$fetched_album"

    # YEAR — PRESERVE-FIRST: album release year, not original recording year
    [[ -z "${AUDIO_YEAR:-}" && -n "$fetched_year" ]] && AUDIO_YEAR="$fetched_year"

    # GENRE — fill if missing
    [[ -z "${AUDIO_GENRE:-}" && -n "$fetched_genre" ]] && AUDIO_GENRE="$fetched_genre"

    return 0
}

# Resolve the canonical album artist for folder organization.
# Priority: hint (source folder label) → embedded ALBUMARTIST → Last.fm → track ARTIST.
#
# The folder label wins first because it is the ONE value that is identical for
# every track in the same source directory — guaranteeing all tracks land in the
# same output folder regardless of what is embedded in individual files.
# The resolved value is always written back into the output file tags by
# embed_audio_meta, so it overrides whatever was there.
#
# Sets AUDIO_ALBUM_ARTIST. Call this before building output folder paths.
# Usage: resolve_album_artist <hint>   (hint = source folder label)
resolve_album_artist() {
    local hint="${1:-}"

    # _is_generic is defined as a top-level function in metadata.sh

    # 0. Explicit compilation source folder ("Various Artists", "VA", ...).
    #    The user has deliberately grouped multi-artist tracks into one album, so
    #    keep them all under a single canonical album-artist instead of scattering
    #    each track under its own performer (which would split one album into many
    #    one-track folders). Only triggers on real compilation markers — not on
    #    empty/"misc" hints, which fall through to normal resolution below.
    if _is_compilation "$hint"; then
        AUDIO_ALBUM_ARTIST="${COMPILATION_ALBUM_ARTIST:-Various Artists}"
        debug_log "Album artist: compilation source '${hint}' → '${AUDIO_ALBUM_ARTIST}' (album='${AUDIO_ALBUM:-}')"
        return 0
    fi

    # 1. Embedded ALBUMARTIST tag — AUTHORITATIVE (tags-first). The source folder
    #    name is no longer assumed to be the artist: it may encode album/year, or
    #    name the album only, so the embedded tag is trusted ahead of the folder.
    #    A compilation value in the tag maps to the canonical compilation artist.
    if _is_compilation "${AUDIO_ALBUM_ARTIST:-}"; then
        AUDIO_ALBUM_ARTIST="${COMPILATION_ALBUM_ARTIST:-Various Artists}"
        debug_log "Album artist: compilation embedded tag → '${AUDIO_ALBUM_ARTIST}' (album='${AUDIO_ALBUM:-}')"
        return 0
    fi
    if ! _is_generic "${AUDIO_ALBUM_ARTIST:-}"; then
        debug_log "Album artist from embedded tag: '${AUDIO_ALBUM_ARTIST}' (album='${AUDIO_ALBUM:-}')"
        return 0
    fi

    # 2. Source folder label — fallback when the embedded tag is missing/generic.
    #    Consistent across all tracks in the import batch, so it still groups an
    #    album correctly when the files carry no usable album-artist tag.
    if ! _is_generic "$hint"; then
        AUDIO_ALBUM_ARTIST="$hint"
        debug_log "Album artist from source folder: '${AUDIO_ALBUM_ARTIST}' (album='${AUDIO_ALBUM:-}')"
        return 0
    fi

    # 3. Last.fm album.getinfo — query with track ARTIST (not a generic album-artist placeholder).
    #    Use AUDIO_ARTIST so that e.g. a soundtrack with embedded AlbumArtist="Various Artists"
    #    is still looked up correctly via the track's performer.
    local _aa_query
    if ! _is_generic "${AUDIO_ALBUM_ARTIST:-}"; then
        _aa_query="${AUDIO_ALBUM_ARTIST}"
    else
        _aa_query="${AUDIO_ARTIST:-}"
    fi
    if [[ -n "${LASTFM_API_KEY:-}" && -n "$_aa_query" && -n "${AUDIO_ALBUM:-}" ]]; then
        local artist_q album_q lastfm_url lastfm_resp fetched_aa
        artist_q="${_aa_query// /+}"
        album_q="${AUDIO_ALBUM// /+}"
        lastfm_url="https://ws.audioscrobbler.com/2.0/?method=album.getinfo&api_key=${LASTFM_API_KEY}&artist=${artist_q}&album=${album_q}&format=json"
        lastfm_resp=$(http_get "$lastfm_url") || true
        fetched_aa=$(echo "$lastfm_resp" | jq -r '.album.artist // empty' 2>/dev/null)
        if ! _is_generic "$fetched_aa"; then
            AUDIO_ALBUM_ARTIST="$fetched_aa"
            echo "[INFO] Album artist from Last.fm: '${AUDIO_ALBUM_ARTIST}' for album '${AUDIO_ALBUM}'" >&2
            return 0
        fi
    fi

    # 4. Track artist as last resort
    if [[ -n "${AUDIO_ARTIST:-}" ]]; then
        AUDIO_ALBUM_ARTIST="${AUDIO_ARTIST}"
        return 0
    fi

    AUDIO_ALBUM_ARTIST="Unknown Artist"
}

# Fetch cover art from MusicBrainz CAA; fall back to Last.fm.
# Writes cover image to $cover_out_path on success.
fetch_audio_cover() {
    local artist="${AUDIO_ARTIST:-}"
    local album="${AUDIO_ALBUM:-}"
    local cover_out_path="$1"

    [[ -z "$artist" || -z "$album" ]] && return 0

    # 1. MusicBrainz CAA
    local mb_search_url="https://musicbrainz.org/ws/2/release/?query=artist:${artist// /+}+release:${album// /+}&limit=1&fmt=json"
    _api_rate_limit "musicbrainz"
    local mb_search
    mb_search=$(http_get \
        -H "User-Agent: mylibsystems/2.0 (https://github.com/user/mylibsystems)" \
        "$mb_search_url") || true

    local release_id
    release_id=$(echo "$mb_search" | jq -r '.releases[0].id // empty' 2>/dev/null)

    if [[ -n "$release_id" ]]; then
        local caa_url="https://coverartarchive.org/release/${release_id}/front-500"
        if http_download "$cover_out_path" "$caa_url"; then
            echo "[INFO] Cover art fetched from MusicBrainz CAA for '${artist} - ${album}'" >&2
            return 0
        fi
    fi

    # 2. Last.fm fallback
    if [[ -n "${LASTFM_API_KEY:-}" ]]; then
        local lastfm_url="https://ws.audioscrobbler.com/2.0/?method=album.getinfo&api_key=${LASTFM_API_KEY}&artist=${artist// /+}&album=${album// /+}&format=json"
        local lastfm_resp
        lastfm_resp=$(http_get "$lastfm_url") || return 0
        local img_url
        img_url=$(echo "$lastfm_resp" | jq -r '.album.image[-1]["#text"] // empty' 2>/dev/null)
        if [[ -n "$img_url" ]]; then
            http_download "$cover_out_path" "$img_url" && \
                echo "[INFO] Cover art fetched from Last.fm for '${artist} - ${album}'" >&2
        fi
    fi
}

# Embed ONLY cover art (no text tags) into a FLAC or M4A file. Used by the
# organizer's retry-safe backfill on the skip paths, where the full AUDIO_* tag
# set is intentionally NOT resolved (those paths avoid the AcoustID lookup), so
# calling embed_audio_meta there would overwrite the file's already-correct tags
# with placeholders. This touches the PICTURE/artwork block only. Returns
# non-zero on a writer error so the caller can surface/retry.
embed_audio_cover_only() {
    local file="$1"
    local cover_path="${2:-}"
    [[ -n "$cover_path" && -f "$cover_path" ]] || return 0
    local ext="${file##*.}"
    ext="$(tr '[:upper:]' '[:lower:]' <<< "$ext")"

    case "$ext" in
        flac)
            metaflac --remove --block-type=PICTURE --dont-use-padding "$file" 2>/dev/null || true
            metaflac --import-picture-from="3|image/jpeg|||${cover_path}" "$file"
            ;;
        m4a|mp4)
            if command -v AtomicParsley &>/dev/null; then
                local _ap_out _ap_rc
                _ap_out="$(AtomicParsley "$file" --overWrite --artwork "$cover_path" 2>&1)"; _ap_rc=$?
                rm -f "${file%.*}-temp-"*.m4a 2>/dev/null || true
                if (( _ap_rc != 0 )) || printf '%s' "$_ap_out" | grep -qi 'AP error\|error trying to fopen'; then
                    echo "[WARN] AtomicParsley artwork failed (rc=${_ap_rc}) for $(basename "$file"); will retry: ${_ap_out//$'\n'/ }" >&2
                    return 1
                fi
            else
                # No AtomicParsley: rewrite the covr atom via ffmpeg (mirrors the
                # exiftool-fallback branch in embed_audio_meta).
                local _m4a_tmp="${file%.*}_covr_tmp.m4a"
                if ffmpeg -nostdin -v error -y \
                        -i "$file" -i "$cover_path" \
                        -map 0:a -map 1:v \
                        -c:a copy -c:v mjpeg \
                        -disposition:1 attached_pic \
                        -movflags +faststart \
                        "$_m4a_tmp" 2>/dev/null && [[ -s "$_m4a_tmp" ]]; then
                    mv "$_m4a_tmp" "$file"
                else
                    rm -f "$_m4a_tmp"
                    echo "[WARN] ffmpeg covr embed failed for: $(basename "$file")" >&2
                    return 1
                fi
            fi
            ;;
        *)
            return 0
            ;;
    esac
    return 0
}

# Embed audio metadata (tags + cover art) into a FLAC or M4A file.
embed_audio_meta() {
    local file="$1"
    local cover_path="${2:-}"   # optional path to cover image
    local ext="${file##*.}"
    ext="$(tr '[:upper:]' '[:lower:]' <<< "$ext")"

    case "$ext" in
        flac)
            # metaflac for FLAC
            if [[ -n "${AUDIO_TITLE:-}"        ]]; then metaflac --remove-tag=TITLE        --set-tag="TITLE=${AUDIO_TITLE}"               "$file"; fi
            if [[ -n "${AUDIO_ARTIST:-}"       ]]; then metaflac --remove-tag=ARTIST       --set-tag="ARTIST=${AUDIO_ARTIST}"             "$file"; fi
            if [[ -n "${AUDIO_ALBUM_ARTIST:-}" ]]; then metaflac --remove-tag=ALBUMARTIST  --set-tag="ALBUMARTIST=${AUDIO_ALBUM_ARTIST}"  "$file"; fi
            if [[ -n "${AUDIO_ALBUM:-}"        ]]; then metaflac --remove-tag=ALBUM        --set-tag="ALBUM=${AUDIO_ALBUM}"               "$file"; fi
            if [[ -n "${AUDIO_YEAR:-}"         ]]; then metaflac --remove-tag=DATE         --set-tag="DATE=${AUDIO_YEAR}"                 "$file"; fi
            if [[ -n "${AUDIO_TRACK:-}"        ]]; then metaflac --remove-tag=TRACKNUMBER  --set-tag="TRACKNUMBER=${AUDIO_TRACK}"         "$file"; fi
            if [[ -n "${AUDIO_DISC:-}"         ]]; then metaflac --remove-tag=DISCNUMBER   --set-tag="DISCNUMBER=${AUDIO_DISC}"           "$file"; fi
            if [[ -n "${AUDIO_GENRE:-}"        ]]; then metaflac --remove-tag=GENRE        --set-tag="GENRE=${AUDIO_GENRE}"               "$file"; fi
            if [[ -n "$cover_path" && -f "$cover_path" ]]; then
                metaflac --remove --block-type=PICTURE --dont-use-padding "$file" 2>/dev/null || true
                metaflac --import-picture-from="3|image/jpeg|||${cover_path}" "$file"
            fi
            ;;
        m4a|mp4)
            if command -v AtomicParsley &>/dev/null; then
                local args=("$file" --overWrite)
                [[ -n "${AUDIO_TITLE:-}"        ]] && args+=(--title       "${AUDIO_TITLE}")
                [[ -n "${AUDIO_ARTIST:-}"       ]] && args+=(--artist      "${AUDIO_ARTIST}")
                [[ -n "${AUDIO_ALBUM_ARTIST:-}" ]] && args+=(--albumArtist "${AUDIO_ALBUM_ARTIST}")
                [[ -n "${AUDIO_ALBUM:-}"        ]] && args+=(--album       "${AUDIO_ALBUM}")
                [[ -n "${AUDIO_YEAR:-}"         ]] && args+=(--year        "${AUDIO_YEAR}")
                [[ -n "${AUDIO_TRACK:-}"        ]] && args+=(--tracknum    "${AUDIO_TRACK}")
                [[ -n "${AUDIO_DISC:-}"         ]] && args+=(--disk        "${AUDIO_DISC}")
                [[ -n "${AUDIO_GENRE:-}"        ]] && args+=(--genre       "${AUDIO_GENRE}")
                [[ -n "$cover_path" && -f "$cover_path" ]] && args+=(--artwork "$cover_path")
                # Capture AtomicParsley's combined output so a fopen/permission
                # failure (common on external-USB races) is detected and surfaced
                # as a tagged [WARN]. Otherwise AP's raw "AP error trying to fopen"
                # line is untagged, never matches LOG_CAPTURE_TAGS, and so never
                # reaches SYNC_LOG — making post-run analysis blind to the single
                # most common failure mode. Returning non-zero lets import.sh's
                # sequential retry phase re-run the file (the race is transient and
                # clears on the second pass). On success the captured output is
                # discarded, which also quiets AP's normal progress firehose.
                local _ap_out _ap_rc
                _ap_out="$(AtomicParsley "${args[@]}" 2>&1)"; _ap_rc=$?
                # AtomicParsley --overWrite writes <basename>-temp-<pid>.m4a then
                # renames it onto the original; on external-USB fopen races it can
                # leave a 0-byte temp orphan behind. Sweep it so DESKTOP/PORTABLE
                # track counts stay in parity.
                rm -f "${file%.*}-temp-"*.m4a 2>/dev/null || true
                if (( _ap_rc != 0 )) || printf '%s' "$_ap_out" | grep -qi 'AP error\|error trying to fopen'; then
                    echo "[WARN] AtomicParsley failed (rc=${_ap_rc}) for $(basename "$file"); will retry: ${_ap_out//$'\n'/ }" >&2
                    return 1
                fi
            else
                # exiftool fallback (always available) — text tags only, NO artwork
                # exiftool writes artwork to [Keys] namespace (QuickTime), which old
                # devices like Sony Walkman NWZ-A720 do not recognize. Cover art is
                # embedded separately via ffmpeg below, which writes the proper
                # iTunes [ItemList] covr atom.
                # `-q -q` silences exiftool's "N image files updated" stdout summary
                # (it prints "image" for every type, incl. m4a); the FLAC/AtomicParsley
                # writers are silent too, so keep this consistent.
                local et_args=(-q -q -overwrite_original)
                [[ -n "${AUDIO_TITLE:-}"        ]] && et_args+=("-Title=${AUDIO_TITLE}")
                [[ -n "${AUDIO_ARTIST:-}"       ]] && et_args+=("-Artist=${AUDIO_ARTIST}")
                [[ -n "${AUDIO_ALBUM_ARTIST:-}" ]] && et_args+=("-AlbumArtist=${AUDIO_ALBUM_ARTIST}")
                [[ -n "${AUDIO_ALBUM:-}"        ]] && et_args+=("-Album=${AUDIO_ALBUM}")
                [[ -n "${AUDIO_YEAR:-}"         ]] && et_args+=("-Year=${AUDIO_YEAR}")
                [[ -n "${AUDIO_TRACK:-}"        ]] && et_args+=("-TrackNumber=${AUDIO_TRACK}")
                [[ -n "${AUDIO_DISC:-}"         ]] && et_args+=("-DiscNumber=${AUDIO_DISC}")
                [[ -n "${AUDIO_GENRE:-}"        ]] && et_args+=("-Genre=${AUDIO_GENRE}")
                exiftool "${et_args[@]}" "$file" 2>/dev/null
                # Embed cover art via ffmpeg into the iTunes covr atom
                if [[ -n "$cover_path" && -f "$cover_path" ]]; then
                    local _m4a_tmp="${file%.*}_covr_tmp.m4a"
                    if ffmpeg -nostdin -v error -y \
                            -i "$file" -i "$cover_path" \
                            -map 0:a -map 1:v \
                            -c:a copy -c:v mjpeg \
                            -disposition:1 attached_pic \
                            -movflags +faststart \
                            "$_m4a_tmp" 2>/dev/null && [[ -s "$_m4a_tmp" ]]; then
                        mv "$_m4a_tmp" "$file"
                    else
                        rm -f "$_m4a_tmp"
                        debug_log "[WARN] ffmpeg covr embed failed for: $file"
                    fi
                fi
            fi
            ;;
        mp3)
            # eyeD3 for MP3
            local e3_args=()
            [[ -n "${AUDIO_TITLE:-}"  ]] && e3_args+=(--title  "${AUDIO_TITLE}")
            [[ -n "${AUDIO_ARTIST:-}" ]] && e3_args+=(--artist "${AUDIO_ARTIST}")
            [[ -n "${AUDIO_ALBUM:-}"  ]] && e3_args+=(--album  "${AUDIO_ALBUM}")
            [[ -n "${AUDIO_YEAR:-}"   ]] && e3_args+=(--release-year "${AUDIO_YEAR}")
            [[ -n "${AUDIO_TRACK:-}"  ]] && e3_args+=(--track  "${AUDIO_TRACK}")
            [[ -n "${AUDIO_GENRE:-}"  ]] && e3_args+=(--genre  "${AUDIO_GENRE}")
            if [[ -n "$cover_path" && -f "$cover_path" ]]; then
                e3_args+=(--add-image "${cover_path}:FRONT_COVER")
            fi
            [[ -n "${AUDIO_ALBUM_ARTIST:-}" ]] && e3_args+=(--album-artist "${AUDIO_ALBUM_ARTIST}")
            eyeD3 ${e3_args[@]:+"${e3_args[@]}"} "$file" 2>/dev/null
            ;;
    esac
}

# ---------------------------------------------------------------------------
# Video metadata — TMDB (PRESERVE-FIRST)
# ---------------------------------------------------------------------------

# Read existing video tags from an MP4 using exiftool.
# Populates VIDEO_TITLE, VIDEO_YEAR, VIDEO_GENRE, VIDEO_DESC, VIDEO_TVSHOW,
#   VIDEO_SEASON, VIDEO_EPISODE
read_video_tags() {
    local file="$1"
    local json
    # Request the exact MP4/ItemList atoms the desktop pipeline writes, then map
    # each to the canonical VIDEO_* name the rest of the code consumes. The atom
    # names (ContentCreateDate/TVShow/TVSeason/TVEpisodeID) differ from the plain
    # tag names, so an auto key->var mapping would silently drop show/season/episode.
    json=$(exiftool -m -json \
        -Title -ContentCreateDate -Genre -Description -TVShow -TVSeason -TVEpisodeID \
        "$file" 2>/dev/null) || return 0
    [[ -z "$json" ]] && return 0
    jq -r '.[0] // {} |
        (if .Title             then "VIDEO_TITLE=\(.Title|tostring|@sh)"                       else empty end),
        (if .ContentCreateDate then "VIDEO_YEAR=\(((.ContentCreateDate|tostring)[0:4])|@sh)"    else empty end),
        (if .Genre             then "VIDEO_GENRE=\(.Genre|tostring|@sh)"                        else empty end),
        (if .Description       then "VIDEO_DESC=\(.Description|tostring|@sh)"                    else empty end),
        (if .TVShow            then "VIDEO_TVSHOW=\(.TVShow|tostring|@sh)"                      else empty end),
        (if .TVSeason          then "VIDEO_SEASON=\(.TVSeason|tostring|@sh)"                    else empty end),
        (if .TVEpisodeID       then "VIDEO_EPISODE=\(.TVEpisodeID|tostring|@sh)"                else empty end)
    ' 2>/dev/null <<<"$json"
}

# Detect whether a video is a movie or TV episode.
# Sets VIDEO_TYPE to "movie" or "tv" (heuristic: S##E## pattern).
detect_video_type() {
    local filepath="$1"
    local basename
    basename="$(basename "$filepath")"
    # Match common TV episode naming conventions (conservative — used for non-TV-root auto-detection):
    #   S##E##  S##.E##  S##_E##  (standard + dot/underscore separator)
    #   ##x##   S##x##            (season x episode: 1x01, 01x02, S01x01)
    if echo "$basename" | grep -qiE 'S[0-9]{1,2}[._]?E[0-9]{1,2}|[Ss]?[0-9]{1,2}x[0-9]{2}[^0-9]'; then
        VIDEO_TYPE="tv"
    else
        VIDEO_TYPE="movie"
    fi
}

# Parse a raw video filename into a clean title + year hint.
# Handles scene-release names (dots/underscores as separators, quality markers).
# Sets VIDEO_TITLE_HINT and VIDEO_YEAR_HINT.
parse_video_filename() {
    local base="$1"
    # Replace dots and underscores with spaces
    local cleaned="${base//[._]/ }"
    local year=""
    # Extract 4-digit year (1900-2099) surrounded by spaces or at boundaries
    if echo "$cleaned" | grep -qE '(^| )(19|20)[0-9]{2}( |$)'; then
        year="$(echo "$cleaned" | grep -oE '(19|20)[0-9]{2}' | head -1)"
        # Keep only the part before the year (strips year + quality tags after it)
        cleaned="${cleaned%% ${year}*}"
    else
        # No year found — strip trailing resolution/codec tags
        cleaned="$(echo "$cleaned" | sed -E 's/ [0-9]{3,4}[pPiI].*//' )"
        cleaned="$(echo "$cleaned" | sed -E 's/ (BluRay|BDRip|BRRip|DVDRip|WEBRip|HDRip|HDTV|REMUX|REPACK|PROPER|EXTENDED|IMAX).*//')"
    fi
    cleaned="$(echo "$cleaned" | sed 's/  */ /g; s/^[[:space:]]*//; s/[[:space:]]*$//')"
    VIDEO_TITLE_HINT="${cleaned:-$base}"
    VIDEO_YEAR_HINT="${year:-}"
}

# Convert trailing Roman numerals (II–XII) in a title to Arabic digits.
# "Cars II" → "Cars 2", "Rocky III" → "Rocky 3", etc.
# Only matches at end-of-string to avoid clobbering words like "Will".
_roman_to_arabic() {
    echo "$1" | sed -E \
        -e 's/ XII$/ 12/' -e 's/ XI$/ 11/' -e 's/ X$/ 10/' \
        -e 's/ IX$/ 9/'   -e 's/ VIII$/ 8/' -e 's/ VII$/ 7/' \
        -e 's/ VI$/ 6/'   -e 's/ V$/ 5/'    -e 's/ IV$/ 4/'  \
        -e 's/ III$/ 3/'  -e 's/ II$/ 2/'
}

# Check that a TMDB result title is similar enough to the search query.
# Returns 0 (success) when at least half the query words appear in the result title.
_tmdb_title_matches() {
    local query="$1" result_title="$2"
    awk -v q="$query" -v r="$result_title" 'BEGIN {
        gsub(/[^a-zA-Z0-9 ]/, " ", q); gsub(/[^a-zA-Z0-9 ]/, " ", r)
        n = split(tolower(q), qw, " ")
        rstr = " " tolower(r) " "
        hits = 0
        for (i = 1; i <= n; i++) {
            if (length(qw[i]) > 1 && index(rstr, " " qw[i] " ") > 0) hits++
        }
        # Need at least half the query words (min 1) found in the result
        exit (n > 0 && hits * 2 >= n) ? 0 : 1
    }' /dev/null
}

# Query TMDB for movie metadata; fills VIDEO_* variables if not already set.
fetch_video_meta_movie() {
    local title="$1"
    local year="${2:-}"

    [[ -z "${TMDB_API_KEY:-}" ]] && { echo "[WARN] TMDB_API_KEY not set; skipping movie lookup" >&2; return 0; }

    # Normalise the search title: convert trailing Roman numerals → Arabic digits
    # so "Cars II" finds "Cars 2" (Pixar) instead of a random Danish sequel.
    local search_title
    search_title="$(_roman_to_arabic "$title")"

    local query_url="https://api.themoviedb.org/3/search/movie?api_key=${TMDB_API_KEY}&language=en-US&query=${search_title// /+}"
    [[ -n "$year" ]] && query_url+="&year=${year}"

    local resp
    resp=$(http_get "$query_url") || return 0

    local result_count
    result_count=$(echo "$resp" | jq -r '.results | length' 2>/dev/null)
    [[ -z "$result_count" || "$result_count" == "0" ]] && return 0

    # Prefer an exact (case-insensitive) title match over results[0].
    # This avoids cases like "Home Alone" → "Home Alone 3" or "The King" → "The Lion King"
    # where results[0] is a partial match that is not the intended film.
    local movie_id="" chosen_title="" i=0
    local search_title_lc
    search_title_lc="$(echo "$search_title" | tr '[:upper:]' '[:lower:]')"
    while [[ $i -lt $result_count ]]; do
        local cand_id cand_title cand_title_lc
        cand_id=$(echo "$resp"    | jq -r ".results[$i].id    // empty" 2>/dev/null)
        cand_title=$(echo "$resp" | jq -r ".results[$i].title // empty" 2>/dev/null)
        cand_title_lc="$(echo "$cand_title" | tr '[:upper:]' '[:lower:]')"
        if [[ "$cand_title_lc" == "$search_title_lc" ]]; then
            movie_id="$cand_id"
            chosen_title="$cand_title"
            break
        fi
        (( i++ )) || true
    done

    # Fall back to results[0] if no exact match, with a sanity-check.
    if [[ -z "$movie_id" ]]; then
        movie_id=$(echo "$resp"    | jq -r '.results[0].id    // empty' 2>/dev/null)
        chosen_title=$(echo "$resp" | jq -r '.results[0].title // empty' 2>/dev/null)
        if ! _tmdb_title_matches "$search_title" "$chosen_title"; then
            # Weak title match. Accept anyway when the caller supplied a year and
            # the top result's release year matches it exactly — TMDB already
            # filtered the search by that year, so a year-exact top hit is a strong
            # signal. This handles films whose TMDB title differs from the release
            # name, e.g. "Star Wars Episode IV - A New Hope" whose canonical TMDB
            # title is simply "Star Wars" (1977).
            local cand_year
            cand_year=$(echo "$resp" | jq -r '.results[0].release_date // empty' 2>/dev/null | cut -c1-4)
            if [[ -n "$year" && -n "$cand_year" && "$cand_year" == "$year" ]]; then
                echo "[INFO] TMDB result '${chosen_title}' accepted via exact year match (${year}) despite weak title match to '${search_title}'" >&2
            else
                echo "[WARN] TMDB result '${chosen_title}' does not match query '${search_title}'; skipping" >&2
                return 0
            fi
        fi
    fi
    [[ -z "$movie_id" ]] && return 0

    local detail_url="https://api.themoviedb.org/3/movie/${movie_id}?api_key=${TMDB_API_KEY}&language=en-US&append_to_response=credits"
    local detail
    detail=$(http_get "$detail_url") || return 0

    local fetched_title fetched_year fetched_genre fetched_desc fetched_poster
    fetched_title=$(echo "$detail" | jq -r '.title // empty')
    fetched_year=$(echo "$detail"  | jq -r '.release_date // empty' | cut -c1-4)
    fetched_genre=$(echo "$detail" | jq -r '.genres[0].name // empty')
    fetched_desc=$(echo "$detail"  | jq -r '.overview // empty')
    fetched_poster=$(echo "$detail" | jq -r '.poster_path // empty')

    # Apply a curated canonical-title override from aliases.conf (@movie entries),
    # if one matches TMDB's title. Lets curated films (e.g. the Star Wars sequel
    # trilogy) carry the numbered "Episode N" title convention used by the rest of
    # the series. This drives both the embedded title and the sanitized folder/file
    # name below.
    local _title_override
    if _title_override="$(_lookup_movie_title_override "$fetched_title")"; then
        fetched_title="$_title_override"
    fi

    [[ -z "${VIDEO_TITLE:-}" && -n "$fetched_title"  ]] && VIDEO_TITLE="$fetched_title"
    [[ -z "${VIDEO_YEAR:-}"  && -n "$fetched_year"   ]] && VIDEO_YEAR="$fetched_year"
    [[ -z "${VIDEO_GENRE:-}" && -n "$fetched_genre"  ]] && VIDEO_GENRE="$fetched_genre"
    [[ -z "${VIDEO_DESC:-}"  && -n "$fetched_desc"   ]] && VIDEO_DESC="$fetched_desc"

    if [[ -n "$fetched_poster" ]]; then
        VIDEO_POSTER_URL="https://image.tmdb.org/t/p/original${fetched_poster}"
    fi
}

# Query TMDB for TV episode metadata; fills VIDEO_* variables if not already set.
fetch_video_meta_tv() {
    local series_name="$1"
    local season="${2:-1}"
    local episode="${3:-1}"

    [[ -z "${TMDB_API_KEY:-}" ]] && { echo "[WARN] TMDB_API_KEY not set; skipping TV lookup" >&2; return 0; }

    local search_url="https://api.themoviedb.org/3/search/tv?api_key=${TMDB_API_KEY}&language=en-US&query=${series_name// /+}"
    local resp
    resp=$(http_get "$search_url") || return 0

    # TMDB sorts results by title match, not by popularity. A spin-off or special may
    # appear first even though it has no episode data. Re-sort by popularity descending
    # so the main series (highest audience) is tried before obscure spin-offs, then use
    # the first result that actually has the requested episode.
    local result_count
    result_count=$(echo "$resp" | jq -r '.results | length' 2>/dev/null)
    [[ -z "$result_count" || "$result_count" -eq 0 ]] && return 0

    # Build popularity-sorted index list: "popularity:original_index" pairs, sorted desc
    local sorted_indices=()
    local _sort_raw
    _sort_raw=$(echo "$resp" | jq -r '[.results | to_entries[] | {idx: .key, pop: .value.popularity}] | sort_by(.pop) | reverse | .[].idx' 2>/dev/null) || true
    if [[ -n "$_sort_raw" ]]; then
        while IFS= read -r _idx; do sorted_indices+=("$_idx"); done <<< "$_sort_raw"
    else
        # jq unavailable or failed — fall back to original order
        local _fi; for (( _fi=0; _fi<result_count; _fi++ )); do sorted_indices+=("$_fi"); done
    fi

    local series_id="" ep_resp="" fetched_ep_title="" matched_idx=0
    local i=0
    while [[ $i -lt ${#sorted_indices[@]} ]]; do
        local candidate_id
        candidate_id=$(echo "$resp" | jq -r ".results[${sorted_indices[$i]}].id // empty" 2>/dev/null)
        [[ -z "$candidate_id" ]] && (( i++ )) && continue

        local ep_url="https://api.themoviedb.org/3/tv/${candidate_id}/season/${season}/episode/${episode}?api_key=${TMDB_API_KEY}&language=en-US"
        local candidate_ep
        candidate_ep=$(http_get "$ep_url") || { (( i++ )) || true; continue; }

        fetched_ep_title=$(echo "$candidate_ep" | jq -r '.name // empty' 2>/dev/null)
        if [[ -n "$fetched_ep_title" ]]; then
            series_id="$candidate_id"
            ep_resp="$candidate_ep"
            matched_idx=${sorted_indices[$i]}
            break
        fi
        (( i++ ))
    done

    # If no result had the episode, nothing to populate
    [[ -z "$series_id" ]] && return 0

    local fetched_air_date fetched_desc fetched_still fetched_show_name fetched_genre
    fetched_air_date=$(echo "$ep_resp"  | jq -r '.air_date // empty')
    fetched_desc=$(echo "$ep_resp"      | jq -r '.overview // empty')
    fetched_still=$(echo "$ep_resp"     | jq -r '.still_path // empty')
    fetched_show_name=$(echo "$resp"    | jq -r ".results[${matched_idx}].name // empty")
    fetched_genre=$(echo "$resp"        | jq -r ".results[${matched_idx}].genre_ids[0] // empty")

    [[ -z "${VIDEO_TITLE:-}"  && -n "$fetched_ep_title" ]] && VIDEO_TITLE="$fetched_ep_title"
    [[ -z "${VIDEO_YEAR:-}"   && -n "$fetched_air_date" ]] && VIDEO_YEAR="${fetched_air_date:0:4}"
    [[ -z "${VIDEO_DESC:-}"   && -n "$fetched_desc"     ]] && VIDEO_DESC="$fetched_desc"
    [[ -z "${VIDEO_TVSHOW:-}" && -n "$fetched_show_name" ]] && VIDEO_TVSHOW="$fetched_show_name"
    VIDEO_SEASON="$season"
    VIDEO_EPISODE="$episode"

    # Always prefer the series-level poster artwork over the episode screenshot (still_path)
    local series_poster
    series_poster=$(echo "$resp" | jq -r ".results[${matched_idx}].poster_path // empty")
    if [[ -n "$series_poster" ]]; then
        VIDEO_POSTER_URL="https://image.tmdb.org/t/p/original${series_poster}"
    elif [[ -n "$fetched_still" ]]; then
        VIDEO_POSTER_URL="https://image.tmdb.org/t/p/original${fetched_still}"
    fi
}

# _title_word_score "hint title" "episode title"
# Returns 0-100: percentage of hint words (length >= 3) that appear in the episode title.
# Words are whole-word matched after lowercasing and stripping punctuation.
_title_word_score() {
    local hint="$1" ep="$2"
    local e_str
    e_str=$(printf '%s' "$ep" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' ' ' | tr -s ' ')
    local total=0 matched=0 word
    for word in $(printf '%s' "$hint" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' ' ' | tr -s ' '); do
        [[ ${#word} -lt 3 ]] && continue
        total=$((total + 1))
        [[ " $e_str " == *" $word "* ]] && matched=$((matched + 1))
    done
    [[ $total -eq 0 ]] && printf '0' && return
    printf '%d' $((matched * 100 / total))
}

# _lookup_title_alias series_name title_hint
# Checks aliases.conf for a regional/alternate episode title mapping.
# File format: show_pattern|alternate_title|canonical_tmdb_title
#   show_pattern is a case-insensitive substring matched against series_name, or "*" for any show.
# Prints the canonical TMDB title and returns 0 when a mapping is found; returns 1 otherwise.
_lookup_title_alias() {
    local series="$1" hint="$2"
    local alias_file
    # Resolve the alias file relative to this script regardless of the caller's CWD.
    alias_file="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)/aliases.conf"
    [[ -f "$alias_file" ]] || return 1

    local series_low hint_low pat alt canonical pat_low alt_low
    series_low=$(printf '%s' "$series" | tr '[:upper:]' '[:lower:]')
    hint_low=$(printf '%s'   "$hint"   | tr '[:upper:]' '[:lower:]')

    while IFS='|' read -r pat alt canonical; do
        # Skip comments and blank/malformed lines
        [[ -z "$pat" || "$pat" == '#'* ]] && continue
        [[ -z "$alt" || -z "$canonical" ]] && continue
        pat_low=$(printf '%s' "$pat" | tr '[:upper:]' '[:lower:]')
        alt_low=$(printf '%s' "$alt" | tr '[:upper:]' '[:lower:]')
        # Show pattern: "*" matches any show; otherwise substring match (bidirectional)
        if [[ "$pat_low" == '*' ]] \
            || [[ "$series_low" == *"$pat_low"* ]] \
            || [[ "$pat_low" == *"$series_low"* ]]; then
            if [[ "$hint_low" == "$alt_low" ]]; then
                printf '%s' "$canonical"
                return 0
            fi
        fi
    done < "$alias_file"
    return 1
}

# _lookup_movie_title_override tmdb_title
# Checks aliases.conf for a curated movie-title override (see header section 2).
# File format for these lines: @movie|tmdb_title|canonical_title
#   The literal "@movie" marker in field 1 selects this lookup; TV alias lines are
#   ignored here (their field 1 is a show name, never "@movie").
# Prints the canonical override title and returns 0 when a mapping is found;
# returns 1 otherwise.
_lookup_movie_title_override() {
    local tmdb_title="$1"
    [[ -z "$tmdb_title" ]] && return 1
    local alias_file
    # Resolve the alias file relative to this script regardless of the caller's CWD.
    alias_file="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)/aliases.conf"
    [[ -f "$alias_file" ]] || return 1

    local title_low pat alt canonical pat_low alt_low
    title_low=$(printf '%s' "$tmdb_title" | tr '[:upper:]' '[:lower:]')

    while IFS='|' read -r pat alt canonical; do
        # Only "@movie" lines apply; skip comments, blanks and TV alias lines.
        [[ -z "$pat" || "$pat" == '#'* ]] && continue
        [[ -z "$alt" || -z "$canonical" ]] && continue
        pat_low=$(printf '%s' "$pat" | tr '[:upper:]' '[:lower:]')
        [[ "$pat_low" == '@movie' ]] || continue
        alt_low=$(printf '%s' "$alt" | tr '[:upper:]' '[:lower:]')
        if [[ "$title_low" == "$alt_low" ]]; then
            printf '%s' "$canonical"
            return 0
        fi
    done < "$alias_file"
    return 1
}

# Look up a TV episode by title similarity within a season, optionally confirmed by duration.
# Strategy: score every episode in the season using word-overlap title similarity (0-100)
# combined with optional duration match (0-100).  When duration_secs is provided the
# combined score is title*60% + duration*40%; otherwise combined = title score.
# A match is accepted only when combined_score >= 60.
# Args: series_name season title_hint [duration_secs]
# On success: sets VIDEO_TITLE, VIDEO_YEAR, VIDEO_DESC, VIDEO_TVSHOW, VIDEO_SEASON,
#   VIDEO_EPISODE, VIDEO_POSTER_URL.  Returns 0 on match, 1 when not found.
fetch_video_meta_tv_by_title() {
    local series_name="$1"
    local season="${2:-1}"
    local title_hint="$3"
    local duration_secs="${4:-0}"

    [[ -z "${TMDB_API_KEY:-}" ]] && return 1
    [[ -z "$title_hint" ]]       && return 1

    # Resolve regional/alternate episode title aliases before any scoring
    # (e.g. UK "Air Crash Investigation" titles differ from Canadian "Mayday" titles in TMDB)
    local _alias_resolved
    if _alias_resolved=$(_lookup_title_alias "$series_name" "$title_hint"); then
        title_hint="$_alias_resolved"
    fi

    local search_url="https://api.themoviedb.org/3/search/tv?api_key=${TMDB_API_KEY}&language=en-US&query=${series_name// /+}"
    local resp
    resp=$(http_get "$search_url") || return 1

    local result_count
    result_count=$(echo "$resp" | jq -r '.results | length' 2>/dev/null)
    [[ -z "$result_count" || "$result_count" -eq 0 ]] && return 1

    # Sort candidates by popularity descending (main show before spin-offs)
    local sorted_indices=()
    local _sort_raw
    _sort_raw=$(echo "$resp" | jq -r '[.results | to_entries[] | {idx: .key, pop: .value.popularity}] | sort_by(.pop) | reverse | .[].idx' 2>/dev/null) || true
    if [[ -n "$_sort_raw" ]]; then
        while IFS= read -r _idx; do sorted_indices+=("$_idx"); done <<< "$_sort_raw"
    else
        local _fi; for (( _fi=0; _fi<result_count; _fi++ )); do sorted_indices+=("$_fi"); done
    fi

    # For "Flight 447. Vanished" style titles, also try matching on just the part after ". "
    local hint_short=""
    if [[ "$title_hint" == *". "* ]]; then
        local _sp="${title_hint##*. }"
        [[ ${#_sp} -gt 3 ]] && hint_short="$_sp"
    fi

    # Track the best-scoring episode across all show candidates.
    # Minimum acceptance threshold: combined score must be > 59 (i.e., >= 60).
    local best_score=59
    local best_ep_name="" best_ep_num="" best_ep_air_date="" best_ep_desc=""
    local best_ep_still="" best_poster="" best_cand_name=""
    local best_ep_season="$season"   # may differ from $season on cross-season match (Pass 3)

    local i=0
    while [[ $i -lt ${#sorted_indices[@]} ]]; do
        local candidate_id candidate_name
        candidate_id=$(echo "$resp"   | jq -r ".results[${sorted_indices[$i]}].id   // empty" 2>/dev/null)
        candidate_name=$(echo "$resp" | jq -r ".results[${sorted_indices[$i]}].name // empty" 2>/dev/null)
        [[ -z "$candidate_id" ]] && (( i++ )) && continue

        local season_url="https://api.themoviedb.org/3/tv/${candidate_id}/season/${season}?api_key=${TMDB_API_KEY}&language=en-US"
        local season_resp
        season_resp=$(http_get "$season_url") || { (( i++ )) || true; continue; }

        local ep_count
        ep_count=$(echo "$season_resp" | jq -r '.episodes | length' 2>/dev/null)
        [[ -z "$ep_count" || "$ep_count" -eq 0 ]] && { (( i++ )) || true; continue; }

        local series_poster_this
        series_poster_this=$(echo "$resp" | jq -r ".results[${sorted_indices[$i]}].poster_path // empty" 2>/dev/null)

        local j=0
        while [[ $j -lt $ep_count ]]; do
            local ep_name ep_num ep_runtime
            ep_name=$(echo "$season_resp"    | jq -r ".episodes[$j].name           // empty" 2>/dev/null)
            ep_num=$(echo "$season_resp"     | jq -r ".episodes[$j].episode_number // empty" 2>/dev/null)
            ep_runtime=$(echo "$season_resp" | jq -r ".episodes[$j].runtime        // 0"     2>/dev/null)
            ep_runtime="${ep_runtime:-0}"

            # Title similarity: best of full hint vs short hint
            local t_score
            t_score=$(_title_word_score "$title_hint" "$ep_name")
            if [[ -n "$hint_short" ]]; then
                local _ts2
                _ts2=$(_title_word_score "$hint_short" "$ep_name")
                (( _ts2 > t_score )) && t_score=$_ts2
            fi

            # Duration confirmation (weighted 40% when runtime available)
            local combined=$t_score
            if [[ "${duration_secs:-0}" -gt 0 && "${ep_runtime:-0}" -gt 0 ]]; then
                local _src_mins=$(( duration_secs / 60 ))
                local _diff=$(( _src_mins - ep_runtime ))
                [[ $_diff -lt 0 ]] && _diff=$(( -_diff ))
                local d_score
                if   (( _diff <= 2  )); then d_score=100
                elif (( _diff <= 5  )); then d_score=80
                elif (( _diff <= 10 )); then d_score=50
                elif (( _diff <= 20 )); then d_score=20
                else                         d_score=0
                fi
                combined=$(( t_score * 60 / 100 + d_score * 40 / 100 ))
            fi

            if (( combined > best_score )); then
                best_score=$combined
                best_ep_name="$ep_name"
                best_ep_num="$ep_num"
                best_ep_air_date=$(echo "$season_resp" | jq -r ".episodes[$j].air_date  // empty" 2>/dev/null)
                best_ep_desc=$(echo "$season_resp"     | jq -r ".episodes[$j].overview  // empty" 2>/dev/null)
                best_ep_still=$(echo "$season_resp"    | jq -r ".episodes[$j].still_path // empty" 2>/dev/null)
                best_poster="$series_poster_this"
                best_cand_name="$candidate_name"
            fi
            (( j++ ))
        done

        # High-confidence match in this (most popular) show — skip lower-popularity candidates
        (( best_score > 80 )) && break
        (( i++ ))
    done

    # --- Pass 2: alternate/translated episode titles (only when pass 1 found no match) ---
    # Fetches TMDB episode translations (e.g. UK "Air Crash Investigation" titles differ from
    # Canadian "Mayday" titles stored as the primary TMDB title).  One extra API call per
    # episode in the season; only triggered on NO_MATCH so normal runs are unaffected.
    if [[ -z "$best_ep_num" ]]; then
        local pi=0
        while [[ $pi -lt ${#sorted_indices[@]} ]]; do
            local cand_id cand_name
            cand_id=$(echo "$resp"   | jq -r ".results[${sorted_indices[$pi]}].id   // empty" 2>/dev/null)
            cand_name=$(echo "$resp" | jq -r ".results[${sorted_indices[$pi]}].name // empty" 2>/dev/null)
            [[ -z "$cand_id" ]] && (( pi++ )) && continue

            local s_url="https://api.themoviedb.org/3/tv/${cand_id}/season/${season}?api_key=${TMDB_API_KEY}&language=en-US"
            local s_resp
            s_resp=$(http_get "$s_url") || { (( pi++ )) || true; continue; }

            local ep_cnt
            ep_cnt=$(echo "$s_resp" | jq -r '.episodes | length' 2>/dev/null)
            [[ -z "$ep_cnt" || "$ep_cnt" -eq 0 ]] && { (( pi++ )) || true; continue; }

            local s_poster
            s_poster=$(echo "$resp" | jq -r ".results[${sorted_indices[$pi]}].poster_path // empty" 2>/dev/null)

            local pj=0
            while [[ $pj -lt $ep_cnt ]]; do
                local ep_n ep_rt
                ep_n=$(echo "$s_resp"  | jq -r ".episodes[$pj].episode_number // empty" 2>/dev/null)
                ep_rt=$(echo "$s_resp" | jq -r ".episodes[$pj].runtime        // 0"     2>/dev/null)
                ep_rt="${ep_rt:-0}"

                local t_url="https://api.themoviedb.org/3/tv/${cand_id}/season/${season}/episode/${ep_n}/translations?api_key=${TMDB_API_KEY}"
                local t_resp
                t_resp=$(http_get "$t_url") || { (( pj++ )) || true; continue; }

                # Score against all English alternate titles from translations
                local at_score=0 aname
                while IFS= read -r aname; do
                    [[ -z "$aname" ]] && continue
                    local _as
                    _as=$(_title_word_score "$title_hint" "$aname")
                    (( _as > at_score )) && at_score=$_as
                    if [[ -n "$hint_short" ]]; then
                        _as=$(_title_word_score "$hint_short" "$aname")
                        (( _as > at_score )) && at_score=$_as
                    fi
                done < <(echo "$t_resp" | jq -r '[.translations[] | select(.iso_639_1 == "en") | .data.name // empty] | .[]' 2>/dev/null)

                local combined=$at_score
                if [[ "${duration_secs:-0}" -gt 0 && "${ep_rt:-0}" -gt 0 ]]; then
                    local _sm=$(( duration_secs / 60 ))
                    local _df=$(( _sm - ep_rt ))
                    [[ $_df -lt 0 ]] && _df=$(( -_df ))
                    local ds
                    if   (( _df <= 2  )); then ds=100
                    elif (( _df <= 5  )); then ds=80
                    elif (( _df <= 10 )); then ds=50
                    elif (( _df <= 20 )); then ds=20
                    else                       ds=0
                    fi
                    combined=$(( at_score * 60 / 100 + ds * 40 / 100 ))
                fi

                if (( combined > best_score )); then
                    best_score=$combined
                    best_ep_name=$(echo "$s_resp" | jq -r ".episodes[$pj].name        // empty" 2>/dev/null)
                    best_ep_num="$ep_n"
                    best_ep_air_date=$(echo "$s_resp" | jq -r ".episodes[$pj].air_date   // empty" 2>/dev/null)
                    best_ep_desc=$(echo "$s_resp"     | jq -r ".episodes[$pj].overview   // empty" 2>/dev/null)
                    best_ep_still=$(echo "$s_resp"    | jq -r ".episodes[$pj].still_path // empty" 2>/dev/null)
                    best_poster="$s_poster"
                    best_cand_name="$cand_name"
                fi
                (( pj++ ))
            done

            (( best_score > 80 )) && break
            (( pi++ ))
        done
    fi

    # --- Pass 3: cross-season fallback (only when Pass 1+2 found nothing) ---
    # Handles shows (e.g. ACI/Mayday) where the file's season tag (Russian broadcast order)
    # differs from TMDB's season numbering (e.g. Russian S02 file may be TMDB S15E10).
    # Iterates ALL show candidates (not just the most popular) to handle spin-off ordering.
    if [[ -z "$best_ep_num" ]]; then
        local p3_ci=0
        while [[ $p3_ci -lt ${#sorted_indices[@]} && -z "$best_ep_num" ]]; do
        local p3_cand_id p3_cand_name p3_cand_poster
        p3_cand_id=$(echo "$resp"   | jq -r ".results[${sorted_indices[$p3_ci]}].id   // empty" 2>/dev/null)
        p3_cand_name=$(echo "$resp" | jq -r ".results[${sorted_indices[$p3_ci]}].name // empty" 2>/dev/null)
        p3_cand_poster=$(echo "$resp" | jq -r ".results[${sorted_indices[$p3_ci]}].poster_path // empty" 2>/dev/null)
        if [[ -n "$p3_cand_id" ]]; then
            local p3_show_resp p3_total_seasons
            p3_show_resp=$(http_get "https://api.themoviedb.org/3/tv/${p3_cand_id}?api_key=${TMDB_API_KEY}&language=en-US") || true
            p3_total_seasons=$(echo "$p3_show_resp" | jq -r '.number_of_seasons // 0' 2>/dev/null)
            p3_total_seasons="${p3_total_seasons:-0}"
            local p3_s=1
            while [[ $p3_s -le $p3_total_seasons ]]; do
                if [[ "$p3_s" -ne "$season" ]]; then
                    local p3_sr
                    p3_sr=$(http_get "https://api.themoviedb.org/3/tv/${p3_cand_id}/season/${p3_s}?api_key=${TMDB_API_KEY}&language=en-US") || { (( p3_s++ )) || true; continue; }
                    local p3_ec
                    p3_ec=$(echo "$p3_sr" | jq -r '.episodes | length' 2>/dev/null)
                    [[ -z "$p3_ec" || "$p3_ec" -eq 0 ]] && { (( p3_s++ )) || true; continue; }
                    local p3_j=0
                    while [[ $p3_j -lt $p3_ec ]]; do
                        local p3_en p3_enum p3_ert
                        p3_en=$(echo "$p3_sr"   | jq -r ".episodes[$p3_j].name           // empty" 2>/dev/null)
                        p3_enum=$(echo "$p3_sr" | jq -r ".episodes[$p3_j].episode_number // empty" 2>/dev/null)
                        p3_ert=$(echo "$p3_sr"  | jq -r ".episodes[$p3_j].runtime        // 0"     2>/dev/null)
                        p3_ert="${p3_ert:-0}"
                        local p3_sc
                        p3_sc=$(_title_word_score "$title_hint" "$p3_en")
                        if [[ -n "$hint_short" ]]; then
                            local _p3ts2
                            _p3ts2=$(_title_word_score "$hint_short" "$p3_en")
                            (( _p3ts2 > p3_sc )) && p3_sc=$_p3ts2
                        fi
                        local p3_combined=$p3_sc
                        if [[ "${duration_secs:-0}" -gt 0 && "${p3_ert:-0}" -gt 0 ]]; then
                            local _p3sm=$(( duration_secs / 60 ))
                            local _p3df=$(( _p3sm - p3_ert ))
                            [[ $_p3df -lt 0 ]] && _p3df=$(( -_p3df ))
                            local p3_ds
                            if   (( _p3df <= 2  )); then p3_ds=100
                            elif (( _p3df <= 5  )); then p3_ds=80
                            elif (( _p3df <= 10 )); then p3_ds=50
                            elif (( _p3df <= 20 )); then p3_ds=20
                            else                         p3_ds=0
                            fi
                            p3_combined=$(( p3_sc * 60 / 100 + p3_ds * 40 / 100 ))
                        fi
                        if (( p3_combined > best_score )); then
                            best_score=$p3_combined
                            best_ep_name="$p3_en"
                            best_ep_num="$p3_enum"
                            best_ep_season=$p3_s
                            best_ep_air_date=$(echo "$p3_sr" | jq -r ".episodes[$p3_j].air_date  // empty" 2>/dev/null)
                            best_ep_desc=$(echo "$p3_sr"     | jq -r ".episodes[$p3_j].overview  // empty" 2>/dev/null)
                            best_ep_still=$(echo "$p3_sr"    | jq -r ".episodes[$p3_j].still_path // empty" 2>/dev/null)
                            best_poster="$p3_cand_poster"
                            best_cand_name="$p3_cand_name"
                        fi
                        (( best_score >= 100 )) && break
                        (( p3_j++ ))
                    done
                fi
                (( best_score > 80 )) && break
                (( p3_s++ ))
            done
        fi
        (( p3_ci++ )) || true
        done  # end candidate loop
    fi

    if [[ -n "$best_ep_num" ]]; then
        [[ -z "${VIDEO_TITLE:-}"  ]] && VIDEO_TITLE="$best_ep_name"
        [[ -z "${VIDEO_YEAR:-}"   ]] && VIDEO_YEAR="${best_ep_air_date:0:4}"
        [[ -z "${VIDEO_DESC:-}"   ]] && VIDEO_DESC="$best_ep_desc"
        [[ -z "${VIDEO_TVSHOW:-}" ]] && VIDEO_TVSHOW="$best_cand_name"
        VIDEO_SEASON="${best_ep_season:-$season}"
        VIDEO_EPISODE="$best_ep_num"
        if [[ -n "$best_poster" ]]; then
            VIDEO_POSTER_URL="https://image.tmdb.org/t/p/original${best_poster}"
        elif [[ -n "$best_ep_still" ]]; then
            VIDEO_POSTER_URL="https://image.tmdb.org/t/p/original${best_ep_still}"
        fi
        return 0
    fi
    return 1
}

# Download a poster/cover image to $dest_path.
fetch_video_poster() {
    local dest_path="$1"
    [[ -z "${VIDEO_POSTER_URL:-}" ]] && return 0
    if http_download "$dest_path" "${VIDEO_POSTER_URL}"; then
        echo "[INFO] Poster fetched: ${VIDEO_POSTER_URL}" >&2
    else
        echo "[WARN] Poster download failed (continuing without artwork): ${VIDEO_POSTER_URL}" >&2
        rm -f "$dest_path"  # remove partial download if any
    fi
    return 0
}

# Probe a video file for resolution label and best audio language.
# Sets VIDEO_RES_LABEL (SD/1K/2K/4K/8K) and VIDEO_AUDIO_LANG (ISO 639-1, e.g. en/uk).
probe_video_info() {
    local file="$1"

    # --- Resolution ---
    local vid_height=0
    if command -v ffprobe &>/dev/null; then
        vid_height="$(ffprobe -v error -select_streams v:0 \
            -show_entries stream=height -of csv=p=0 "$file" 2>/dev/null | head -1)"
        # Strip any non-digit characters (ffprobe csv can emit a trailing
        # comma / extra field, e.g. "2160," which breaks the arithmetic below
        # and silently falls through to the SD label).
        vid_height="${vid_height//[!0-9]/}"
        vid_height="${vid_height:-0}"
    fi
    if   (( vid_height >= 4320 )); then VIDEO_RES_LABEL="8K"
    elif (( vid_height >= 2160 )); then VIDEO_RES_LABEL="4K"
    elif (( vid_height >= 1080 )); then VIDEO_RES_LABEL="2K"
    elif (( vid_height >= 720  )); then VIDEO_RES_LABEL="1K"
    else                                VIDEO_RES_LABEL="SD"
    fi

    # --- Best audio language (priority: eng > ukr > first available) ---
    VIDEO_AUDIO_LANG="und"
    if command -v ffprobe &>/dev/null; then
        local probe_audio best3="" first3=""
        probe_audio="$(ffprobe -v error -select_streams a \
            -show_entries stream=index:stream_tags=language \
            -of csv=p=0 "$file" 2>/dev/null)" || probe_audio=""
        while IFS=',' read -r _ai lang; do
            [[ -z "${_ai// /}" ]] && continue
            local ll
            ll="$(tr '[:upper:]' '[:lower:]' <<< "${lang:-}")"
            [[ -z "$first3" ]] && first3="$ll"
            if   [[ "$ll" == "eng" ]]; then best3="eng"; break
            elif [[ "$ll" == "ukr" && "$best3" != "eng" ]]; then best3="ukr"
            fi
        done <<< "$probe_audio"
        [[ -z "$best3" ]] && best3="$first3"
        # Map ISO 639-2/T (3-letter) → ISO 639-1 (2-letter) for clean filenames
        case "$best3" in
            eng)          VIDEO_AUDIO_LANG="en" ;;
            ukr)          VIDEO_AUDIO_LANG="uk" ;;
            fra|fre)      VIDEO_AUDIO_LANG="fr" ;;
            deu|ger)      VIDEO_AUDIO_LANG="de" ;;
            spa)          VIDEO_AUDIO_LANG="es" ;;
            ita)          VIDEO_AUDIO_LANG="it" ;;
            jpn)          VIDEO_AUDIO_LANG="ja" ;;
            zho|chi|cmn)  VIDEO_AUDIO_LANG="zh" ;;
            kor)          VIDEO_AUDIO_LANG="ko" ;;
            por)          VIDEO_AUDIO_LANG="pt" ;;
            rus)          VIDEO_AUDIO_LANG="ru" ;;
            nld|dut)      VIDEO_AUDIO_LANG="nl" ;;
            pol)          VIDEO_AUDIO_LANG="pl" ;;
            *)            VIDEO_AUDIO_LANG="${best3:-und}" ;;
        esac
    fi
    debug_log "probe_video_info: height=${vid_height} res=${VIDEO_RES_LABEL} lang=${VIDEO_AUDIO_LANG}"
}

# Embed video metadata into an M4V/MP4 using AtomicParsley (preferred) or exiftool.
# embed_video_meta FILE [POSTER_PATH] [MODE]
#   MODE="full" (default) — all tags + cover art   (desktop)
#   MODE="portable"       — all tags + cover art, no description
#                           (Sony Walkman NWZ: description not shown)
embed_video_meta() {
    local file="$1"
    local poster_path="${2:-}"
    local mode="${3:-full}"

    local _ext="${file##*.}"
    _ext="$(tr '[:upper:]' '[:lower:]' <<< "$_ext")"

    # For video containers use an ffmpeg -c copy pass.
    # AtomicParsley --overWrite and exiftool both rewrite the container and
    # silently drop all but the first audio track — breaking Apple TV multi-track.
    # ffmpeg -map 0 -c copy preserves every stream, disposition flag, and
    # language atom we set during the remux/encode step.
    if [[ "$_ext" == "m4v" || "$_ext" == "mp4" || "$_ext" == "mov" ]] && \
       command -v ffmpeg &>/dev/null; then
        local staged
        staged="$(staging_path "$file")"

        local -a ff=(-y -i "$file")

        local _has_poster=0
        local _poster_tmp=""
        if [[ -n "$poster_path" && -f "$poster_path" ]]; then
            if [[ "$mode" == "portable" ]]; then
                # Scale cover art to fit within PORTABLE_VIDEO_WIDTH×PORTABLE_VIDEO_HEIGHT
                # with preserved aspect ratio (no crop, no black bars).
                local _pw="${PORTABLE_VIDEO_WIDTH:-320}"
                local _ph="${PORTABLE_VIDEO_HEIGHT:-240}"
                _poster_tmp=$(mktemp /tmp/poster_portable_XXXXXX.jpg)
                "${FFMPEG_BIN:-ffmpeg}" -nostdin -y -i "$poster_path" \
                    -vf "scale=${_pw}:${_ph}:force_original_aspect_ratio=decrease" \
                    -q:v 3 "$_poster_tmp" 2>/dev/null && ff+=(-i "$_poster_tmp") || ff+=(-i "$poster_path")
            else
                ff+=(-i "$poster_path")
            fi
            _has_poster=1
        fi

        # Map the primary video stream only (uppercase V excludes any existing
        # attached_pic / cover-art streams — prevents accumulating mjpeg streams
        # across repeated embed passes) plus all audio tracks.
        # Subtitle/text/data streams are deliberately excluded: the ipod/m4v muxer
        # rejects unknown codec ids ("Tag text incompatible with output codec id").
        ff+=(-map 0:V:0 -map 0:a)
        if (( _has_poster )); then
            ff+=(-map 1 -disposition:v:1 attached_pic)
        fi

        # Always copy chapters from the video input (input 0).
        # -map_chapters 0 is explicit so chapters survive even when a second
        # input (poster image) is present.
        ff+=(-map_chapters 0)

        # Detect HEVC video: apply hevc_mp4toannexb BSF + hvc1 tag so QuickTime/Apple TV
        # can play HEVC files. Without this, files get the 'hev1' codec tag (in-band params)
        # which Apple's AVFoundation rejects. The BSF converts in-stream parameter sets to
        # the hvcC container box format, producing a valid 'hvc1' stream.
        # This is done here (not in convert.sh) so the conversion happens once, in the
        # final pass — avoiding a double hev1↔hvc1 round-trip that corrupts the bitstream.
        local _src_vcodec_embed=""
        if command -v ffprobe &>/dev/null; then
            _src_vcodec_embed=$(ffprobe -v error -select_streams v:0 \
                -show_entries stream=codec_name -of csv=p=0 "$file" 2>/dev/null | head -1 || true)
        fi
        if [[ "$_src_vcodec_embed" == "hevc" ]]; then
            # -bsf:v:0 and -tag:v:0 scope to the first video stream only, so the
            # BSF is NOT applied to any poster/attached-pic stream (v:1), which
            # would cause "Error initializing bitstream filter" on a JPEG stream.
            ff+=(-c:v copy -bsf:v:0 hevc_mp4toannexb -tag:v:0 hvc1 -c:a copy)
        else
            ff+=(-c copy)
        fi

        # Stamp the video stream with the primary language from the configured list.
        # Without this, sources whose video stream is tagged 'und' produce 'und' output.
        local _vid_primary_lang
        if [[ "$mode" == "portable" ]]; then
            _vid_primary_lang=$(echo "${PORTABLE_VIDEO_AUDIO_LANGS:-eng}" | awk '{print $1}')
        else
            _vid_primary_lang=$(echo "${DESKTOP_VIDEO_AUDIO_LANGS:-eng}" | awk '{print $1}')
        fi
        ff+=(-metadata:s:v:0 "language=${_vid_primary_lang}")

        # Nuke global/container-level metadata only — rip files contain garbage tags
        # (encoder names, torrent comments, wrong titles). We rebuild those from TMDB below.
        # -map_metadata:g -1 leaves stream-level tags (language=, title= per audio track)
        # intact so Apple TV and VLC can identify tracks correctly.
        # NOTE: the original MKV remux may preserve a stale QuickTime moov/udta/©nam atom
        # that exiftool reads. ffprobe and Apple apps (iTunes/TV) read from the ilst layer
        # which is correctly set below — so practical metadata display is unaffected.
        ff+=(-map_metadata:g -1)

        # Re-stamp stream-level audio language + title tags so Apple TV picker shows
        # language names. Belt-and-suspenders: even if stream tags survived the copy,
        # explicitly setting them here ensures they're always correct.
        if command -v ffprobe &>/dev/null; then
            local _a_probe _a_i=0 _a_lang _a_title
            _a_probe=$(ffprobe -v error -select_streams a \
                -show_entries stream_tags=language -of csv=p=0 "$file" 2>/dev/null) || _a_probe=""
            while IFS= read -r _a_lang; do
                _a_lang="$(tr '[:upper:]' '[:lower:]' <<< "${_a_lang:-}")"
                [[ -z "$_a_lang" ]] && (( _a_i++ )) || true && continue
                _a_title="$(_lang_to_title "$_a_lang")"
                ff+=("-metadata:s:a:${_a_i}" "language=${_a_lang}")
                ff+=("-metadata:s:a:${_a_i}" "title=${_a_title}")
                (( _a_i++ )) || true
            done <<< "$_a_probe"
        fi

        # iTunes / QuickTime metadata atoms
        [[ -n "${VIDEO_TITLE:-}"  ]] && ff+=(-metadata "title=${VIDEO_TITLE}")
        [[ -n "${VIDEO_YEAR:-}"   ]] && ff+=(-metadata "date=${VIDEO_YEAR}")
        [[ -n "${VIDEO_GENRE:-}"  ]] && ff+=(-metadata "genre=${VIDEO_GENRE}")
        if [[ "$mode" != "portable" && -n "${VIDEO_DESC:-}" ]]; then
            ff+=(-metadata "description=${VIDEO_DESC}")
        fi
        [[ -n "${VIDEO_TVSHOW:-}"  ]] && ff+=(-metadata "show=${VIDEO_TVSHOW}")
        [[ -n "${VIDEO_SEASON:-}"  ]] && ff+=(-metadata "season_number=${VIDEO_SEASON}")
        [[ -n "${VIDEO_EPISODE:-}" ]] && ff+=(-metadata "episode_id=${VIDEO_EPISODE}")

        # -f mp4 forces the mp4 muxer; .m4v extension would pick 'ipod' which rejects HEVC
        ff+=(-movflags +faststart -f mp4 "$staged")

        _ffmpeg "${ff[@]}"
        [[ -n "$_poster_tmp" ]] && rm -f "$_poster_tmp"
        commit_staged "$staged" "$file"
        return 0
    fi

    # Fallback for non-video files (audio, etc.) — use AtomicParsley then exiftool
    if command -v AtomicParsley &>/dev/null; then
        local args=("$file" --overWrite)
        [[ -n "${VIDEO_TITLE:-}"   ]] && args+=(--title        "${VIDEO_TITLE}")
        [[ -n "${VIDEO_YEAR:-}"    ]] && args+=(--year         "${VIDEO_YEAR}")
        [[ -n "${VIDEO_GENRE:-}"   ]] && args+=(--genre        "${VIDEO_GENRE}")
        [[ "$mode" != "portable" && -n "${VIDEO_DESC:-}" ]] && args+=(--description "${VIDEO_DESC}")
        [[ -n "${VIDEO_TVSHOW:-}"  ]] && args+=(--TVShowName   "${VIDEO_TVSHOW}")
        [[ -n "${VIDEO_SEASON:-}"  ]] && args+=(--TVSeasonNum  "${VIDEO_SEASON}")
        [[ -n "${VIDEO_EPISODE:-}" ]] && args+=(--TVEpisodeNum "${VIDEO_EPISODE}")
        [[ -n "$poster_path" && -f "$poster_path" ]] && args+=(--artwork "$poster_path")
        AtomicParsley "${args[@]}"
    elif command -v exiftool &>/dev/null; then
        local et_args=(-overwrite_original)
        [[ -n "${VIDEO_TITLE:-}"   ]] && et_args+=("-QuickTime:Title=${VIDEO_TITLE}")
        [[ -n "${VIDEO_YEAR:-}"    ]] && et_args+=("-QuickTime:Year=${VIDEO_YEAR}")
        [[ -n "${VIDEO_GENRE:-}"   ]] && et_args+=("-QuickTime:Genre=${VIDEO_GENRE}")
        [[ "$mode" != "portable" && -n "${VIDEO_DESC:-}" ]] && et_args+=("-QuickTime:Description=${VIDEO_DESC}")
        [[ -n "${VIDEO_TVSHOW:-}"  ]] && et_args+=("-TVShow=${VIDEO_TVSHOW}")
        [[ -n "${VIDEO_SEASON:-}"  ]] && et_args+=("-TVSeason=${VIDEO_SEASON}")
        [[ -n "${VIDEO_EPISODE:-}" ]] && et_args+=("-TVEpisode=${VIDEO_EPISODE}")
        [[ -n "$poster_path" && -f "$poster_path" ]] && et_args+=("-CoverArt<=$poster_path")
        exiftool "${et_args[@]}" "$file" 2>/dev/null
    else
        echo "[WARN] No metadata tool found; skipping video metadata for: $file" >&2
    fi
}

# ---------------------------------------------------------------------------
# Photo metadata helpers
# ---------------------------------------------------------------------------

# Determine the capture date of a photo or camera video.
# Tries every available source in order of reliability:
#   1. Embedded metadata — EXIF, QuickTime, XMP, IPTC, GPS date stamp
#      (single exiftool pass, tags in priority order)
#   2. Filesystem dates — FileCreateDate (preserved on some copies), FileModifyDate
#   3. Filename patterns — YYYYMMDD, YYYY-MM-DD, YYYYMMDD_HHMMSS, etc.
#   4. macOS filesystem birth time (stat -f %SB) — reflects when file first appeared
#      on this volume; a last resort, better than "unknown"
# Outputs: DATE_YEAR, DATE_MONTH, DATE_DAY (or "unknown" + return 1 if all fail)
read_photo_date() {
    local file="$1"
    local dt="" _src=""

    # --- Pass 1: all embedded capture-date tags in one exiftool call ----------------
    # Tags listed in descending reliability order.  exiftool outputs values in the
    # order requested and skips missing tags, so the first valid line wins.
    local _raw
    _raw=$(exiftool -d "%Y:%m:%d" \
        -DateTimeOriginal \
        -EXIF:DateTimeDigitized \
        -QuickTime:CreateDate \
        -QuickTime:MediaCreateDate \
        -QuickTime:TrackCreateDate \
        -XMP:DateCreated \
        -XMP:CreateDate \
        -IPTC:DateCreated \
        -GPS:GPSDateStamp \
        -s3 "$file" 2>/dev/null)

    local _ln _d
    while IFS= read -r _ln; do
        [[ -z "$_ln" ]] && continue
        _d="${_ln%% *}"   # strip time and timezone — keep YYYY:MM:DD only
        if [[ "$_d" =~ ^[12][0-9]{3}:[01][0-9]:[0-3][0-9]$ ]]; then
            dt="$_d"; _src="embedded metadata"; break
        fi
    done <<< "$_raw"

    # --- Pass 2: filesystem dates ---------------------------------------------------
    if [[ -z "$dt" ]]; then
        local _fs
        _fs=$(exiftool -d "%Y:%m:%d" -FileCreateDate -FileModifyDate -s3 "$file" 2>/dev/null)
        while IFS= read -r _ln; do
            [[ -z "$_ln" ]] && continue
            _d="${_ln%% *}"
            if [[ "$_d" =~ ^[12][0-9]{3}:[01][0-9]:[0-3][0-9]$ ]]; then
                dt="$_d"; _src="filesystem date"; break
            fi
        done <<< "$_fs"
    fi

    # --- Pass 3: filename pattern matching ------------------------------------------
    # Handles: YYYYMMDD_HHMMSS (Android), YYYY-MM-DD, YYYY_MM_DD, YYYYMMDD
    if [[ -z "$dt" ]]; then
        local bn
        bn="$(basename "$file")"
        # Require year in [1900-2099] range, month [01-12], day [01-31]
        if   [[ "$bn" =~ ([12][0-9]{3})[._-]([01][0-9])[._-]([0-3][0-9]) ]]; then
            dt="${BASH_REMATCH[1]}:${BASH_REMATCH[2]}:${BASH_REMATCH[3]}"; _src="filename (separated)"
        elif [[ "$bn" =~ ([12][0-9]{3})([01][0-9])([0-3][0-9]) ]]; then
            dt="${BASH_REMATCH[1]}:${BASH_REMATCH[2]}:${BASH_REMATCH[3]}"; _src="filename (compact)"
        fi
        [[ -n "$dt" ]] && echo "[INFO] Date from ${_src}: $(basename "$file") → $dt" >&2
    fi

    # --- Pass 4: macOS filesystem birth time (stat) ---------------------------------
    if [[ -z "$dt" ]]; then
        local _birth
        _birth=$(stat -f "%SB" -t "%Y:%m:%d" "$file" 2>/dev/null || true)
        if [[ "$_birth" =~ ^[12][0-9]{3}:[01][0-9]:[0-3][0-9]$ ]]; then
            dt="$_birth"; _src="filesystem birth time"
            echo "[INFO] Date from ${_src}: $(basename "$file") → $dt" >&2
        fi
    fi

    if [[ -z "$dt" ]]; then
        echo "[WARN] Cannot determine capture date for: $file" >&2
        DATE_YEAR="unknown"; DATE_MONTH="unknown"; DATE_DAY="unknown"
        return 1
    fi

    debug_log "read_photo_date: $(basename "$file") → $dt (source: ${_src})"
    DATE_YEAR="${dt:0:4}"
    DATE_MONTH="${dt:5:2}"
    DATE_DAY="${dt:8:2}"
}
