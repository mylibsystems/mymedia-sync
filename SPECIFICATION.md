# mylibsystems/sync — Specification

## Purpose

A set of bash scripts that automate importing, organizing, converting, and backing up a personal media library. Media is sourced from a camera, a downloads inbox, and local collections, then normalized and filed into a structured library on an external drive.

Every import produces **two parallel output trees**: one for desktop/hi-fi devices and one for portable devices. Source files are **moved** (not copied) out of the source directory after successful import, leaving the source folder empty.

Metadata for every media type is fetched from authoritative internet databases and embedded into the output files to the greatest extent possible. Folder structure must always reflect the embedded metadata.

---

## Target Devices

### Desktop / Hi-Fi
- **macOS** — Apple Music, QuickTime Player, Finder
- **Apple TV** — native import, full-resolution playback
- **High-resolution monitors and printers** — print-quality photos

### Portable
- **Sony Walkman NWZ-A720 / NWZ-A728** (primary portable target)
  - Screen: 2.0" TFT LCD, **320 × 240 px** (QVGA)
  - Audio: MP3 (8–320 kbps), AAC-LC (16–320 kbps, `.mp4`/`.m4a`), WMA
  - Video: MPEG-4 / **H.264 Baseline Profile Level 3.0**, max resolution **320 × 240**, max ~768 kbps total bitrate, audio AAC-LC 44.1 kHz
  - Photo: JPEG slideshow
  - No FLAC, no MKV, no M4V support

> The portable target dimensions and quality knobs are configurable (see **Configuration** section). The Sony NWZ-A720 values are defaults.

---

## Directory Layout

### Sources (read from, emptied after import)

| Path | Description |
|---|---|
| `/Volumes/LUMIX` | Panasonic Lumix camera (SD card mount) |
| `/Volumes/WD-ELEMENTS/INBOX` | Downloads / manually dropped files |
| `/Volumes/WD-ELEMENTS/MUSIC` | Existing raw music collection |
| `/Volumes/WD-ELEMENTS/MOVIES` | Existing raw movie collection |
| `/Volumes/WD-ELEMENTS/PHOTOS` | Existing raw photo collection |
| `/Volumes/WD-ELEMENTS/VIDEO` | Existing raw video collection |

### Library Destinations (written to)

| Path | Quality Tier | Content |
|---|---|---|
| `/Volumes/WD-ELEMENTS/LIBRARY.DESKTOP/MUSIC` | Desktop | FLAC lossless, organized by tags |
| `/Volumes/WD-ELEMENTS/LIBRARY.PORTABLE/MUSIC` | Portable | AAC-LC M4A, organized by tags |
| `/Volumes/WD-ELEMENTS/LIBRARY.DESKTOP/MOVIES` | Desktop | H.264 High Profile MP4/M4V, original resolution |
| `/Volumes/WD-ELEMENTS/LIBRARY.PORTABLE/MOVIES` | Portable | H.264 Baseline 320×240 MP4 |
| `/Volumes/WD-ELEMENTS/LIBRARY.DESKTOP/PHOTOS` | Desktop | JPEG quality 92, original size |
| `/Volumes/WD-ELEMENTS/LIBRARY.PORTABLE/PHOTOS` | Portable | JPEG quality 85, resized to 320×240 |

---

## Configuration

All quality and device parameters are defined as variables at the top of each script (or in a shared `config.sh` sourced by all scripts). Defaults target the device set above. Override on the command line or by editing `config.sh`.

```bash
# Portable video target (Sony NWZ-A720 defaults)
PORTABLE_VIDEO_WIDTH=320
PORTABLE_VIDEO_HEIGHT=240
PORTABLE_VIDEO_BITRATE=512k        # video stream bitrate
PORTABLE_VIDEO_AUDIO_BITRATE=128k  # audio stream bitrate in video
PORTABLE_VIDEO_AUDIO_RATE=44100    # sample rate Hz
PORTABLE_VIDEO_PROFILE=baseline    # H.264 profile
PORTABLE_VIDEO_LEVEL=3.0           # H.264 level

# Portable photo target
PORTABLE_PHOTO_LONGEST_EDGE=320    # longest edge in pixels
PORTABLE_PHOTO_QUALITY=85          # JPEG quality 0-100

# Portable audio target
PORTABLE_AUDIO_BITRATE=640k        # AAC-LC bitrate (above device spec but plays fine in practice)
PORTABLE_AUDIO_RATE=48000          # sample rate Hz

# Desktop video target (Apple/QuickTime/Apple TV)
DESKTOP_VIDEO_CRF=18               # H.264 CRF (lower = better quality)
DESKTOP_VIDEO_PRESET=slow          # x264 encode speed/quality tradeoff
DESKTOP_VIDEO_AUDIO_BITRATE=320k
DESKTOP_VIDEO_AUDIO_RATE=48000

# Desktop photo target
DESKTOP_PHOTO_QUALITY=92           # JPEG quality 0-100

# Desktop audio: FLAC compression level (0=fastest, 8=smallest, lossless either way)
DESKTOP_AUDIO_FLAC_LEVEL=8
```

---

## Audio Requirements

### Desktop — FLAC (Lossless)

- **Format:** FLAC (Free Lossless Audio Codec), container `.flac`
- **Bit depth:** preserve original (16-bit or 24-bit as present in source)
- **Sample rate:** preserve original (44.1 kHz, 48 kHz, 88.2 kHz, 96 kHz, etc.)
- **Compression level:** `$DESKTOP_AUDIO_FLAC_LEVEL` (default 8 — maximum compression, zero quality loss)
- **No re-encoding if source is already FLAC** — copy stream, re-embed metadata only
- **Encoding tool:** `ffmpeg -c:a flac -compression_level 8`
- Compatible with: macOS, Apple Music, any audiophile player

### Portable — AAC-LC (M4A)

- **Format:** AAC-LC (Low Complexity), container `.m4a`
- **Bitrate:** `$PORTABLE_AUDIO_BITRATE` (default **640 kbps** — exceeds the device's published 320 kbps ceiling but plays correctly in practice on NWZ-A720; higher bitrate = better quality when the file is also played on macOS/Apple Music)
- **Sample rate:** `$PORTABLE_AUDIO_RATE` (default **48 kHz**, matching v1 proven behaviour)
- **Channels:** stereo (2-channel)
- **Encoding tool:** `ffmpeg -c:a libfdk_aac -b:a 640k -ar 48000 -ac 2 -movflags +faststart`
  - `libfdk_aac` is used over the native ffmpeg AAC encoder for superior quality at high bitrates
  - Alternative on macOS with AudioToolbox: `-c:a aac_at -b:a 640k` for Apple-native encoder
- **No re-encoding if source is already AAC-LC at or above 640 kbps** — copy stream, re-embed metadata only
- **Compatible with:** Sony NWZ-A720/A728, macOS, Apple Music, iOS

### Audio Metadata (Both Tiers)

**Preserve-first principle:** all existing embedded tags and cover art in the source file are transferred verbatim to the output file. Internet databases are consulted **only to fill in missing fields** — they never overwrite a tag that is already present. An online match is additionally used to *verify* existing key tags (Artist, Album, Year, Track Number) and flag suspicious mismatches in the log, but the original value is kept.

Required tags per file:

| Tag | Primary source | Filled from internet if missing |
|---|---|---|
| `Title` | Embedded tag | MusicBrainz |
| `Album Artist` | Embedded tag | MusicBrainz |
| `Artist` | Embedded tag | MusicBrainz |
| `Album` | Embedded tag | MusicBrainz |
| `Date` / `Year` | Embedded tag | MusicBrainz |
| `Track Number` | Embedded tag | MusicBrainz |
| `Disc Number` | Embedded tag | MusicBrainz (default `1` if absent) |
| `Genre` | Embedded tag | MusicBrainz |
| `Cover Art` (FRONT_COVER, 500×500 px min) | Embedded image | MusicBrainz CAA → Last.fm |

**Metadata lookup pipeline:**
1. Read **all** existing embedded tags and cover art with `exiftool` / `ffprobe` — this is the authoritative input
2. Copy all existing tags and cover art to the output file unchanged
3. For each required tag that is **absent** in the source, query **MusicBrainz** (via AcoustID fingerprint `fpcalc` first; fall back to artist + album text search) to retrieve the missing value
4. If cover art is **absent**, fetch from **MusicBrainz Cover Art Archive** → fall back to **Last.fm** `album.getInfo`
5. Embed only the newly fetched fields; log each addition with `[ADDED from MusicBrainz]`
6. Optionally cross-check existing Artist / Album / Year against MusicBrainz result; log `[MISMATCH]` warnings but do **not** alter the original values
7. For FLAC output: use `metaflac`; for M4A: use `AtomicParsley` or `ffmpeg -metadata`; for MP3 intermediate: use `eyeD3` in ID3v2.3 format

**Cover art requirements:** minimum 500×500 px, JPEG, embedded as `FRONT_COVER` (ID3 / M4A atom). Readable on Sony NWZ-A720 album view and Apple Music.

---

## Audio Organization

Both desktop and portable outputs use the **same 2-level folder structure** derived purely from embedded metadata:

```
<Album Artist>/<Year> - <Album>/[Disc].[Track] - track.<ext>
```

**Rules:**
- `<Album Artist>` — use `ALBUMARTIST` tag; fall back to `ARTIST` if absent. Sanitize `/` to `-`.
- `<Year>` — 4-digit year only (extracted from `DATE` tag, e.g. `2003` from `2003-05-12`)
- `<Album>` — sanitize `/` to `-`
- `[Disc]` — 1-digit zero-padded disc number; `1` if absent
- `[Track]` — 2-digit zero-padded track number
- File is named `[Disc].[Track] - track.<ext>` (content-agnostic filename; metadata carries the title)
- If any of Artist, Year, Album, Track Number is absent **after metadata lookup**, log and skip the file
- Cover art file `cover.jpg` is placed in the album folder alongside the tracks

**Example:**

```
Pink Floyd/1973 - The Dark Side of the Moon/
  1.01 - track.flac       ← Desktop
  cover.jpg

Pink Floyd/1973 - The Dark Side of the Moon/
  1.01 - track.m4a        ← Portable
  cover.jpg
```

---

## Video Requirements

Every video import produces two output files: one desktop and one portable version. Source is moved after both outputs are successfully created.

### Desktop — H.264 High Profile (MP4 / M4V)

- **Container:** `.mp4` (preferred for Apple TV compatibility) or `.m4v` (for iTunes library)
- **Video codec:** H.264 (`libx264`), **High Profile**, CRF `$DESKTOP_VIDEO_CRF` (default **18** — visually lossless), preset `$DESKTOP_VIDEO_PRESET` (default `slow`)
- **Resolution:** same as source — **do not scale or crop** (Apple TV and modern Macs can handle 4K)
- **Frame rate:** preserve source frame rate
- **Audio codec:** AAC-LC (`libfdk_aac`), `$DESKTOP_VIDEO_AUDIO_BITRATE` (default **320 kbps**), `$DESKTOP_VIDEO_AUDIO_RATE` (default **48 kHz**), stereo or 5.1 preserved from source
- **Subtitles:** pass through if present
- **Fast-start:** `-movflags +faststart` for streaming
- Compatible with: QuickTime Player, macOS, Apple TV (native import), Final Cut Pro

### Portable — H.264 Baseline Profile (MP4, Sony NWZ-A720)

- **Container:** `.mp4`
- **Video codec:** H.264 (`libx264`), **Baseline Profile**, Level `$PORTABLE_VIDEO_LEVEL` (default **3.0**)
- **Resolution:** scale to fit `$PORTABLE_VIDEO_WIDTH`×`$PORTABLE_VIDEO_HEIGHT` (default **320×240**), preserving aspect ratio with black padding (`pad` filter) to fill exactly 320×240
  - Use `scale=320:240:force_original_aspect_ratio=decrease,pad=320:240:(ow-iw)/2:(oh-ih)/2`
- **Video bitrate:** `-b:v $PORTABLE_VIDEO_BITRATE` (default **512 kbps**)
- **Frame rate:** cap at 30 fps (`-r 30`)
- **Audio codec:** AAC-LC, `-b:a $PORTABLE_VIDEO_AUDIO_BITRATE` (default **128 kbps**), `-ar $PORTABLE_VIDEO_AUDIO_RATE` (default **44.1 kHz**), stereo (`-ac 2`)
- **Reference frames:** `-refs 1` (required for Baseline Level 3.0)
- **B-frames:** `-bf 0` (Baseline Profile, no B-frames)
- **Encoding command example:**
  ```bash
  ffmpeg -i "$input" \
    -vf "scale=320:240:force_original_aspect_ratio=decrease,pad=320:240:(ow-iw)/2:(oh-ih)/2" \
    -c:v libx264 -profile:v baseline -level 3.0 -b:v 512k -r 30 -refs 1 -bf 0 \
    -c:a libfdk_aac -b:a 128k -ar 44100 -ac 2 \
    -movflags +faststart "$output"
  ```
- Compatible with: Sony NWZ-A720 / NWZ-A728

### Video Metadata (Both Tiers)

Metadata is fetched from internet databases and embedded into the MP4 container using `AtomicParsley` or `ffmpeg -metadata`. Cover art (poster/thumbnail) is also embedded.

**Tier parity — portable mirrors desktop.** The portable output always carries the **same embedded metadata and cover art as the desktop output**: title, year, genre, and TV tags are identical, and the same poster/cover image is embedded. The portable tier never strips, blanks, or independently re-looks-up these fields — it inherits them from the desktop pass. The only deliberate differences are:
- the long **description** is omitted on portable (the Sony Walkman NWZ does not display it);
- the embedded cover art is **downscaled** to fit `PORTABLE_VIDEO_WIDTH`×`PORTABLE_VIDEO_HEIGHT` (preserving aspect ratio) to keep the file small.

**Lookup pipeline:**
1. Identify content type: movie or TV episode (by directory name, existing tags, or interactive prompt)
2. **Movies:** query **The Movie Database (TMDB)** API — fetch title, year, genre, description, poster image
3. **TV series:** query **TMDB** or **TheTVDB** API — fetch series name, season, episode number, episode title, air date, description, thumbnail
4. Sanitize and embed all fields as MP4 atoms (`©nam`, `©day`, `©gen`, `desc`, `ldes`, `covr`)
5. If TMDB lookup fails, embed what is available from filename/directory heuristics

**Embedded fields:**

| Field | Movies | TV Episodes |
|---|---|---|
| Title (`©nam`) | Movie title | Episode title |
| Year (`©day`) | Release year | Air date |
| Genre (`©gen`) | TMDB genre | TMDB genre |
| Description (`desc`) | TMDB overview | Episode synopsis |
| Cover art (`covr`) | TMDB poster (max available size, JPEG) | Episode still / series poster |
| TV Show name (`tvsh`) | — | Series name |
| Season number (`tvsn`) | — | Season number |
| Episode number (`tven`) | — | Episode number |

> **Portable tier:** every field above is embedded identically to the desktop file, **except** `desc` (Description), which is omitted on the portable copy, and `covr` (Cover art), which is downscaled to the portable video dimensions. All other fields — including **Title** — are always present and match the desktop output.

### Video Organization (Both Tiers)

Both desktop and portable outputs use the same **2-level folder structure**:

**Movies:**
```
<Movie Title> (<Year>)/
  <Movie Title> (<Year>).mp4
```

**TV Series:**
```
<Series Name>/
  S<Season>E<Episode> - <Episode Title>.mp4
```

**Rules:**
- Sanitize `:`, `/`, `?`, `*`, `"`, `<`, `>`, `|` in names to `-` or space
- Season and episode numbers are zero-padded to 2 digits: `S01E03`
- If season/episode cannot be determined, fall back to air date: `<YYYY-MM-DD> - <Title>`
- Desktop and portable files share the same folder layout; filename suffix distinguishes quality (e.g., `.desktop.mp4` vs `.portable.mp4`) if kept in same tree, or separate tree roots (recommended)

**Example:**
```
Blade Runner 2049 (2017)/
  Blade Runner 2049 (2017).mp4       ← Desktop
  Blade Runner 2049 (2017).mp4       ← Portable (separate root)

Breaking Bad/
  S01E01 - Pilot.mp4
  S01E02 - Cat's in the Bag.mp4
```

---

## Photo Requirements

Every photo import produces two output files from the same source RAW/JPEG. Source is moved after both outputs are created.

### Desktop — JPEG (Full Quality, Print-Ready)

- **Format:** JPEG
- **Resolution:** original sensor resolution, **no scaling**
- **Quality:** `$DESKTOP_PHOTO_QUALITY` (default **92** — no visible degradation at 1:1 on any monitor, suitable for printing)
- **EXIF:** all original metadata preserved verbatim — GPS, camera model, lens, exposure, ICC color profile
- **Orientation:** auto-rotate to upright based on EXIF orientation tag, then strip the rotation tag
- **Conversion:**
  - RAW (`.ORF`, `.RW2`, `.CR2`, `.NEF`, `.ARW`): convert via `sips` → JPEG at quality 92, then copy EXIF from original using `exiftool -TagsFromFile`
  - HEIC: convert via `sips -s format jpeg --setProperty formatOptions 92`
  - JPEG source: copy to destination, re-embed date metadata if missing — no re-compression
- **Date tag mandatory:** `DateTimeOriginal` EXIF field must be set. If absent, attempt to extract from filename (`YYYYMMDD`, `YYYY-MM-DD` patterns) or `FileModifyDate`. Log if still absent.

### Portable — JPEG (Sony NWZ-A720)

- **Format:** JPEG
- **Resolution:** scale down to fit `$PORTABLE_PHOTO_LONGEST_EDGE` × `$PORTABLE_PHOTO_LONGEST_EDGE` (default **320** × **320**), preserve aspect ratio (do not crop), using `sips -Z 320`
- **Quality:** `$PORTABLE_PHOTO_QUALITY` (default **85**)
- **EXIF:** preserve `DateTimeOriginal`, `Make`, `Model`, `Orientation`, `GPSLatitude`, `GPSLongitude` — strip bulky MakerNote and embedded thumbnail from portable copy to minimize file size
- **Thumbnail:** embed a 96×96 px JPEG thumbnail in EXIF for device browser display, using `exiftool -ThumbnailImage<=thumbnail.jpg`
- Compatible with: Sony NWZ-A720 photo slideshow viewer (supports JPEG up to its screen resolution)

### Photo Organization (Both Tiers)

Photos are organized by **capture date** from EXIF `DateTimeOriginal`, 3 levels deep:

```
<YYYY>/<MM>/<DD>/<original filename>.<ext>
```

**Rules:**
- `<YYYY>` — 4-digit year
- `<MM>` — 2-digit month (zero-padded)
- `<DD>` — 2-digit day (zero-padded)
- `<original filename>` — original base name from camera (e.g., `P1040321`, `IMG_5892`) — **not renamed**
- Extension normalized to lowercase: `.jpg` (not `.JPG`)
- If two files produce the same output path (same date + same name), append `_1`, `_2`, etc. before the extension
- Cover/album-art files (filename matches `cover`, `album`, `art`) are skipped

**Example:**
```
2024/06/15/P1040321.jpg     ← Desktop
2024/06/15/P1040322.jpg

2024/06/15/P1040321.jpg     ← Portable (separate root, scaled down)
```

---

## Metadata Fetch Architecture

All metadata lookups are non-blocking best-effort: if a lookup fails or times out (10 s default), the file is still processed with whatever metadata is available. Failures are logged.

| Media Type | Preserved as-is | Added if missing | Verified against |
|---|---|---|---|
| Audio tags | All existing embedded tags | MusicBrainz REST API + AcoustID (`fpcalc`) | MusicBrainz (log mismatches only) |
| Audio cover art | Embedded image | MusicBrainz Cover Art Archive → Last.fm | — |
| Movie metadata | All existing MP4 atoms | TMDB API (`/movie/search`, `/movie/{id}`) | TMDB (log mismatches only) |
| TV metadata | All existing MP4 atoms | TMDB or TheTVDB API | TMDB (log mismatches only) |
| Video poster/art | Embedded `covr` atom | TMDB image CDN → ffmpeg still frame | — |
| Photo EXIF | All original EXIF/XMP/IPTC | Filename pattern → `FileModifyDate` (date only) | — |

API keys for TMDB and Last.fm are stored in `config.sh` as environment variables (`TMDB_API_KEY`, `LASTFM_API_KEY`). MusicBrainz and AcoustID are used without a key (rate-limited to ~1 req/s).

---

## Scripts

### `sync.sh` — Main Orchestrator

Entry point. Sources `config.sh`, clears previous log files, then runs all pipeline stages in order.

**Stages (in order):**

1. **Camera import** — iterate subdirectories under `/Volumes/LUMIX`; run `import.sh` for each in parallel, writing to both desktop and portable photo trees.
2. **Downloads import** — iterate subdirectories under `INBOX`; run `import.sh` for each in parallel.
3. **Music import** — iterate source `MUSIC`; run `import.sh` for each album folder in parallel, writing desktop FLAC and portable AAC.
4. **Movies import** — iterate source `MOVIES`; run `import.sh` for each folder, writing desktop H.264 High and portable H.264 Baseline.
5. **Cleanup** — remove `.syncing` temp directories from all library destinations; delete empty source directories.

Parallel stages use bash background jobs (`& pid=$!`) collected into `PID_LIST`, with `wait` and a `SIGINT` trap to kill children on interrupt.

---

### `config.sh` — Shared Configuration

Sourced by all other scripts. Defines:
- Device target parameters (see **Configuration** section above)
- API keys (`TMDB_API_KEY`, `LASTFM_API_KEY`)
- Source and library root paths
- Concurrency limits (`MAX_PARALLEL_JOBS`, default = number of CPU cores)

---

### `import.sh` — Import Driver

```
./import.sh <sourceDir> <folderLabel> <mediaRootDir>
```

Walks `<sourceDir>` up to depth 8 with `find -type f` and calls `orginize.sh` on each file. Output is appended to `import.log`.

---

### `orginize.sh` — File Organizer

```
./orginize.sh <filePath> <folderLabel> <mediaRootDir>
```

Processes a single source file: fetches metadata, converts to desktop and portable formats, moves the output to the correct library sub-tree, then removes the source file on success. Logic is determined by file extension.

**Organization strategies:**

| Strategy | Behavior |
|---|---|
| `orginizeByDate` | Reads `DateTimeOriginal` from EXIF via `exiftool`; falls back to `FileModifyDate`. Creates `YYYY/MM/DD` subdirectory. Calls `convert.sh` for both desktop and portable photo output. |
| `orginizeByTags` | Fetches/validates all required audio tags (see Audio Metadata section). Creates `<Artist>/<Year> - <Album>/[Disc].[Track] - track.<ext>` for both desktop (FLAC) and portable (AAC). |
| `orginizeByVideoMeta` | Fetches movie/TV metadata from TMDB/TheTVDB. Creates `<Title> (<Year>>/` or `<Series>/S<s>E<e> - <title>` structure for both desktop and portable video. |
| `orginizeDefault` | Uses the source folder label as subdirectory name. Falls back when type cannot be determined. |

**Extension routing:**

| Extensions | Strategy | Media Type |
|---|---|---|
| `m4a`, `flac`, `mp3`, `aac`, `ogg`, `wav`, `aiff` | `orginizeByTags` | Audio |
| `jpg`, `JPG`, `jpeg`, `JPEG`, `heic`, `HEIC`, `ORF`, `orf`, `RW2`, `rw2`, `CR2`, `cr2`, `NEF`, `nef`, `ARW`, `arw`, `TIFF`, `tiff` | `orginizeByDate` | Photo |
| `mp4`, `MP4`, `mov`, `MOV` | `orginizeByVideoMeta` | Video (camera / download) |
| `avi`, `AVI`, `mkv`, `MKV`, `mpeg`, `MPEG`, `avc`, `AVC`, `m4v`, `M4V`, `wmv`, `WMV` | `orginizeByVideoMeta` | Video (library) |

All strategies skip the output file if it already exists (`skipIfExists`). Unknown extensions are logged and skipped.

---

### `convert.sh` — File Converter

```
./convert.sh <filePath> <tier> <destDir>
```

Converts a single file to the target format for `<tier>` (`desktop` or `portable`) and writes it to `<destDir>`. Uses a `.syncing` staging directory during conversion.

**Audio conversion:**

| Operation | Tier | Tool | Parameters |
|---|---|---|---|
| `convertToFlac` | desktop | `ffmpeg` | `-c:a flac -compression_level $DESKTOP_AUDIO_FLAC_LEVEL`, preserve sample rate and bit depth |
| `convertToAac` | portable | `ffmpeg` | `-c:a libfdk_aac -b:a $PORTABLE_AUDIO_BITRATE -ar $PORTABLE_AUDIO_RATE -ac 2 -movflags +faststart` |
| `embedAudioMeta` | both | `AtomicParsley` / `metaflac` / `eyeD3` | Embed all fetched tags + cover art (FRONT_COVER, 500×500 min) |

**Video conversion:**

| Operation | Tier | Tool | Parameters |
|---|---|---|---|
| `convertToDesktopMp4` | desktop | `ffmpeg` | `-c:v libx264 -profile:v high -crf $DESKTOP_VIDEO_CRF -preset $DESKTOP_VIDEO_PRESET`, original resolution, `-c:a libfdk_aac -b:a $DESKTOP_VIDEO_AUDIO_BITRATE -ar $DESKTOP_VIDEO_AUDIO_RATE`, `-movflags +faststart` |
| `convertToPortableMp4` | portable | `ffmpeg` | `-vf "scale=W:H:force_original_aspect_ratio=decrease,pad=W:H:(ow-iw)/2:(oh-ih)/2"`, `-c:v libx264 -profile:v baseline -level $PORTABLE_VIDEO_LEVEL -b:v $PORTABLE_VIDEO_BITRATE -r 30 -refs 1 -bf 0`, `-c:a libfdk_aac -b:a $PORTABLE_VIDEO_AUDIO_BITRATE -ar $PORTABLE_VIDEO_AUDIO_RATE -ac 2`, `-movflags +faststart` |
| `embedVideoMeta` | both | `AtomicParsley` | Embed title, year, genre, description, cover art (`covr`), TV tags |

**Photo conversion:**

| Operation | Tier | Tool | Parameters |
|---|---|---|---|
| `convertToDesktopJpeg` | desktop | `sips` + `exiftool` | Convert RAW/HEIC to JPEG quality `$DESKTOP_PHOTO_QUALITY`, no resize, copy all EXIF with `exiftool -TagsFromFile` |
| `convertToPortableJpeg` | portable | `sips` + `exiftool` | Convert to JPEG quality `$PORTABLE_PHOTO_QUALITY`, scale to `$PORTABLE_PHOTO_LONGEST_EDGE` px, preserve date/GPS/orientation tags, strip MakerNote, embed 96×96 thumbnail |

Both photo operations skip re-compression if source is already JPEG at the target quality level.

---

### `backup.sh` — Backup Driver

```
./backup.sh <sourceDir> <destDir> <mediaLabel> [export]
```

Walks `<sourceDir>` up to depth 8 with `find -type f` and calls `transfer.sh` on each file. Output is appended to `backup.log`.

---

### `transfer.sh` — File Mover/Copier

```
./transfer.sh <sourceFile> <destDir> <mediaLabel> [export]
```

Replicates the source directory structure under `<destDir>`. If `export=on`, copies the file; otherwise moves it. Uses `mkdir -p` for intermediate directories. Skips if destination already exists (`cp -n` / `mv -n`).

---

### `clean.sh` — RAW Cleanup

Standalone utility (no arguments). Scans the `PHOTOS/` source directory for RAW files and removes paired or redundant files:

- `.RW2` / `.rw2` — removes any paired `.jpg`, `.JPG`, `.jpeg`, `.JPEG` file at the same base path
- `.TIFF` / `.tiff` — removes the TIFF file itself (intermediary artifact)

---

## Dependencies

| Tool | Purpose | Install |
|---|---|---|
| `ffmpeg` (with `libfdk_aac`, `libx264`) | All audio/video transcoding | `brew install ffmpeg --with-fdk-aac` or Docker `jrottenberg/ffmpeg` |
| `exiftool` | Read/write EXIF, XMP, IPTC metadata from all media types | `brew install exiftool` |
| `sips` | macOS native image conversion and resizing | Built-in macOS |
| `AtomicParsley` | Embed metadata and cover art into MP4/M4A atoms | `brew install atomicparsley` |
| `metaflac` | Embed metadata into FLAC files | `brew install flac` |
| `eyeD3` | MP3 ID3v2.3 tag manipulation | `pip install eyeD3` |
| `fpcalc` (AcoustID) | Generate audio fingerprint for MusicBrainz lookup | `brew install chromaprint` |
| `curl` / `jq` | TMDB, Last.fm, MusicBrainz API calls + JSON parsing | `brew install jq` |

Docker (`jrottenberg/ffmpeg`) is supported as an alternative to a local ffmpeg build when `libfdk_aac` is not available natively.

---

## Logging

| File | Written by |
|---|---|
| `import.log` | `import.sh` (via `orginize.sh`) |
| `export.log` | `export.sh` (via `convert.sh`) |
| `backup.log` | `backup.sh` (via `transfer.sh`) |
| `sync.log` | Reserved (rsync project backup) |

All logs are cleared at the start of each `sync.sh` run.

---

## Design Constraints

- **Dual-output** — every source file produces both a desktop and a portable output before the source is moved.
- **Source destruction only on success** — the source file is removed only after both output files are verified present on disk.
- **Idempotent** — every operation checks for the existence of the output file before acting; re-running is safe.
- **Non-destructive writes** — `cp -n` and `mv -n` are used throughout; existing files are never overwritten.
- **Parallel imports** — camera and downloads import stages run per-folder background jobs in parallel, capped at `$MAX_PARALLEL_JOBS` (default = CPU core count via `sysctl -n hw.logicalcpu`).
- **Metadata-first organization** — folder structure is always derived from authoritative metadata, never from source folder names alone.
- **macOS-specific tools** — `sips` for image conversion, `aac_at` (AudioToolbox) as optional AAC encoder, volume paths under `/Volumes/`.
- **Internet metadata fetch** — all lookups are best-effort with a 10 s timeout; files are never blocked on a failed lookup.
- **Configurable device targets** — all device-specific parameters (resolution, bitrate, quality) are variables in `config.sh` with documented Sony NWZ-A720 defaults.
