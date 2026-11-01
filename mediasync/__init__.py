"""mediasync — one CLI app that orchestrates the MyMedia pipeline.

The encoders themselves (ffmpeg / ImageMagick / exiftool / flac / AtomicParsley
command lines) are NOT reimplemented here: the proven shell workers
(orginize.sh, portablize.sh, convert.sh, metadata.sh) keep running them
unchanged. This package decides what has to run, verifies every result, keeps
the camera archive protected and shows the progress.
"""

__version__ = "1.0.0"
