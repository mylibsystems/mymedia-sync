import os
import shutil
import subprocess
import tempfile
import threading
import unittest
from types import SimpleNamespace

from mediasync.inventory import Verifier
from mediasync.repair import Repairer, rebuild


class FakeState:
    def load_verified(self): return {}
    def load_durations(self): return {}
    def set_verified(self, rows): pass
    def set_durations(self, rows): pass
    def drop_verified(self, path): pass


class FakeLog:
    def __init__(self): self.records = []
    def info(self, *a, **k): pass
    def warn(self, *a, **k): pass
    def error(self, *a, **k): pass
    def record(self, name, header, row): self.records.append((name, row))


class FakeGuard:
    def check_write(self, p): return p
    def remove_file(self, p): os.remove(p)


def tag(path, name):
    out = subprocess.run(["metaflac", f"--show-tag={name}", path], capture_output=True, text=True).stdout.strip()
    return out.split("=", 1)[1] if "=" in out else ""


@unittest.skipUnless(shutil.which("flac") and shutil.which("ffmpeg") and shutil.which("metaflac"), "flac tools missing")
class RepairMusic(unittest.TestCase):
    def setUp(self):
        self.t = tempfile.mkdtemp()
        t = self.t
        self.src = os.path.join(t, "card/Artist/2020 - Album")
        self.desk = os.path.join(t, "router/LIBRARY.DESKTOP/MUSIC/Artist/2020 - Album")
        self.port = os.path.join(t, "router/LIBRARY.PORTABLE/MUSIC/Artist/2020 - Album")
        for d in (self.src, self.desk, self.port, os.path.join(t, "local/logs")):
            os.makedirs(d)
        good = os.path.join(self.src, "1.01 - Song.flac")
        subprocess.run(["ffmpeg", "-v", "error", "-f", "lavfi", "-i", "sine=frequency=440:duration=8", "-c:a", "flac",
                        "-metadata", "TITLE=Song", "-metadata", "ARTIST=Artist", "-metadata", "ALBUM=Album", good], check=True)
        self.good_bytes = open(good, "rb").read()
        # library copy: other tag text, audio cut off half way, header still claims the full length
        lib = os.path.join(self.desk, "01.01 - Song.flac")
        shutil.copy(good, lib)
        subprocess.run(["metaflac", "--remove-tag=TITLE", "--set-tag=TITLE=Library Title", lib], check=True)
        data = open(lib, "rb").read()
        with open(lib, "wb") as f:
            f.write(data[: len(data) * 6 // 10])
        self.damaged = open(lib, "rb").read()
        # a second damaged file with no source anywhere
        lone = os.path.join(self.desk, "01.02 - Other.flac")
        other = os.path.join(t, "other.flac")
        subprocess.run(["ffmpeg", "-v", "error", "-f", "lavfi", "-i", "sine=frequency=880:duration=8", "-c:a", "flac", other],
                       check=True)
        odata = open(other, "rb").read()
        with open(lone, "wb") as f:
            f.write(odata[: len(odata) * 6 // 10])
        open(os.path.join(self.port, "01.01 - Song.m4a"), "wb").write(b"portable made from the damaged file")
        s = SimpleNamespace(
            logs=os.path.join(t, "local/logs"), local_root=os.path.join(t, "local"),
            repair_music_sources=(os.path.join(t, "card"),),
            desktop=lambda kind: os.path.join(t, "router/LIBRARY.DESKTOP", kind),
            portable=lambda kind: os.path.join(t, "router/LIBRARY.PORTABLE", kind))
        self.settings, self.log = s, FakeLog()
        self.rep = Repairer(s, self.log, FakeGuard(), Verifier(FakeState(), self.log, deep_all=True), threading.Event())

    def tearDown(self):
        shutil.rmtree(self.t, ignore_errors=True)

    def test_damaged_file_is_repaired_keeping_its_own_tags(self):
        counts = self.rep.run()
        self.assertEqual(counts.get("repaired"), 1, counts)
        self.assertEqual(counts.get("no source copy"), 1, counts)
        fixed = os.path.join(self.desk, "01.01 - Song.flac")
        self.assertEqual(subprocess.run(["flac", "-t", "-s", fixed]).returncode, 0)
        self.assertEqual(tag(fixed, "TITLE"), "Library Title")           # the library's tag, not the source's
        self.assertEqual(tag(fixed, "ARTIST"), "Artist")
        backup = os.path.join(self.t, "local/repair-backup/Artist/2020 - Album/01.01 - Song.flac")
        self.assertEqual(open(backup, "rb").read(), self.damaged)         # original saved first
        self.assertFalse(os.path.exists(os.path.join(self.port, "01.01 - Song.m4a")))   # rebuilt from the healthy file
        self.assertTrue(os.path.exists(os.path.join(self.src, "1.01 - Song.flac")))     # source untouched
        self.assertEqual(open(os.path.join(self.src, "1.01 - Song.flac"), "rb").read(), self.good_bytes)
        self.assertTrue(any(n == "repair-music.csv" for n, _ in self.log.records))

    def test_a_damaged_source_is_never_used(self):
        src = os.path.join(self.src, "1.01 - Song.flac")
        with open(src, "wb") as f:
            f.write(self.damaged)
        counts = Repairer(self.settings, self.log, FakeGuard(), Verifier(FakeState(), self.log, deep_all=True),
                          threading.Event()).run()
        self.assertEqual(counts.get("source copy is damaged too"), 1, counts)
        self.assertEqual(open(os.path.join(self.desk, "01.01 - Song.flac"), "rb").read(), self.damaged)

    def test_without_a_source_folder_nothing_changes(self):
        self.settings.repair_music_sources = (os.path.join(self.t, "not-mounted"),)
        counts = Repairer(self.settings, self.log, FakeGuard(), Verifier(FakeState(), self.log, deep_all=True),
                          threading.Event()).run()
        self.assertEqual(counts, {})
        self.assertEqual(open(os.path.join(self.desk, "01.01 - Song.flac"), "rb").read(), self.damaged)

    def test_rebuild_uses_source_tags_when_library_header_is_unreadable(self):
        out = rebuild(b"garbage" * 100, self.good_bytes)
        self.assertIsNotNone(out)
        self.assertIn("taken from the source", out[1])


if __name__ == "__main__":
    unittest.main()
