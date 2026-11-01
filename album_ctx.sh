#!/usr/bin/env bash
# album_ctx.sh — build the per-album context for a music source folder.
#
# This is the album-context step of import.sh (lines "Scanning album directories" ..
# "ensure_album_ctx_fallback"), run on its own so the Python app can show per-file
# progress for the tracks afterwards. Same functions, same arguments, same order.
#
# Usage: ./album_ctx.sh <ctxDir> <sourceDir>

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.sh"
source "${SCRIPT_DIR}/metadata.sh"

ALBUM_CTX_DIR="$1"
SOURCE_DIR="$2"
mkdir -p "$ALBUM_CTX_DIR"

echo "[INFO] Scanning album directories under: $SOURCE_DIR" >&2
_album_dirs_file=$(mktemp /tmp/album_dirs_XXXXXX)
find "$SOURCE_DIR" -maxdepth 8 -type f \
    \( -iname '*.flac' -o -iname '*.m4a' -o -iname '*.mp3' \
       -o -iname '*.aac' -o -iname '*.wav' -o -iname '*.ogg' \) \
    -print | while IFS= read -r f; do dirname "$f"; done \
    | sort -u > "$_album_dirs_file"

while IFS= read -r _album_dir; do
    [[ -z "$_album_dir" ]] && continue
    echo "[START] Album context: $(basename "$_album_dir")" >&2
    if ! fetch_album_meta_for_folder "$_album_dir" "$(basename "$_album_dir")" "$ALBUM_CTX_DIR"; then
        log_warn "Album context unavailable, using embedded tags: $_album_dir"
    fi
    ensure_album_ctx_fallback "$_album_dir" "$ALBUM_CTX_DIR"
done < "$_album_dirs_file"
rm -f "$_album_dirs_file"
