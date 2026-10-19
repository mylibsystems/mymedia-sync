# Makefile — orchestrator for the MyMedia Sync pipeline (macOS + Linux).
#
# Every command in the pipeline is exposed as a make target. Start with:
#
#     make setup      # install all dependencies on a fresh machine (mac or linux)
#     make check      # verify every required tool is present
#     make sync       # run the full import pipeline
#
# Pass a library root to any run target with MEDIA_PATH=/path/to/drive, e.g.
#
#     make sync   MEDIA_PATH=/Volumes/WD-ELEMENTS
#     make music  MEDIA_PATH=/mnt/media
#
# ---------------------------------------------------------------------------

SHELL := /bin/bash
.DEFAULT_GOAL := help

# Directory this Makefile lives in (so `make` works from anywhere).
ROOT := $(patsubst %/,%,$(dir $(abspath $(lastword $(MAKEFILE_LIST)))))

# Optional library root passed through to sync.sh (UNSORTED + LIBRARY.* live here).
MEDIA_PATH ?=
MP := $(if $(strip $(MEDIA_PATH)),MEDIA_PATH=$(strip $(MEDIA_PATH)),)

# backup.sh / transfer.sh / convert.sh arguments (override on the command line).
SRC   ?=
DEST  ?=
LABEL ?= misc
MODE  ?= move
FILE  ?=
TIER  ?= desktop

.PHONY: help setup check doctor build-ffmpeg sync camera downloads music movies tv photos \
        playlist backup transfer convert clean-raw stop

# ---------------------------------------------------------------------------
help: ## Show this help
	@echo "MyMedia Sync — pipeline orchestrator"
	@echo ""
	@echo "Usage: make <target> [MEDIA_PATH=/path/to/drive]"
	@echo ""
	@grep -E '^[a-zA-Z0-9_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| sort \
		| awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-12s\033[0m %s\n",$$1,$$2}'

# ---- Environment -----------------------------------------------------------
setup: ## Install all dependencies for this OS (mac: brew, linux: apt)
	@bash "$(ROOT)/sync.sh" setup

check: ## Verify every required tool is installed (no changes)
	@SYNC_AUTOTEE=0 bash "$(ROOT)/sync.sh" doctor

doctor: check ## Alias for `check`

build-ffmpeg: ## Build local ffmpeg w/ libfdk_aac (Linux; nonfree, do NOT redistribute)
	@bash "$(ROOT)/build-ffmpeg.sh"

# ---- Pipeline --------------------------------------------------------------
sync: ## Run the full pipeline (all stages)
	@bash "$(ROOT)/sync.sh" $(MP)

camera: ## Import camera / SD-card photos only
	@bash "$(ROOT)/sync.sh" camera $(MP)

downloads: ## Import the downloads / inbox stage only
	@bash "$(ROOT)/sync.sh" downloads $(MP)

music: ## Import music only (FLAC + AAC, playlists)
	@bash "$(ROOT)/sync.sh" music $(MP)

movies: ## Import movies only
	@bash "$(ROOT)/sync.sh" movies $(MP)

tv: ## Import TV shows only
	@bash "$(ROOT)/sync.sh" tv $(MP)

photos: ## Import photos only
	@bash "$(ROOT)/sync.sh" photos $(MP)

playlist: ## Regenerate per-album / per-artist M3U8 playlists (both tiers)
	@$(MP) bash -c 'source "$(ROOT)/config.sh"; source "$(ROOT)/playlist.sh"; \
		generate_music_playlists "$$DESKTOP_MUSIC_ROOT"  flac; \
		generate_music_playlists "$$PORTABLE_MUSIC_ROOT" m4a'

# ---- Backup / transfer -----------------------------------------------------
backup: ## Backup a library tree: make backup SRC=<dir> DEST=<dir> [LABEL=..] [MODE=move|export]
	@[[ -n "$(SRC)"  ]] || { echo "[ERROR] SRC=<sourceDir> is required" >&2; exit 1; }
	@[[ -n "$(DEST)" ]] || { echo "[ERROR] DEST=<destDir> is required" >&2; exit 1; }
	@bash "$(ROOT)/backup.sh" "$(SRC)" "$(DEST)" "$(LABEL)" "$(MODE)"

transfer: ## Move/copy one file: make transfer FILE=<file> DEST=<dir> [LABEL=..] [MODE=move|export]
	@[[ -n "$(FILE)" ]] || { echo "[ERROR] FILE=<sourceFile> is required" >&2; exit 1; }
	@[[ -n "$(DEST)" ]] || { echo "[ERROR] DEST=<destDir> is required" >&2; exit 1; }
	@bash "$(ROOT)/transfer.sh" "$(FILE)" "$(DEST)" "$(LABEL)" "$(MODE)"

convert: ## Convert one file: make convert FILE=<file> TIER=desktop|portable DEST=<dir>
	@[[ -n "$(FILE)" ]] || { echo "[ERROR] FILE=<file> is required" >&2; exit 1; }
	@[[ -n "$(DEST)" ]] || { echo "[ERROR] DEST=<destDir> is required" >&2; exit 1; }
	@bash "$(ROOT)/convert.sh" "$(FILE)" "$(TIER)" "$(DEST)"

# ---- Utilities -------------------------------------------------------------
clean-raw: ## Remove paired JPEGs (when RAW exists) and TIFF artifacts from PHOTOS source
	@bash "$(ROOT)/clean.sh"

stop: ## Kill any running import / ffmpeg jobs
	@bash "$(ROOT)/sync.sh" stop
