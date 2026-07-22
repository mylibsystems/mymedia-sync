#!/usr/bin/env bash
# playlist.sh — generate M3U8 (UTF-8) playlists for the music library.
# Sourced by sync.sh; never executed directly.
#
# Produces, in BOTH the desktop (FLAC) and portable (m4a) trees:
#   <artist>/<album>/playlist.m3u8   — tracks of one album (relative filenames)
#   <artist>/playlist.m3u8           — every track of an artist (relative album/track paths)
#
# M3U8 is UTF-8 so Cyrillic / accented track names render correctly. Track order
# follows the zero-padded "DD.TT - Title" filename prefix via a plain lexical sort.

# Build one M3U entry (two lines) for an audio file:
#   #EXTINF:<seconds>,<artist> - <title>
#   <relpath>
# Reads duration + tags via ffprobe; falls back to the filename when tags are absent.
_m3u_entry() {
    local file="$1" relpath="$2"
    local dur="" artist="" title="" disp

    if command -v ffprobe &>/dev/null; then
        local meta
        meta=$(ffprobe -v error -show_entries format=duration:format_tags \
            -of json "$file" 2>/dev/null)
        if [[ -n "$meta" ]]; then
            # Tag-key case differs by container (FLAC=UPPER Vorbis comments, m4a=lower),
            # so lower-case all tag keys before lookup.
            dur=$(printf '%s' "$meta"    | jq -r '(.format.duration // "0") | tonumber | round' 2>/dev/null)
            artist=$(printf '%s' "$meta" | jq -r '(.format.tags // {}) | with_entries(.key |= ascii_downcase) | .artist // empty' 2>/dev/null)
            title=$(printf '%s' "$meta"  | jq -r '(.format.tags // {}) | with_entries(.key |= ascii_downcase) | .title  // empty' 2>/dev/null)
        fi
    fi
    [[ -z "$dur" || "$dur" == "null" ]] && dur=0

    if   [[ -n "$artist" && -n "$title" ]]; then disp="${artist} - ${title}"
    elif [[ -n "$title"                 ]]; then disp="$title"
    else disp="$(basename "${file%.*}")"
    fi

    printf '#EXTINF:%s,%s\n%s\n' "$dur" "$disp" "$relpath"
}

# True (0) when an album playlist is missing or older than any track in the folder.
_album_playlist_stale() {
    local album_dir="$1" ext="$2"
    local out="${album_dir}/${PLAYLIST_FILENAME:-playlist.m3u8}"
    [[ -f "$out" ]] || return 0
    local newer
    newer=$(find "$album_dir" -maxdepth 1 -type f -iname "*.${ext}" -newer "$out" -print -quit 2>/dev/null)
    [[ -n "$newer" ]]
}

# Generate (or refresh) the per-album playlist. Echoes 1 when written, 0 otherwise.
generate_album_playlist() {
    local album_dir="$1" ext="$2"
    local out="${album_dir}/${PLAYLIST_FILENAME:-playlist.m3u8}"

    _album_playlist_stale "$album_dir" "$ext" || { printf '0'; return 0; }

    # Collect track files into an array via a TEMP FILE (real `< file` redirect),
    # NOT process substitution `< <(...)`. Apple's system bash 3.2.57 corrupts its
    # heap ("malloc: pointer being freed was not allocated" → Abort trap: 6) when
    # process substitution is used inside functions called in a loop, so this whole
    # file avoids `<(...)` entirely.
    local files=() f listf
    listf="$(mktemp)"
    find "$album_dir" -maxdepth 1 -type f -iname "*.${ext}" | sort > "$listf"
    while IFS= read -r f; do
        [[ -n "$f" ]] && files+=("$f")
    done < "$listf"
    rm -f "$listf"

    [[ ${#files[@]} -eq 0 ]] && { printf '0'; return 0; }

    local tmp; tmp="$(mktemp)"
    printf '#EXTM3U\n' > "$tmp"
    for f in ${files[@]+"${files[@]}"}; do
        _m3u_entry "$f" "$(basename "$f")" >> "$tmp"
    done

    # -f: never prompt. A pre-existing non-writable playlist.m3u8 (e.g. mode 000)
    # would otherwise trigger mv's interactive "override ...? (y/n)" prompt and
    # hang the (non-interactive) pipeline.
    mv -f "$tmp" "$out"; printf '1'
}

# True (0) when an artist playlist is missing or older than any track / album dir
# beneath it. Mirrors _album_playlist_stale but recurses into the album folders so
# a re-encoded track, or an added/removed album, marks the artist playlist stale.
# Without this, generate_artist_playlist re-ffprobes EVERY track of EVERY artist on
# every run (≈8.6k probes/tier, single-threaded) — the Stage 3b slowdown.
_artist_playlist_stale() {
    local artist_dir="$1" ext="$2"
    local out="${artist_dir}/${PLAYLIST_FILENAME:-playlist.m3u8}"
    [[ -f "$out" ]] || return 0
    local newer
    newer=$(find "$artist_dir" -mindepth 1 \
                \( -type d -o \( -type f -iname "*.${ext}" \) \) \
                -newer "$out" -print -quit 2>/dev/null)
    [[ -n "$newer" ]]
}

# Generate (or refresh) the per-artist playlist spanning all of the artist's albums.
# Relative paths are "<album>/<track>" so the file is portable within the artist folder.
# Echoes 1 when written, 0 otherwise.
generate_artist_playlist() {
    local artist_dir="$1" ext="$2"
    local out="${artist_dir}/${PLAYLIST_FILENAME:-playlist.m3u8}"

    _artist_playlist_stale "$artist_dir" "$ext" || { printf '0'; return 0; }

    # Collect album dirs first via a temp file (no process substitution; see
    # generate_album_playlist for the bash 3.2.57 reason).
    local albums=() album_dir listf
    listf="$(mktemp)"
    find "$artist_dir" -mindepth 1 -maxdepth 1 -type d | sort > "$listf"
    while IFS= read -r album_dir; do
        [[ -n "$album_dir" ]] && albums+=("$album_dir")
    done < "$listf"
    rm -f "$listf"

    local tmp; tmp="$(mktemp)"
    printf '#EXTM3U\n' > "$tmp"
    local found=0 f rel
    local files=()
    for album_dir in ${albums[@]+"${albums[@]}"}; do
        [[ -d "$album_dir" ]] || continue
        # Collect this album's tracks into an array via a temp file.
        files=()
        listf="$(mktemp)"
        find "$album_dir" -maxdepth 1 -type f -iname "*.${ext}" | sort > "$listf"
        while IFS= read -r f; do
            [[ -n "$f" ]] && files+=("$f")
        done < "$listf"
        rm -f "$listf"
        for f in ${files[@]+"${files[@]}"}; do
            found=1
            rel="${f#"${artist_dir}"/}"
            _m3u_entry "$f" "$rel" >> "$tmp"
        done
    done

    if (( found )); then mv -f "$tmp" "$out"; printf '1'; else rm -f "$tmp"; printf '0'; fi
}

# Walk a music root, generating per-album and per-artist playlists.
# Usage: generate_music_playlists <music_root> <audio_ext>
generate_music_playlists() {
    local music_root="$1" ext="$2"
    [[ -d "$music_root" ]] || { echo "[WARN] Playlist: music root not found: $music_root" >&2; return 0; }

    # Collect artist dirs first via a temp file (no process substitution; see
    # generate_album_playlist for the bash 3.2.57 reason).
    local artists=() artist_dir listf
    listf="$(mktemp)"
    find "$music_root" -mindepth 1 -maxdepth 1 -type d | sort > "$listf"
    while IFS= read -r artist_dir; do
        [[ -n "$artist_dir" ]] && artists+=("$artist_dir")
    done < "$listf"
    rm -f "$listf"

    local artist_count=0 album_count=0 album_dir
    local albums=()
    for artist_dir in ${artists[@]+"${artists[@]}"}; do
        [[ -d "$artist_dir" ]] || continue
        # Collect this artist's album dirs into an array via a temp file.
        albums=()
        listf="$(mktemp)"
        find "$artist_dir" -mindepth 1 -maxdepth 1 -type d | sort > "$listf"
        while IFS= read -r album_dir; do
            [[ -n "$album_dir" ]] && albums+=("$album_dir")
        done < "$listf"
        rm -f "$listf"
        for album_dir in ${albums[@]+"${albums[@]}"}; do
            [[ -d "$album_dir" ]] || continue
            [[ "$(generate_album_playlist "$album_dir" "$ext")" == "1" ]] && (( album_count++ )) || true
        done
        [[ "$(generate_artist_playlist "$artist_dir" "$ext")" == "1" ]] && (( artist_count++ )) || true
    done

    echo "[INFO] Playlists (${ext}): ${album_count} album, ${artist_count} artist written under ${music_root}"
}
