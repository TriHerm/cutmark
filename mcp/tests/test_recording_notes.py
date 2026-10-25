"""Recording guides are separate from scripts and survive session moves."""
import json
import os
from pathlib import Path
import shutil
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import cutmark_mcp as t


class RecordingNotesTests(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.mkdtemp()
        self.env = patch.dict(os.environ, {"CUTMARK_ROOT": self.root})
        self.env.start()
        self.rules = patch.object(t, "need_rules")
        self.need_rules = self.rules.start()
        self.s = Path(self.root) / "Project" / "2026-10-24-demo"
        self.s.mkdir(parents=True)
        (self.s / "session.json").write_text(json.dumps({"title": "Demo", "createdAt": "2026-10-24T08:00:00Z", "takes": []}))
        (self.s / "script.md").write_text("Spoken script")

    def tearDown(self):
        self.rules.stop()
        self.env.stop()
        shutil.rmtree(self.root)

    def test_notes_round_trip_without_changing_script(self):
        text = "Opening\nAn example\n\n¿Y después?\nThe next step"
        t.t_update_session({"session": str(self.s), "recording_notes": text})
        self.need_rules.assert_called_once_with("script")
        self.assertEqual((self.s / t.RECORDING_NOTES).read_text(), text)
        self.assertEqual(t.t_get_session({"session": str(self.s)})["recording_notes"], text)
        self.assertEqual((self.s / "script.md").read_text(), "Spoken script")
        self.assertEqual(list(self.s.glob(".recording-notes-*")), [])

    def test_old_session_has_empty_notes_without_creating_file(self):
        self.assertEqual(t.t_get_session({"session": str(self.s)})["recording_notes"], "")
        self.assertFalse((self.s / t.RECORDING_NOTES).exists())

    def test_notes_follow_rename_and_can_be_cleared(self):
        out = t.t_update_session({"session": str(self.s), "title": "New title", "recording_notes": "Opening"})
        moved = Path(out["path"])
        self.assertEqual((moved / t.RECORDING_NOTES).read_text(), "Opening")
        t.t_update_session({"session": str(moved), "recording_notes": ""})
        self.assertEqual((moved / t.RECORDING_NOTES).read_text(), "")

    def test_bad_notes_are_not_replaced(self):
        file = self.s / t.RECORDING_NOTES
        file.write_bytes(b"\xff\xfe\xff")
        with self.assertRaises(UnicodeError):
            t.t_update_session({"session": str(self.s), "recording_notes": "Replacement"})
        self.assertEqual(file.read_bytes(), b"\xff\xfe\xff")
        read = t.t_get_session({"session": str(self.s)})
        self.assertIsNone(read["recording_notes"])
        self.assertIn("recording_notes_error", read)
        self.assertEqual(read["script"], "Spoken script")

    def test_invalid_argument_does_not_write_notes(self):
        with self.assertRaises(ValueError):
            t.t_update_session({"session": str(self.s), "recording_notes": ["A"]})
        self.assertFalse((self.s / t.RECORDING_NOTES).exists())
