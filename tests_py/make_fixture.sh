#!/usr/bin/env bash
# make_fixture.sh <dir> — build a throwaway "router + local disk" tree with real (tiny) media.
set -euo pipefail
t="$1"
mkdir -p "$t"/{local,router} "$t"/router/{LIBRARY.DESKTOP,LIBRARY.PORTABLE}/{PHOTOS,MUSIC,MOVIES,TV}
R="$t/router"
mkdir -p "$R"/{UNSORTED/{CAMERA,MUSIC/Artist/Album,MOVIES,TV,PHOTOS,DOWNLOADS,VIDEO},CAMERA}
photo() { mkdir -p "$(dirname "$1")"; convert -size 320x240 plasma:fractal "$1" 2>/dev/null; exiftool -q -overwrite_original -DateTimeOriginal="$2" "$1"; }
vid()   { mkdir -p "$(dirname "$1")"; ffmpeg -loglevel error -y -f lavfi -i testsrc=size=320x240:rate=15:duration=${3:-2} -f lavfi -i sine=duration=${3:-2} -shortest -metadata creation_time="$2" "$1"; }
# camera archive on the router (already archived earlier)
photo "$R/CAMERA/2026/10/20/IMG_1.jpg" "2026:10:20 10:01:00"
photo "$R/CAMERA/2026/10/20/IMG_2.jpg" "2026:10:20 10:02:00"
photo "$R/CAMERA/2026/10/20/IMG_6337.JPG" "2026:10:20 10:03:00"     # Live Photo pair
vid   "$R/CAMERA/2026/10/20/IMG_6337.MOV" "2026-10-20T10:03:00Z"
photo "$R/CAMERA/2020/04/30/old_exif.jpg" "2016:10:21 19:21:43"      # archive folder date != EXIF date
vid   "$R/CAMERA/2026/10/21/V_1.mp4" "2026-10-21T12:00:00Z" 3
# new camera files waiting in the router inbox
photo "$R/UNSORTED/CAMERA/100APPLE/NEW_1.jpg" "2026:10:22 12:01:00"
photo "$R/UNSORTED/CAMERA/100APPLE/NEW_2.jpg" "2026:10:22 12:02:00"
vid   "$R/UNSORTED/CAMERA/100APPLE/V_new.mp4" "2026-10-22T12:03:00Z"
# music
ffmpeg -loglevel error -y -f lavfi -i sine=frequency=440:duration=2 -metadata title="Song One" -metadata artist="Artist" -metadata album="Album" -metadata track=1 -metadata date=2020 "$R/UNSORTED/MUSIC/Artist/Album/01.flac"
ffmpeg -loglevel error -y -f lavfi -i sine=frequency=550:duration=2 -metadata title="Song Two" -metadata artist="Artist" -metadata album="Album" -metadata track=2 -metadata date=2020 "$R/UNSORTED/MUSIC/Artist/Album/02.flac"
# a photo in the PHOTOS inbox
photo "$R/UNSORTED/PHOTOS/Trip/P_1.jpg" "2025:07:04 09:00:00"
# noise files that must be ignored
echo x > "$R/UNSORTED/CAMERA/100APPLE/.DS_Store"; echo x > "$R/UNSORTED/CAMERA/100APPLE/readme.txt"
cat > "$t/settings.toml" <<TOML
[paths]
local_root  = "$t/local"
router_root = "$t/router"
[ingest]
enabled = true
verify  = true
streams = 2
[run]
workers = 4
video_workers = 2
retry = 1
TOML
(cd "$R" && find . -type f -exec sha256sum {} \; | sort -k2) > "$t/router.sha"
echo "fixture ready: $(find $R -type f | wc -l) files on the router"
