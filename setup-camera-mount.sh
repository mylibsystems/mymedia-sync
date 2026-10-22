#!/usr/bin/env bash
# setup-camera-mount.sh — make the router's root-level CAMERA folder visible at
# /mnt/router-smb/CAMERA together with the other router mappings.
#
# The router exports UNSORTED / LIBRARY.* / logs over SMB but not a CAMERA folder at
# the disk root, so it is bound from the NFS export of the SAME disk
# (/mnt/router-nfs/CAMERA). Idempotent. Run once:
#
#   sudo ./setup-camera-mount.sh            # mount now + make it permanent
#   ./setup-camera-mount.sh --dry-run       # show what would be done (no root needed)
#
# What it changes (all reversible):
#   1. bind-mounts /mnt/router-nfs/CAMERA -> /mnt/router-smb/CAMERA now
#   2. adds one block to /usr/local/sbin/mount-router-smb.sh so router-smb.service
#      re-creates the bind on every boot / restart (a backup is kept next to it)
#   3. orders router-smb.service after router-nfs.service (systemd drop-in)

set -euo pipefail

NFS="${ROUTER_NFS_MOUNT:-/mnt/router-nfs}"
MP="${ROUTER_SMB_MOUNT:-/mnt/router-smb}"
NAME="CAMERA"
MOUNT_SCRIPT="/usr/local/sbin/mount-router-smb.sh"
DROPIN_DIR="/etc/systemd/system/router-smb.service.d"
MARKER="# mymedia-sync: bind CAMERA"

DRY=0; [[ "${1:-}" == "--dry-run" ]] && DRY=1
say() { printf '%s\n' "$*"; }
run() { if (( DRY )); then say "  [dry-run] $*"; else "$@"; fi; }

if (( ! DRY && EUID != 0 )); then
    say "Run with sudo:  sudo $0   (or use --dry-run to preview)"; exit 1
fi

mountpoint -q "$NFS"      || { say "[ERROR] $NFS is not mounted (start router-nfs.service first)"; exit 1; }
[[ -d "$NFS/$NAME" ]]     || { say "[ERROR] $NFS/$NAME does not exist on the router disk"; exit 1; }
[[ -d "$MP" ]]            || { say "[ERROR] $MP does not exist"; exit 1; }

# 1) bind now
say "1) bind $NFS/$NAME -> $MP/$NAME"
if mountpoint -q "$MP/$NAME"; then
    say "   already mounted"
else
    run mkdir -p "$MP/$NAME"
    run mount --bind "$NFS/$NAME" "$MP/$NAME"
fi

# 2) permanent: extend the existing boot-time mount script
say "2) make it permanent in $MOUNT_SCRIPT"
if [[ ! -f "$MOUNT_SCRIPT" ]]; then
    say "   [WARN] $MOUNT_SCRIPT not found - skipping (the bind lasts until reboot)"
elif grep -qF "$MARKER" "$MOUNT_SCRIPT"; then
    say "   already patched"
else
    run cp -a "$MOUNT_SCRIPT" "${MOUNT_SCRIPT}.bak-camera"
    if (( DRY )); then
        say "  [dry-run] insert the CAMERA bind block before the final result check"
    else
        block=$(cat <<EOF
$MARKER
# CAMERA lives at the router disk root and is not exported over SMB: bind it from the NFS mount.
if mountpoint -q /mnt/router-nfs && [ -d /mnt/router-nfs/CAMERA ] && ! mountpoint -q "\$MP/CAMERA"; then
    mkdir -p "\$MP/CAMERA"
    mount --bind /mnt/router-nfs/CAMERA "\$MP/CAMERA" && rc=0
fi
EOF
)
        tmp="$(mktemp)"
        awk -v blk="$block" '/^\[ \$rc -eq 0 \]/ && !done { print blk; done=1 } { print }' "$MOUNT_SCRIPT" > "$tmp"
        grep -qF "$MARKER" "$tmp" || { say "   [ERROR] could not find the insertion point; left the script unchanged"; rm -f "$tmp"; exit 1; }
        bash -n "$tmp" || { say "   [ERROR] patched script has a syntax error; left unchanged"; rm -f "$tmp"; exit 1; }
        cat "$tmp" > "$MOUNT_SCRIPT"; rm -f "$tmp"
        say "   patched (backup: ${MOUNT_SCRIPT}.bak-camera)"
    fi
fi

# 3) start order: NFS first, then the SMB/bind script
say "3) order router-smb.service after router-nfs.service"
if [[ -f "$DROPIN_DIR/camera.conf" ]]; then
    say "   already present"
else
    run mkdir -p "$DROPIN_DIR"
    if (( DRY )); then say "  [dry-run] write $DROPIN_DIR/camera.conf"; else
        printf '[Unit]\nWants=router-nfs.service\nAfter=router-nfs.service\n' > "$DROPIN_DIR/camera.conf"
    fi
    run systemctl daemon-reload
fi

say ""
if (( DRY )); then say "Dry run only - nothing was changed."; else
    say "Done. Check:  ls $MP/$NAME | head"
fi
