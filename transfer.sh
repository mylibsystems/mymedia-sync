#!/usr/bin/env bash
# transfer.sh — file mover / copier, replicates source directory structure
#
# Usage:
#   ./transfer.sh <sourceFile> <destDir> <mediaLabel> [export]
#
# If 4th arg is "export", the file is COPIED; otherwise MOVED.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.sh"

SOURCE_FILE="$1"
DEST_DIR="$2"
MEDIA_LABEL="${3:-misc}"
MODE="${4:-move}"     # "export" = copy; anything else = move

if [[ ! -f "$SOURCE_FILE" ]]; then
    echo "[ERROR] Source file not found: $SOURCE_FILE" >&2
    exit 1
fi

# Replicate the file's directory structure relative to the nearest common ancestor.
# We use the file's own directory basename as the relative path component.
REL_DIR="$(dirname "$SOURCE_FILE" | xargs basename)"
FINAL_DIR="${DEST_DIR}/${REL_DIR}"
mkdir -p "$FINAL_DIR"

DEST_FILE="${FINAL_DIR}/$(basename "$SOURCE_FILE")"

if [[ -e "$DEST_FILE" ]]; then
    echo "[SKIP] Already exists: $DEST_FILE" >&2
    exit 0
fi

if [[ "$MODE" == "export" ]]; then
    cp -n "$SOURCE_FILE" "$DEST_FILE"
    echo "[OK] Copied: $SOURCE_FILE → $DEST_FILE" >&2
else
    mv -n "$SOURCE_FILE" "$DEST_FILE"
    echo "[OK] Moved: $SOURCE_FILE → $DEST_FILE" >&2
fi
