#!/usr/bin/env bash
# prepare-disk.sh — ERASE a whole disk, format it exFAT (readable/writable on Linux and macOS) and
# create the mediasync layout (CAMERA, UNSORTED, logs, .mediasync-staging). Run as root.
#
#   sudo ./prepare-disk.sh /dev/sdX /mnt/media-local ERASE   [owner-uid]
#
# Refuses system disks, mounted router shares and anything that is not a whole disk.
set -euo pipefail

DEV="${1:-}"; MNT="${2:-/mnt/media-local}"; CONFIRM="${3:-}"; OWNER="${4:-${SUDO_UID:-${PKEXEC_UID:-1000}}}"
LABEL="MEDIALOCAL"

die() { echo "[ERROR] $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "run as root"
[[ -b "$DEV" ]] || die "usage: $0 /dev/sdX [mountpoint] ERASE [uid]"
[[ "$CONFIRM" == "ERASE" ]] || die "third argument must be the word ERASE"
[[ "$(lsblk -dno TYPE "$DEV")" == "disk" ]] || die "$DEV is not a whole disk"

root_src="$(findmnt -no SOURCE /)"
root_disk="$(lsblk -no PKNAME "$root_src" 2>/dev/null | head -1 || true)"
[[ "/dev/${root_disk}" != "$DEV" ]] || die "$DEV holds the system root"
if lsblk -nro MOUNTPOINT "$DEV" | grep -qE '^/($|boot|home|usr|var)'; then die "$DEV holds a system mount"; fi

echo "Erasing $DEV: $(lsblk -dno SIZE,MODEL "$DEV")"
for part in $(lsblk -nro NAME,MOUNTPOINT "$DEV" | awk 'NF>1{print $2}' | sort -r); do
    umount "$part"
done
for part in $(lsblk -nro PATH "$DEV" | tail -n +2); do swapoff "$part" 2>/dev/null || true; done

wipefs -a -f "$DEV"* >/dev/null 2>&1 || true
sgdisk --zap-all "$DEV" >/dev/null
sgdisk -n 1:0:0 -t 1:0700 -c 1:"$LABEL" "$DEV" >/dev/null
partprobe "$DEV"; udevadm settle
PART="$(lsblk -nro PATH "$DEV" | sed -n 2p)"
[[ -b "$PART" ]] || die "partition not created"

mkfs.exfat -L "$LABEL" "$PART"
UUID="$(blkid -s UUID -o value "$PART")"

mkdir -p "$MNT"
mount -t exfat -o "uid=${OWNER},gid=${OWNER},umask=0022,noatime" "UUID=${UUID}" "$MNT"
sudo_user_dirs=(CAMERA UNSORTED logs .mediasync-staging)
for d in "${sudo_user_dirs[@]}"; do mkdir -p "$MNT/$d"; done

# Persistent mount (nofail so a missing disk never blocks boot).
sed -i "\|^UUID=.* ${MNT} |d" /etc/fstab
echo "UUID=${UUID} ${MNT} exfat uid=${OWNER},gid=${OWNER},umask=0022,noatime,nofail,x-systemd.device-timeout=5 0 0" >> /etc/fstab

echo "OK  ${PART} -> ${MNT} (UUID ${UUID})"
df -h "$MNT"
