#!/usr/bin/env bash
# backup.sh — backup driver: walk source library and transfer each file
#
# Usage:
#   ./backup.sh <sourceDir> <destDir> <mediaLabel> [export]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.sh"

SOURCE_DIR="$1"
DEST_DIR="$2"
MEDIA_LABEL="${3:-misc}"
MODE="${4:-move}"

if [[ ! -d "$SOURCE_DIR" ]]; then
    echo "[ERROR] Source directory not found: $SOURCE_DIR" >&2
    exit 1
fi

echo "[INFO] Backup started: $SOURCE_DIR → $DEST_DIR  mode=$MODE" >> "${BACKUP_LOG}"

job_count=0
declare -a pids=()

while IFS= read -r -d '' file; do
    [[ "$(basename "$file")" == .* ]] && continue
    [[ "$file" == *"${STAGING_SUFFIX}"* ]] && continue

    "${SCRIPT_DIR}/transfer.sh" "$file" "$DEST_DIR" "$MEDIA_LABEL" "$MODE" \
        >> "${BACKUP_LOG}" 2>&1 &
    pids+=($!)
    (( job_count++ ))

    if (( job_count >= MAX_PARALLEL_JOBS )); then
        wait "${pids[0]}"
        pids=("${pids[@]:1}")
        (( job_count-- ))
    fi
done < <(find "$SOURCE_DIR" -maxdepth 8 -type f -print0)

for pid in "${pids[@]:+"${pids[@]}"}" ; do
    wait "$pid" || true
done

echo "[INFO] Backup complete: $SOURCE_DIR" >> "${BACKUP_LOG}"
