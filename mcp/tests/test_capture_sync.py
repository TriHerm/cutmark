"""Capture timing is metadata, not a promise of composite or audio synchronization."""
import json
import os
import shutil
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import cutmark_mcp as t  # noqa: E402


class CaptureSyncTests(unittest.TestCase):
    def setUp(self):
        self.top = tempfile.mkdtemp(prefix="cutmark-sync-")
        os.environ["CUTMARK_ROOT"] = self.top
        self.session = os.path.join(self.top, "Demo", "2026-10-23-paired")
        os.makedirs(self.session)

    def tearDown(self):
        os.environ.pop("CUTMARK_ROOT", None)
        shutil.rmtree(self.top)

    @staticmethod
    def take(kind, host, quality="videoFrame", number=1):
        return {"number": number, "kind": kind, "file": "take-01-%s.mov" % kind,
                "startedAt": "2026-10-23T07:01:02.123Z", "duration": 5.0,
                "captureHostTime": host, "timingQuality": quality}

    def test_signed_screen_start_offsets_use_host_clock_not_rounded_dates(self):
        camera = self.take("camera", 1000.25)
        screen = self.take("screen", 1000.437)
        self.assertAlmostEqual(t.paired_video_start_offset(camera, screen), 0.187)
        camera["startedAt"] = screen["startedAt"]  # Same wall-clock spelling is irrelevant.
        self.assertAlmostEqual(t.paired_video_start_offset(camera, screen), 0.187)
        screen["captureHostTime"] = 1000.08
        self.assertAlmostEqual(t.paired_video_start_offset(camera, screen), -0.17)

    def test_unknown_legacy_fallback_and_mismatched_takes_are_not_labeled_synced(self):
        camera = self.take("camera", 101.0)
        screen = self.take("screen", 101.2)
        for key in ("captureHostTime", "timingQuality"):
            old = dict(camera)
            old.pop(key)
            self.assertIsNone(t.paired_video_start_offset(old, screen))
        self.assertIsNone(t.paired_video_start_offset(camera, self.take("screen", 101.2, number=2)))
        self.assertIsNone(t.paired_video_start_offset(camera, self.take("screen", 101.2, "callback")))
        self.assertIsNone(t.paired_video_start_offset(camera, None))
        self.assertIsNone(t.paired_video_start_offset(None, screen))

    def test_nonfinite_crossboot_and_boolean_times_are_rejected(self):
        camera = self.take("camera", 1000.0)
        for invalid in (True, False, None, "1000.2", float("nan"), float("inf"), -1, 100.0):
            self.assertIsNone(t.paired_video_start_offset(camera, self.take("screen", invalid)))

    def test_session_manifest_discloses_only_verifiable_frame_start_difference(self):
        camera, screen = self.take("camera", 200.55), self.take("screen", 200.31)
        meta = {"title": "Paired", "createdAt": "2026-10-23T07:00:00Z", "takes": [camera, screen]}
        t.write_meta(self.session, meta)
        with open(os.path.join(self.session, "SESSION.md")) as f:
            summary = f.read()
        self.assertIn("-0.240s", summary)
        self.assertIn("not proof of audio sync", summary)
        with open(os.path.join(self.session, "session.json")) as f:
            persisted = json.load(f)
        self.assertEqual(persisted["takes"], [camera, screen])
        meta["takes"][0].pop("captureHostTime")
        t.write_meta(self.session, meta)
        with open(os.path.join(self.session, "SESSION.md")) as f:
            self.assertNotIn("-0.240s", f.read())

    def test_iso_parser_reads_old_and_fractional_timestamp_formats(self):
        old = t.parse_iso("2026-10-23T07:01:02Z")
        precise = t.parse_iso("2026-10-23T07:01:02.123Z")
        self.assertEqual((precise - old).total_seconds(), 0.123)
        self.assertIsNone(t.parse_iso("broken"))


if __name__ == "__main__":
    unittest.main()
