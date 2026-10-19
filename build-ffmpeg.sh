#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# build-ffmpeg.sh — build a LOCAL ffmpeg with libfdk_aac for exact v2 AAC parity.
# ---------------------------------------------------------------------------
# IMPORTANT (licensing): ffmpeg configured with --enable-nonfree --enable-libfdk-aac
# produces a binary that is "nonfree and unredistributable". It is completely fine
# to BUILD and USE it locally, but it must NEVER be committed or redistributed.
# It installs into ./.ffmpeg (which is gitignored) and the pipeline uses it only
# for encoding via $FFMPEG_BIN. The system ffmpeg is left untouched.
#
# macOS users get libfdk_aac through Homebrew (see `sync.sh setup`); this script
# targets apt-based Linux.
# ---------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/platform.sh"

FFMPEG_VERSION="${FFMPEG_VERSION:-8.0}"
PREFIX="${FFMPEG_PREFIX:-${SCRIPT_DIR}/.ffmpeg}"
BIN="${PREFIX}/bin/ffmpeg"

# Already built with libfdk_aac? Nothing to do.
if [[ -x "$BIN" ]] && "$BIN" -hide_banner -encoders 2>/dev/null | grep -qw libfdk_aac; then
    echo "[FFMPEG] Already built with libfdk_aac: $BIN"
    exit 0
fi

if [[ "$OS_NAME" == "macos" ]]; then
    echo "[FFMPEG] On macOS install a libfdk_aac build via Homebrew instead:" >&2
    echo "         brew install homebrew-ffmpeg/ffmpeg/ffmpeg --with-fdk-aac" >&2
    exit 1
fi

if ! command -v apt-get &>/dev/null; then
    echo "[ERROR] Automated ffmpeg+libfdk_aac build is only scripted for apt-based Linux." >&2
    echo "        Install: build tools, nasm/yasm, libfdk-aac-dev, libx264-dev, libzimg-dev, zlib1g-dev" >&2
    echo "        then build ffmpeg with --enable-gpl --enable-nonfree --enable-libfdk-aac." >&2
    exit 1
fi

echo "[FFMPEG] Installing build dependencies (sudo required)..."
sudo apt-get update
sudo apt-get install -y \
    build-essential nasm yasm pkg-config curl \
    libfdk-aac-dev libx264-dev libzimg-dev zlib1g-dev

BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ffmpeg-build-XXXXXX")"
trap 'rm -rf "$BUILD_DIR"' EXIT
cd "$BUILD_DIR"

echo "[FFMPEG] Downloading ffmpeg ${FFMPEG_VERSION}..."
curl -fLO "https://ffmpeg.org/releases/ffmpeg-${FFMPEG_VERSION}.tar.xz"
tar xf "ffmpeg-${FFMPEG_VERSION}.tar.xz"
cd "ffmpeg-${FFMPEG_VERSION}"

echo "[FFMPEG] Configuring (prefix=${PREFIX})..."
./configure --prefix="$PREFIX" \
    --enable-gpl --enable-nonfree \
    --enable-libx264 --enable-libfdk-aac --enable-libzimg \
    --disable-doc --disable-ffplay

echo "[FFMPEG] Building (this takes a few minutes)..."
make -j"$(cpu_count)"
make install

if "$BIN" -hide_banner -encoders 2>/dev/null | grep -qw libfdk_aac; then
    echo "[FFMPEG] Success: $BIN (libfdk_aac enabled)"
else
    echo "[ERROR] Built ffmpeg is missing libfdk_aac." >&2
    exit 1
fi
