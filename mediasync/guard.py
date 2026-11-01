"""Safety rules for every filesystem change made by Python.

* The camera library is PROTECTED: nothing in it is ever deleted, overwritten or
  renamed — new files can only be added under a name that does not exist yet.
* The router copies (ingest source) are READ-ONLY for this program.
* Deleting is only possible inside the local UNSORTED inbox (never the top-level
  type folders), the staging area, and library output folders (damaged outputs).
"""
from __future__ import annotations

import os
from pathlib import Path


class ProtectedPathError(PermissionError):
    """Raised instead of touching a path the rules forbid."""


def _real(p: os.PathLike | str) -> Path:
    return Path(os.path.realpath(os.fspath(p)))


def _inside(path: Path, root: Path) -> bool:
    return path == root or root in path.parents


class Guard:
    def __init__(self, *, camera: Path, unsorted: Path, protected=(), readonly=(), delete_roots=(),
                 types=("CAMERA", "DOWNLOADS", "MUSIC", "MOVIES", "TV", "PHOTOS", "VIDEO")):
        self.camera = _real(camera)
        self.unsorted = _real(unsorted)
        self.protected = [self.camera] + [_real(p) for p in protected]
        self.readonly = [_real(p) for p in readonly]
        self.delete_roots = [self.unsorted] + [_real(p) for p in delete_roots]
        self.type_dirs = {self.unsorted / t for t in types}

    # ---- checks ---------------------------------------------------------
    def _deny_if_protected(self, rp: Path, what: str) -> None:
        for root in self.protected:
            if _inside(rp, root):
                raise ProtectedPathError(f"camera library is protected: cannot {what} {rp}")
        for root in self.readonly:
            if _inside(rp, root):
                raise ProtectedPathError(f"router copy is read-only: cannot {what} {rp}")

    def check_delete(self, path) -> Path:
        rp = _real(path)
        self._deny_if_protected(rp, "delete")
        if rp in self.type_dirs:
            raise ProtectedPathError(f"top-level source folder is protected: {rp}")
        if not any(_inside(rp, r) for r in self.delete_roots):
            raise ProtectedPathError(f"not inside a folder this program may delete from: {rp}")
        return rp

    def check_write(self, path) -> Path:
        """Create/modify check for non-camera targets (local inbox, staging, logs, libraries)."""
        rp = _real(path)
        self._deny_if_protected(rp, "write")
        return rp

    def check_camera_add(self, dst) -> Path:
        """Adding a NEW file to the camera library: must be inside it and must not exist."""
        rp = _real(dst)
        if not _inside(rp, self.camera) or rp == self.camera:
            raise ProtectedPathError(f"not a path inside the camera library: {rp}")
        if os.path.lexists(rp):
            raise ProtectedPathError(f"camera library never overwrites: {rp} already exists")
        return rp

    # ---- operations -----------------------------------------------------
    def remove_file(self, path) -> None:
        rp = self.check_delete(path)
        os.unlink(rp)

    def remove_empty_dir(self, path) -> bool:
        rp = self.check_delete(path)
        try:
            os.rmdir(rp)
            return True
        except OSError:
            return False

    def move_into_camera(self, src, dst) -> None:
        """Move a file from the inbox into the camera library without ever overwriting."""
        self.check_delete(src)
        self.check_camera_add(dst)
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        if os.path.lexists(dst):
            raise ProtectedPathError(f"camera library never overwrites: {dst}")
        os.rename(src, dst)   # same filesystem; destination was verified not to exist

    def new_file_in_camera(self, dst) -> Path:
        """Reserve a destination for a copy; caller writes a temp file then calls publish_camera_file."""
        return self.check_camera_add(dst)

    def publish_camera_file(self, tmp, dst) -> None:
        """Atomically publish a finished temp file (inside the camera library) as dst."""
        self.check_camera_add(dst)
        rt = _real(tmp)
        if not _inside(rt, self.camera):
            raise ProtectedPathError(f"temp file must live inside the camera library: {rt}")
        if os.path.lexists(dst):
            raise ProtectedPathError(f"camera library never overwrites: {dst}")
        os.rename(tmp, dst)

    def remove_temp_in_camera(self, tmp) -> None:
        """Remove OUR OWN unfinished temp file (named .*.partial-*) from the camera library."""
        rt = _real(tmp)
        name = rt.name
        if _inside(rt, self.camera) and name.startswith(".") and ".partial-" in name:
            try:
                os.unlink(rt)
            except FileNotFoundError:
                pass
            return
        raise ProtectedPathError(f"refusing to delete non-temp file in camera library: {rt}")
