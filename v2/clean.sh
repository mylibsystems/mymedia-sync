#!/usr/bin/env bash
# clean.sh — RAW cleanup utility
#
# Scans the PHOTOS source directory and removes:
#   - paired JPEG files when a RAW counterpart (.RW2/.rw2) exists
#   - TIFF intermediary artifacts (.TIFF/.tiff)
#
# Usage:
#   ./clean.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.sh"

if [[ ! -d "$PHOTOS_SOURCE" ]]; then
    echo "[WARN] Photos source not found: $PHOTOS_SOURCE" >&2
    exit 0
fi

echo "[INFO] Starting RAW cleanup in: $PHOTOS_SOURCE"

removed=0

# Remove paired JPEGs when .RW2 raw exists
while IFS= read -r -d '' raw_file; do
    base="${raw_file%.*}"
    for jpeg_ext in jpg JPG jpeg JPEG; do
        paired="${base}.${jpeg_ext}"
        if [[ -f "$paired" ]]; then
            echo "[CLEAN] Removing paired JPEG (has RAW): $paired"
            rm -f "$paired"
            (( removed++ ))
        fi
    done
done < <(find "$PHOTOS_SOURCE" -type f \( -name "*.RW2" -o -name "*.rw2" \) -print0)

# Remove TIFF intermediary files
while IFS= read -r -d '' tiff_file; do
    echo "[CLEAN] Removing TIFF artifact: $tiff_file"
    rm -f "$tiff_file"
    (( removed++ ))
done < <(find "$PHOTOS_SOURCE" -type f \( -name "*.TIFF" -o -name "*.tiff" \) -print0)

echo "[INFO] RAW cleanup complete. Files removed: $removed"
