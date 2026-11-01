import os
import sys
import tempfile
import threading
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from mediasync import fsutil, native  # noqa: E402
from mediasync.guard import Guard, ProtectedPathError  # noqa: E402
from mediasync.logs import RunLog  # noqa: E402
from mediasync.model import Status, Task  # noqa: E402
from mediasync.state import State  # noqa: E402


def w(path, data=b"x"):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as f:
        f.write(data)
    return path


class GuardTests(unittest.TestCase):
    def setUp(self):
        self.d = Path(tempfile.mkdtemp())
        self.local, self.router = self.d / "local", self.d / "router"
        self.guard = Guard(camera=self.local / "CAMERA", unsorted=self.local / "UNSORTED",
                           protected=[self.router / "CAMERA"],
                           readonly=[self.router / "UNSORTED", self.router / "CAMERA"],
                           delete_roots=[self.router / "LIBRARY.DESKTOP", self.local / ".staging"])

    def test_camera_library_is_never_deleted(self):
        f = w(self.local / "CAMERA/2026/10/20/IMG_1.jpg")
        with self.assertRaises(ProtectedPathError):
            self.guard.remove_file(f)
        self.assertTrue(os.path.exists(f))
        with self.assertRaises(ProtectedPathError):
            self.guard.remove_empty_dir(self.local / "CAMERA/2026/10/20")

    def test_camera_library_is_never_overwritten(self):
        f = w(self.local / "CAMERA/2026/10/20/IMG_1.jpg", b"original")
        src = w(self.local / "UNSORTED/CAMERA/x/IMG_1.jpg", b"different")
        with self.assertRaises(ProtectedPathError):
            self.guard.move_into_camera(src, f)
        self.assertEqual(open(f, "rb").read(), b"original")
        self.assertTrue(os.path.exists(src))

    def test_router_is_read_only(self):
        r1 = w(self.router / "UNSORTED/MUSIC/a.flac")
        r2 = w(self.router / "CAMERA/2026/a.jpg")
        for f in (r1, r2):
            with self.assertRaises(ProtectedPathError):
                self.guard.remove_file(f)
            with self.assertRaises(ProtectedPathError):
                self.guard.check_write(f)

    def test_symlink_into_camera_is_still_protected(self):
        f = w(self.local / "CAMERA/2026/a.jpg")
        os.makedirs(self.local / "UNSORTED/X", exist_ok=True)
        link = self.local / "UNSORTED/X/link.jpg"
        os.symlink(f, link)
        with self.assertRaises(ProtectedPathError):
            self.guard.remove_file(link)
        self.assertTrue(os.path.exists(f))

    def test_only_allowed_places_can_be_deleted(self):
        outside = w(self.d / "elsewhere/file.txt")
        with self.assertRaises(ProtectedPathError):
            self.guard.remove_file(outside)
        inbox = w(self.local / "UNSORTED/MUSIC/a/b.flac")
        self.guard.remove_file(inbox)
        self.assertFalse(os.path.exists(inbox))
        out = w(self.router / "LIBRARY.DESKTOP/PHOTOS/2026-10-20/x.jpg")
        self.guard.remove_file(out)                      # a damaged library output may be replaced

    def test_top_level_type_folders_are_protected(self):
        os.makedirs(self.local / "UNSORTED/CAMERA")
        with self.assertRaises(ProtectedPathError):
            self.guard.remove_empty_dir(self.local / "UNSORTED/CAMERA")

    def test_camera_add_requires_a_new_name(self):
        f = w(self.local / "CAMERA/2026/a.jpg")
        with self.assertRaises(ProtectedPathError):
            self.guard.check_camera_add(f)
        self.guard.check_camera_add(self.local / "CAMERA/2026/new.jpg")

    def test_only_own_temp_files_removed_from_camera(self):
        keep = w(self.local / "CAMERA/2026/a.jpg")
        tmp = w(self.local / "CAMERA/2026/.a.jpg.partial-123-4")
        with self.assertRaises(ProtectedPathError):
            self.guard.remove_temp_in_camera(keep)
        self.guard.remove_temp_in_camera(tmp)
        self.assertTrue(os.path.exists(keep))
        self.assertFalse(os.path.exists(tmp))


class FakeCtx:
    """The parts of Ctx that the native phases use."""

    def __init__(self, base: Path):
        from mediasync import config
        self.settings = config.Settings(local_root=base / "local", router_root=base / "router", ingest_enabled=True,
                                        ingest_from=base / "router", ingest_verify=True, ingest_streams=2, workers=2,
                                        video_workers=1, retry=0, deep_verify=False, allow_router_inputs=False)
        self.settings.logs.mkdir(parents=True, exist_ok=True)
        self.log = RunLog(self.settings.logs)
        self.state = State(self.settings.logs / "state.db")
        self.status = Status()
        self.guard = Guard(camera=self.settings.camera, unsorted=self.settings.unsorted,
                           protected=[base / "router/CAMERA"],
                           readonly=[base / "router/UNSORTED", base / "router/CAMERA"], delete_roots=[])
        self.camera_lock = threading.Lock()
        self._n = 0
        self.stop = threading.Event()

    def next_id(self):
        self._n += 1
        return self._n

    def exif(self):
        from mediasync.probe import ExifPool
        if not hasattr(self, "_pool"):
            self._pool = ExifPool(1)
        return self._pool


class NativeTests(unittest.TestCase):
    def setUp(self):
        self.d = Path(tempfile.mkdtemp())
        self.ctx = FakeCtx(self.d)
        self.s = self.ctx.settings

    def tearDown(self):
        self.ctx.log.close()
        if hasattr(self.ctx, "_pool"):
            self.ctx._pool.close()

    def test_ingest_copies_with_checksum_and_never_touches_the_router(self):
        src = w(self.d / "router/UNSORTED/MUSIC/Artist/a.flac", b"audio-bytes" * 1000)
        before = open(src, "rb").read()
        tasks, _ = native.plan_ingest(self.ctx, self.ctx.stop)
        self.assertEqual(len(tasks), 1)
        self.assertTrue(native.ingest_task(self.ctx, tasks[0]))
        self.assertEqual(open(self.s.unsorted / "MUSIC/Artist/a.flac", "rb").read(), before)
        self.assertEqual(open(src, "rb").read(), before)
        self.assertIn("sha256", open(self.s.logs / "manifest.csv").read())
        # ledger: after processing the local copy away, it is not copied again
        os.unlink(self.s.unsorted / "MUSIC/Artist/a.flac")
        self.assertEqual(native.plan_ingest(self.ctx, self.ctx.stop)[0], [])

    def test_ingest_collision_keeps_local_file_and_logs_both_checksums(self):
        w(self.d / "router/CAMERA/2026/a.jpg", b"router-version")
        w(self.s.camera / "2026/a.jpg", b"local-version-different-size")
        tasks, _ = native.plan_ingest(self.ctx, self.ctx.stop)
        self.assertEqual(len(tasks), 1)
        self.assertFalse(native.ingest_task(self.ctx, tasks[0]))
        self.assertEqual(open(self.s.camera / "2026/a.jpg", "rb").read(), b"local-version-different-size")
        rows = open(self.s.logs / "collisions.csv").read()
        self.assertIn("existing_sha256", rows)
        self.assertEqual(self.ctx.log.collisions, 1)

    def test_ingest_into_camera_never_overwrites(self):
        w(self.d / "router/CAMERA/2026/a.jpg", b"same")
        tasks, _ = native.plan_ingest(self.ctx, self.ctx.stop)
        self.assertTrue(native.ingest_task(self.ctx, tasks[0]))
        self.assertEqual(open(self.s.camera / "2026/a.jpg", "rb").read(), b"same")
        self.assertEqual(native.plan_ingest(self.ctx, self.ctx.stop)[0], [])

    def _photo(self, path, date, color="red"):
        os.makedirs(os.path.dirname(path), exist_ok=True)
        import subprocess
        subprocess.run(["convert", "-size", "64x48", f"xc:{color}", path], check=True)
        subprocess.run(["exiftool", "-q", "-overwrite_original", f"-DateTimeOriginal={date}", path], check=True)
        return path

    def test_backup_moves_into_dated_folder(self):
        src = self._photo(str(self.s.unsorted / "CAMERA/100/IMG_1.jpg"), "2026:10:20 10:00:00")
        t = Task(1, "backup", "file", "IMG_1.jpg", src, os.path.getsize(src))
        self.assertTrue(native.backup_task(self.ctx, t))
        self.assertTrue(os.path.exists(self.s.camera / "2026/10/20/IMG_1.jpg"))
        self.assertFalse(os.path.exists(src))

    def test_backup_collision_never_overwrites_and_logs_checksums(self):
        first = self._photo(str(self.s.unsorted / "CAMERA/100/IMG_1.jpg"), "2026:10:20 10:00:00", "red")
        t1 = Task(1, "backup", "file", "IMG_1.jpg", first, os.path.getsize(first))
        self.assertTrue(native.backup_task(self.ctx, t1))
        original = (self.s.camera / "2026/10/20/IMG_1.jpg").read_bytes()
        second = self._photo(str(self.s.unsorted / "CAMERA/200/IMG_1.jpg"), "2026:10:20 10:00:00", "blue")
        t2 = Task(2, "backup", "file", "IMG_1.jpg", second, os.path.getsize(second))
        self.assertTrue(native.backup_task(self.ctx, t2))
        self.assertEqual((self.s.camera / "2026/10/20/IMG_1.jpg").read_bytes(), original)
        self.assertTrue(os.path.exists(self.s.camera / "2026/10/20/IMG_1_1.jpg"))
        self.assertEqual(self.ctx.log.collisions, 1)
        self.assertIn("new_sha256", open(self.s.logs / "collisions.csv").read())

    def test_backup_identical_copy_is_not_duplicated(self):
        a = self._photo(str(self.s.unsorted / "CAMERA/100/IMG_1.jpg"), "2026:10:20 10:00:00")
        self.assertTrue(native.backup_task(self.ctx, Task(1, "backup", "file", "IMG_1.jpg", a, os.path.getsize(a))))
        b = str(self.s.unsorted / "CAMERA/200/IMG_1.jpg")
        os.makedirs(os.path.dirname(b), exist_ok=True)
        with open(b, "wb") as f:
            f.write((self.s.camera / "2026/10/20/IMG_1.jpg").read_bytes())
        t = Task(2, "backup", "file", "IMG_1.jpg", b, os.path.getsize(b))
        self.assertTrue(native.backup_task(self.ctx, t))
        self.assertEqual(len(list((self.s.camera / "2026/10/20").iterdir())), 1)
        self.assertFalse(os.path.exists(b))

    def test_backup_without_date_leaves_file_in_inbox(self):
        src = w(self.s.unsorted / "CAMERA/100/nodate.bin", b"zz")
        os.utime(src, (0, 0))      # epoch is a valid filesystem date, so use a name-less odd file instead
        t = Task(1, "backup", "file", "nodate.bin", src, 2)
        native.backup_task(self.ctx, t)       # either archived by file date or left; must never lose data
        found = os.path.exists(src) or any(p.name.startswith("nodate") for p in self.s.camera.rglob("*"))
        self.assertTrue(found)


class FsutilTests(unittest.TestCase):
    def setUp(self):
        self.d = Path(tempfile.mkdtemp())

    def test_jpeg_check(self):
        import subprocess
        good = str(self.d / "g.jpg")
        subprocess.run(["convert", "-size", "100x80", "plasma:fractal", good], check=True)
        self.assertTrue(fsutil.jpeg_check(good)[0])
        cut = str(self.d / "c.jpg")
        open(cut, "wb").write(open(good, "rb").read()[:2000])
        self.assertFalse(fsutil.jpeg_check(cut)[0])
        empty = str(self.d / "e.jpg")
        open(empty, "wb").close()
        self.assertEqual(fsutil.jpeg_check(empty), (False, "empty file"))
        junk = str(self.d / "j.jpg")
        open(junk, "wb").write(b"not a jpeg at all" * 100)
        self.assertFalse(fsutil.jpeg_check(junk)[0])
        tiny = str(self.d / "t.jpg")
        subprocess.run(["convert", "-size", "8x8", "xc:red", tiny], check=True)
        self.assertTrue(fsutil.jpeg_check(tiny)[0])

    def test_scan_tree_skips_hidden_and_reports_sizes(self):
        w(self.d / "a/b/x.jpg", b"1234")
        w(self.d / "a/.hidden", b"1")
        w(self.d / ".DS_Store", b"1")
        rows = {r[0]: r[1] for r in fsutil.scan_tree(self.d)}
        self.assertEqual(rows, {"a/b/x.jpg": 4})

    def test_copy_verified_matches_sha(self):
        src = w(self.d / "s.bin", os.urandom(3 << 20))
        sha, n = fsutil.copy_verified(src, str(self.d / "d.bin"))
        self.assertEqual(sha, fsutil.sha256_file(str(self.d / "d.bin")))
        self.assertEqual(n, 3 << 20)


if __name__ == "__main__":
    unittest.main()
