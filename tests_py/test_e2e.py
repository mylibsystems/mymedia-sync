"""Integration test: the real app + the real shell workers on a small throwaway "router + local disk"."""
import hashlib
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
TOOLS = ("ffmpeg", "ffprobe", "exiftool", "convert", "flac")


def tree_hash(root: Path, skip=()):
    out = {}
    for dp, _, fs in os.walk(root):
        for f in fs:
            p = Path(dp) / f
            rel = str(p.relative_to(root))
            if any(rel.startswith(s) for s in skip):
                continue
            out[rel] = hashlib.sha256(p.read_bytes()).hexdigest()
    return out


def files(root: Path, skip=()):
    out = {}
    for dp, _, fs in os.walk(root):
        for f in fs:
            p = Path(dp) / f
            rel = str(p.relative_to(root))
            if any(rel.startswith(s) for s in skip):
                continue
            st = p.stat()
            out[rel] = (st.st_size, st.st_mtime_ns, st.st_ino)
    return out


@unittest.skipUnless(all(subprocess.run(["which", t], capture_output=True).returncode == 0 for t in TOOLS),
                     "media tools not installed")
class EndToEnd(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.t = Path(tempfile.mkdtemp(prefix="mediasync_e2e_"))
        subprocess.run([str(REPO / "tests_py/make_fixture.sh"), str(cls.t)], check=True, capture_output=True)
        cls.env = dict(os.environ, MEDIASYNC_SETTINGS=str(cls.t / "settings.toml"))
        cls.router, cls.local = cls.t / "router", cls.t / "local"
        cls.sources_before = tree_hash(cls.router, skip=("LIBRARY.",))

    def run_app(self, *extra):
        r = subprocess.run([sys.executable, "-m", "mediasync", "--plain", *extra], cwd=REPO, env=self.env,
                           capture_output=True, text=True, timeout=900)
        return r

    # The tests are ordered by name so they run as one story: 1 -> 2 -> 3.
    def test_1_clean_run_builds_everything_and_never_touches_the_router(self):
        r = self.run_app()
        self.assertIn("EVERYTHING CONFIRMED COMPLETE", r.stdout, r.stdout[-1500:])
        # router sources byte-identical
        self.assertEqual(tree_hash(self.router, skip=("LIBRARY.",)), self.sources_before)
        # archive on the local disk, dated by capture date
        cam = {str(p.relative_to(self.local / "CAMERA")) for p in (self.local / "CAMERA").rglob("*") if p.is_file()}
        for rel in ("2026/10/20/IMG_1.jpg", "2026/10/20/IMG_6337.JPG", "2026/10/20/IMG_6337.MOV", "2026/10/22/NEW_1.jpg",
                    "2026/10/22/V_new.mp4", "2020/04/30/old_exif.jpg"):
            self.assertIn(rel, cam)
        d, p = self.router / "LIBRARY.DESKTOP", self.router / "LIBRARY.PORTABLE"
        for rel in ("PHOTOS/2016-10-21/old_exif.jpg",          # EXIF date differs from the archive folder
                    "PHOTOS/2026-10-20/IMG_6337.jpg", "PHOTOS/2026-10-20/IMG_6337.m4v",   # Live Photo pair
                    "PHOTOS/2026-10-22/V_new.m4v", "PHOTOS/2025-07-04/P_1.jpg",
                    "MUSIC/Artist/2020 - Album/01.01 - Song One.flac"):
            self.assertTrue((d / rel).is_file(), f"desktop missing {rel}")
        for rel in ("PHOTOS/2016-10-21/old_exif.jpg", "PHOTOS/2026-10-20/IMG_6337.jpg", "PHOTOS/2026-10-20/IMG_6337.m4v",
                    "PHOTOS/2026-10-22/V_new.m4v", "MUSIC/Artist/2020 - Album/01.01 - Song One.m4a"):
            self.assertTrue((p / rel).is_file(), f"portable missing {rel}")
        # inbox emptied of everything supported
        left = [q.name for q in (self.local / "UNSORTED").rglob("*") if q.is_file()]
        self.assertEqual(left, ["readme.txt"])
        # logs with checksums on the local disk
        self.assertIn("sha256", (self.local / "logs/manifest.csv").read_text())
        self.assertFalse(list(self.router.rglob(".media-sync-staging-*")))

    def test_2_second_run_changes_nothing(self):
        snap1 = files(self.t, skip=("local/logs", "local/.mediasync", "router.sha"))
        r = self.run_app()
        self.assertIn("EVERYTHING CONFIRMED COMPLETE", r.stdout)
        self.assertEqual(files(self.t, skip=("local/logs", "local/.mediasync", "router.sha")), snap1)

    def test_3_damage_is_detected_and_repaired_and_collisions_never_overwrite(self):
        d, p = self.router / "LIBRARY.DESKTOP", self.router / "LIBRARY.PORTABLE"
        (d / "PHOTOS/2026-10-20/IMG_1.jpg").write_bytes((d / "PHOTOS/2026-10-20/IMG_1.jpg").read_bytes()[:3000])
        (p / "PHOTOS/2026-10-20/IMG_2.jpg").write_bytes(b"")
        (p / "PHOTOS/2026-10-21/V_1.m4v").unlink()
        subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-f", "lavfi", "-i", "testsrc=size=320x240:rate=15:duration=0.5",
                        "-f", "lavfi", "-i", "sine=duration=0.5", "-shortest", str(d / "PHOTOS/2026-10-21/V_1.m4v")], check=True)
        flac = p / "MUSIC/Artist/2020 - Album/01.02 - Song Two.m4a"
        flac.write_bytes(flac.read_bytes()[:20000])
        archived = (self.local / "CAMERA/2026/10/20/IMG_1.jpg").read_bytes()
        other = self.local / "UNSORTED/CAMERA/x/IMG_1.jpg"
        other.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(["convert", "-size", "200x100", "plasma:fractal", str(other)], check=True)
        subprocess.run(["exiftool", "-q", "-overwrite_original", "-DateTimeOriginal=2026:10:20 10:01:00", str(other)], check=True)
        r = self.run_app()
        self.assertIn("EVERYTHING CONFIRMED COMPLETE", r.stdout, r.stdout[-2500:])
        self.assertEqual((self.local / "CAMERA/2026/10/20/IMG_1.jpg").read_bytes(), archived)       # never overwritten
        self.assertTrue((self.local / "CAMERA/2026/10/20/IMG_1_1.jpg").is_file())
        coll = (self.local / "logs/collisions.csv").read_text()
        self.assertIn("2026/10/20/IMG_1.jpg", coll)
        self.assertGreater(len((self.local / "logs/collisions.csv").read_text().splitlines()), 1)
        removed = (self.local / "logs/removed-damaged.csv").read_text()
        for name in ("IMG_1.jpg", "V_1.m4v", "IMG_2.jpg", "Song Two.m4a"):
            self.assertIn(name, removed)

    def test_4_dry_run_changes_nothing(self):
        snap = files(self.t, skip=("local/logs", "local/.mediasync"))
        r = self.run_app("--dry-run")
        self.assertEqual(r.returncode, 0, r.stderr[-800:])
        self.assertEqual(files(self.t, skip=("local/logs", "local/.mediasync")), snap)


if __name__ == "__main__":
    unittest.main()
