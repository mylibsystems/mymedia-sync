import os
import shutil
import subprocess
import tempfile
import unittest

from mediasync.probe import flac_audio_ok


@unittest.skipUnless(shutil.which("flac") and shutil.which("ffmpeg"), "flac/ffmpeg not installed")
class FlacAudioOk(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.mkdtemp()
        cls.good = os.path.join(cls.tmp, "good.flac")
        subprocess.run(["ffmpeg", "-v", "error", "-f", "lavfi", "-i", "sine=frequency=440:duration=8",
                        "-c:a", "flac", cls.good], check=True)
        cls.data = open(cls.good, "rb").read()

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.tmp, ignore_errors=True)

    def write(self, name, data):
        p = os.path.join(self.tmp, name)
        with open(p, "wb") as f:
            f.write(data)
        return p

    def metadata_end(self):
        pos = 4
        while True:
            h = self.data[pos]
            pos += 4 + int.from_bytes(self.data[pos + 1:pos + 4], "big")
            if h & 0x80:
                return pos

    def test_good_file(self):
        self.assertTrue(flac_audio_ok(self.good)[0])

    def test_trailing_id3v1_tag_is_not_damage(self):
        p = self.write("tag.flac", self.data + b"TAG" + b"\0" * 125)
        self.assertTrue(flac_audio_ok(p)[0])

    def test_junk_before_first_frame_is_not_damage(self):
        end = self.metadata_end()
        p = self.write("junk.flac", self.data[:end] + b"\x81\x00\x04\x00" + b"\0" * 1024 + self.data[end:])
        self.assertTrue(flac_audio_ok(p)[0])

    def test_truncated_file_is_damage(self):
        p = self.write("cut.flac", self.data[: len(self.data) // 2])
        self.assertFalse(flac_audio_ok(p)[0])

    def test_corrupt_frame_in_the_middle_is_damage(self):
        mid = len(self.data) // 2
        p = self.write("bad.flac", self.data[:mid] + b"\xaa" * 400 + self.data[mid + 400:])
        self.assertFalse(flac_audio_ok(p)[0])


if __name__ == "__main__":
    unittest.main()
