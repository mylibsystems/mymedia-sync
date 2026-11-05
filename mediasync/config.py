"""Settings (settings.toml + environment) and the derived folder layout."""
from __future__ import annotations

import os
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path

try:
    import tomllib
except ImportError:  # Python < 3.11
    tomllib = None

REPO = Path(__file__).resolve().parent.parent
SOURCE_TYPES = ("CAMERA", "DOWNLOADS", "MUSIC", "MOVIES", "TV", "PHOTOS", "VIDEO")
LIBRARY_TYPES = ("MUSIC", "MOVIES", "TV", "PHOTOS")

DEFAULTS = {
    "paths": {"local_root": "", "router_root": "/mnt/router-smb"},
    "ingest": {"enabled": True, "from_root": "", "verify": True, "streams": 3},
    "run": {"workers": 0, "video_workers": 2, "retry": 1, "deep_verify": False},
    "safety": {"allow_router_inputs": False},
    "repair": {"enabled": True, "music_sources": []},
}


def _parse_flat_toml(text: str) -> dict:
    """Minimal TOML subset (sections, strings, ints, bools) for Python < 3.11."""
    out: dict = {}
    cur = out
    for raw in text.splitlines():
        line = raw.split("#", 1)[0].strip() if '"' not in raw else raw.strip()
        if not line:
            continue
        if line.startswith("[") and line.endswith("]"):
            cur = out.setdefault(line[1:-1].strip(), {})
            continue
        if "=" not in line:
            continue
        key, val = (x.strip() for x in line.split("=", 1))
        if val.startswith("["):
            val = re.findall(r'"([^"]*)"', val)
        elif val.startswith('"'):
            val = val[1: val.rfind('"')]
        elif val.lower() in ("true", "false"):
            val = val.lower() == "true"
        else:
            try:
                val = int(val)
            except ValueError:
                pass
        cur[key] = val
    return out


def _load_toml(path: Path) -> dict:
    data = path.read_bytes()
    if tomllib is not None:
        return tomllib.loads(data.decode("utf-8"))
    return _parse_flat_toml(data.decode("utf-8"))


@dataclass
class Settings:
    local_root: Path | None
    router_root: Path
    ingest_enabled: bool
    ingest_from: Path
    ingest_verify: bool
    ingest_streams: int
    workers: int
    video_workers: int
    retry: int
    deep_verify: bool
    allow_router_inputs: bool
    repair_enabled: bool = True
    repair_music_sources: tuple = ()
    repo: Path = REPO
    settings_file: Path | None = None

    # ---- derived layout -------------------------------------------------
    @property
    def inputs_on_router(self) -> bool:
        return self.local_root is None

    @property
    def inputs_root(self) -> Path:
        return self.local_root if self.local_root else self.router_root

    @property
    def unsorted(self) -> Path:
        return self.inputs_root / "UNSORTED"

    @property
    def camera(self) -> Path:
        return self.inputs_root / "CAMERA"

    @property
    def logs(self) -> Path:
        return (self.local_root / "logs") if self.local_root else (self.repo / "logs")

    @property
    def staging(self) -> Path:
        return (self.local_root / ".mediasync-staging") if self.local_root else Path("/tmp/mediasync-staging")

    @property
    def desktop_root(self) -> Path:
        return self.router_root / "LIBRARY.DESKTOP"

    @property
    def portable_root(self) -> Path:
        return self.router_root / "LIBRARY.PORTABLE"

    def source_dir(self, kind: str) -> Path:
        return self.unsorted / kind

    def desktop(self, kind: str) -> Path:
        return self.desktop_root / kind

    def portable(self, kind: str) -> Path:
        return self.portable_root / kind

    @property
    def n_workers(self) -> int:
        return self.workers if self.workers > 0 else max(1, os.cpu_count() or 2)

    # ---- engine (bash workers) environment ------------------------------
    def engine_env(self, extra: dict | None = None) -> dict:
        """Environment for the shell workers; points them at the same folders."""
        env = dict(os.environ)
        env.update({
            "MEDIA_PATH": str(self.router_root),
            "UNSORTED_ROOT": str(self.unsorted),
            "DESKTOP_MUSIC_ROOT": str(self.desktop("MUSIC")),
            "DESKTOP_MOVIES_ROOT": str(self.desktop("MOVIES")),
            "DESKTOP_TV_ROOT": str(self.desktop("TV")),
            "DESKTOP_PHOTOS_ROOT": str(self.desktop("PHOTOS")),
            "DESKTOP_CAMERA_ROOT": str(self.camera),
            "PORTABLE_MUSIC_ROOT": str(self.portable("MUSIC")),
            "PORTABLE_MOVIES_ROOT": str(self.portable("MOVIES")),
            "PORTABLE_TV_ROOT": str(self.portable("TV")),
            "PORTABLE_PHOTOS_ROOT": str(self.portable("PHOTOS")),
            "STAGING_ROOT": str(self.staging),
            "LOG_DIR": str(self.logs / "engine"),
            "CAMERA_INDEX_FILE": str(self.logs / "camera-built.tsv"),
            "DEGRADED_LOG": str(self.logs / "camera-degraded.tsv"),
            "BUILD_PROGRESS_FILE": str(self.logs / ".camera-build-progress"),
            "DELETE_AFTER_IMPORT": "1",
            "SYNC_AUTOTEE": "0",
            "MEDIASYNC_DIRS_READY": "1",          # the app creates the folders once; workers skip mkdir
            "MAX_PARALLEL_JOBS": str(self.n_workers),
            "TMPDIR": str(self.staging / "tmp"),
        })
        if extra:
            env.update({k: str(v) for k, v in extra.items()})
        return env


def load(path: str | os.PathLike | None = None) -> Settings:
    """Load settings.toml (path, $MEDIASYNC_SETTINGS or <repo>/settings.toml)."""
    cfg = {sec: dict(vals) for sec, vals in DEFAULTS.items()}
    sf = Path(path or os.environ.get("MEDIASYNC_SETTINGS") or REPO / "settings.toml")
    used = None
    if sf.is_file():
        for sec, vals in _load_toml(sf).items():
            if isinstance(vals, dict):
                cfg.setdefault(sec, {}).update(vals)
        used = sf
    p, ing, run, saf = cfg["paths"], cfg["ingest"], cfg["run"], cfg["safety"]
    rep = cfg.get("repair", {})
    srcs = rep.get("music_sources") or []
    if isinstance(srcs, str):
        srcs = [srcs]
    local = str(p.get("local_root") or "").strip()
    router = Path(str(p.get("router_root") or "/mnt/router-smb"))
    from_root = str(ing.get("from_root") or "").strip()
    return Settings(
        local_root=Path(local) if local else None,
        router_root=router,
        ingest_enabled=bool(ing.get("enabled", True)),
        ingest_from=Path(from_root) if from_root else router,
        ingest_verify=bool(ing.get("verify", True)),
        ingest_streams=max(1, int(ing.get("streams", 3))),
        workers=int(run.get("workers", 0)),
        video_workers=max(1, int(run.get("video_workers", 2))),
        retry=max(0, int(run.get("retry", 1))),
        deep_verify=bool(run.get("deep_verify", False)),
        allow_router_inputs=bool(saf.get("allow_router_inputs", False)),
        repair_enabled=bool(rep.get("enabled", True)),
        repair_music_sources=tuple(str(x) for x in srcs if str(x).strip()),
        settings_file=used,
    )


def validate(s: Settings) -> list[str]:
    """Return a list of blocking problems (empty list = good to run)."""
    problems: list[str] = []
    if s.inputs_on_router and not s.allow_router_inputs:
        problems.append(
            "No local disk configured: set [paths] local_root in settings.toml "
            "(inputs CAMERA/UNSORTED must live on the fast local disk; the router copy "
            "is never modified). To work directly on the router anyway, set "
            "[safety] allow_router_inputs = true.")
    for label, path in (("desktop library", s.desktop_root), ("portable library", s.portable_root)):
        if not path.is_dir():
            problems.append(f"{label} is not available: {path} (is the router share mounted?)")
    if s.local_root is not None and not s.local_root.is_dir():
        problems.append(f"local_root does not exist: {s.local_root} (is the disk mounted?)")
    return problems


if __name__ == "__main__":  # quick manual check
    st = load()
    print(st)
    print("\n".join(validate(st)) or "settings OK", file=sys.stderr)
