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


@unittest.skipUnless(shutil.which("ffmpeg"), "ffmpeg not installed")
class TailDecodes(unittest.TestCase):
    def test_very_short_track_is_not_damage(self):
        from mediasync.probe import tail_decodes
        with tempfile.TemporaryDirectory() as d:
            p = os.path.join(d, "pregap.m4a")
            subprocess.run(["ffmpeg", "-v", "error", "-f", "lavfi", "-i", "sine=frequency=440:duration=0.04",
                            "-c:a", "aac", p], check=True)
            self.assertTrue(tail_decodes(p, "audio")[0])

    def test_timestamp_warnings_are_not_decode_errors(self):
        from mediasync.probe import _real_error
        warn = "[null @ 0x59598c6da140] Application provided invalid, non monotonically increasing dts to muxer in stream 0: 5 >= 5"
        self.assertEqual(_real_error(warn), "")
        self.assertTrue(_real_error("[h264 @ 0x5ece3e20ae80] error while decoding MB 114 49, bytestream -5"))


@unittest.skipUnless(shutil.which("ffmpeg"), "ffmpeg not installed")
class TailDecodesVideo(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.mkdtemp()
        cls.movie = os.path.join(cls.tmp, "movie.mp4")
        # audio (8 s) runs well past the last video frame (5 s), keyframes every 2 s, like the real movies
        subprocess.run(["ffmpeg", "-v", "error", "-f", "lavfi", "-i", "testsrc=size=320x240:rate=24:duration=5",
                        "-f", "lavfi", "-i", "sine=frequency=440:duration=8", "-c:v", "libx264", "-g", "48",
                        "-c:a", "aac", "-pix_fmt", "yuv420p", cls.movie], check=True)

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.tmp, ignore_errors=True)

    def test_audio_longer_than_video_is_not_damage(self):
        from mediasync.probe import tail_decodes
        self.assertTrue(tail_decodes(self.movie, "video")[0])

    def test_truncated_movie_is_damage(self):
        from mediasync.probe import tail_decodes
        p = os.path.join(self.tmp, "cut.mp4")
        data = open(self.movie, "rb").read()
        with open(p, "wb") as f:
            f.write(data[: len(data) * 6 // 10])
        self.assertFalse(tail_decodes(p, "video")[0])
