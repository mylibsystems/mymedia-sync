#!/usr/bin/env bash
# platform.sh — cross-platform (macOS + Linux/Xubuntu) compatibility layer.
#
# Sourced by config.sh (which every other script sources). It abstracts away the
# few places where the pipeline used macOS-only tools so the exact same code runs
# on both platforms:
#
#   * OS detection            → $OS_NAME  (macos | linux | unknown)
#   * logical CPU count       → cpu_count()          (sysctl ⇄ nproc)
#   * image conversion/scaling → image_to_jpeg / image_scale_jpeg / image_dimensions
#                                (Apple `sips` ⇄ ImageMagick `magick`/`convert`)
#
# Never executed directly; only sourced.

# ---------------------------------------------------------------------------
# OS detection
# ---------------------------------------------------------------------------
case "$(uname -s 2>/dev/null)" in
    Darwin) OS_NAME="macos" ;;
    Linux)  OS_NAME="linux" ;;
    *)      OS_NAME="unknown" ;;
esac
export OS_NAME

# ---------------------------------------------------------------------------
# Logical CPU count (used for MAX_PARALLEL_JOBS)
# ---------------------------------------------------------------------------
cpu_count() {
    local n=""
    if [[ "$OS_NAME" == "macos" ]]; then
        n=$(sysctl -n hw.logicalcpu 2>/dev/null)
    else
        n=$(nproc 2>/dev/null)
    fi
    # getconf is a POSIX fallback available on both platforms
    [[ -z "$n" ]] && n=$(getconf _NPROCESSORS_ONLN 2>/dev/null)
    if ! [[ "$n" =~ ^[0-9]+$ ]] || (( n < 1 )); then
        n=4
    fi
    echo "$n"
}

# ---------------------------------------------------------------------------
# ImageMagick helpers (Linux path / non-macOS fallback)
# ---------------------------------------------------------------------------
# Return the ImageMagick convert binary name ("magick" on IM7, "convert" on IM6).
_im_convert_bin() {
    if command -v magick &>/dev/null; then echo "magick"
    elif command -v convert &>/dev/null; then echo "convert"
    fi
}
# Run ImageMagick identify (IM7 "magick identify" or IM6 "identify").
_im_identify() {
    if command -v magick &>/dev/null; then magick identify "$@"
    elif command -v identify &>/dev/null; then identify "$@"
    else return 1
    fi
}

# ---------------------------------------------------------------------------
# image_to_jpeg <input> <output> <quality 0-100>
# ---------------------------------------------------------------------------
# Convert any supported image (JPEG/PNG/HEIC/RAW/TIFF/…) to a JPEG at the given
# quality. EXIF is intentionally NOT preserved here — callers restore metadata
# from the original with exiftool afterwards (matches the macOS `sips` flow).
image_to_jpeg() {
    local in="$1" out="$2" q="$3"
    if [[ "$OS_NAME" == "macos" ]] && command -v sips &>/dev/null; then
        sips -s format jpeg --setProperty formatOptions "$q" "$in" --out "$out"
    else
        local im; im="$(_im_convert_bin)"
        if [[ -z "$im" ]]; then
            echo "[ERROR] No image converter found. Install ImageMagick (make setup)." >&2
            return 1
        fi
        # jpg: prefix forces JPEG output regardless of the staged file's extension.
        "$im" "${in}[0]" -quality "$q" "jpg:${out}"
    fi
}

# ---------------------------------------------------------------------------
# image_scale_jpeg <input> <output> <longest_edge_px> <quality 0-100>
# ---------------------------------------------------------------------------
# Downscale so the longest edge is <= longest_edge_px, then write JPEG. Never
# upscales (matches how the portable-photo path guards against enlarging).
image_scale_jpeg() {
    local in="$1" out="$2" edge="$3" q="$4"
    if [[ "$OS_NAME" == "macos" ]] && command -v sips &>/dev/null; then
        sips -Z "$edge" -s format jpeg --setProperty formatOptions "$q" "$in" --out "$out"
    else
        local im; im="$(_im_convert_bin)"
        if [[ -z "$im" ]]; then
            echo "[ERROR] No image converter found. Install ImageMagick (make setup)." >&2
            return 1
        fi
        # The trailing '>' makes -resize shrink-only (never enlarge).
        "$im" "${in}[0]" -resize "${edge}x${edge}>" -quality "$q" "jpg:${out}"
    fi
}

# ---------------------------------------------------------------------------
# image_auto_orient <file>
# ---------------------------------------------------------------------------
# Bake the EXIF orientation into the pixels so the image displays correctly on
# every viewer (including ones that ignore the orientation tag, e.g. the
# portable player), then normalise the Orientation tag to 1. Must be called
# AFTER metadata has been restored from the source (the restore re-imports the
# original — possibly rotated — Orientation tag).
#   * macOS: `sips` already rotates the pixels while converting, so the restored
#     tag is stale — just reset it to normal without rotating again.
#   * Linux/ImageMagick: `image_to_jpeg` does NOT auto-orient, so physically
#     rotate the pixels here (`mogrify -auto-orient` resets the tag to 1 too).
image_auto_orient() {
    local f="$1"
    if [[ "$OS_NAME" == "macos" ]] && command -v sips &>/dev/null; then
        exiftool -m -overwrite_original -n -Orientation=1 "$f" 2>/dev/null || true
    else
        local im; im="$(_im_convert_bin)"
        [[ -n "$im" ]] || return 0
        if [[ "$im" == "magick" ]]; then
            magick mogrify -auto-orient "$f" 2>/dev/null || true
        else
            mogrify -auto-orient "$f" 2>/dev/null || true
        fi
    fi
}

# ---------------------------------------------------------------------------
# image_dimensions <input>  → echoes "WIDTH HEIGHT"
# ---------------------------------------------------------------------------
image_dimensions() {
    local in="$1"
    if [[ "$OS_NAME" == "macos" ]] && command -v sips &>/dev/null; then
        local w h
        w=$(sips -g pixelWidth  "$in" 2>/dev/null | awk '/pixelWidth/  {print $2}')
        h=$(sips -g pixelHeight "$in" 2>/dev/null | awk '/pixelHeight/ {print $2}')
        echo "${w:-0} ${h:-0}"
    else
        local dims
        dims="$(_im_identify -format '%w %h' "${in}[0]" 2>/dev/null)"
        echo "${dims:-0 0}"
    fi
}
