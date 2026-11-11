import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import cutmark_mcp as t


class StudioCuts(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        self.session = self.root / "Inbox" / "2026-11-10-test"
        self.project = self.session / t.STUDIO_PROJECT
        self.proposal = self.session / t.STUDIO_CUTS
        self.project.parent.mkdir(parents=True)
        self.addCleanup(patch.stopall)
        patch.dict(os.environ, CUTMARK_ROOT=str(self.root)).start()
        self.project.write_text(json.dumps({"version": 1, "clips": [
            {"file": "a.mov", "lane": "video", "start": 2, "end": 10, "speed": 2, "offset": 0},
            {"file": "b.mov", "lane": "overlay", "start": 0, "end": 2, "speed": 1, "offset": 1},
            {"file": "c.mov", "lane": "video", "start": 0, "end": 1, "speed": 1, "offset": 0},
        ]}))
        (self.session / "a.words.json").write_text('{"words":[]}')
        self.args = {"session": str(self.session), "revision": t.t_get_studio_timeline({"session": str(self.session)})["revision"]}

    def test_proposal_maps_output_and_leaves_project_unchanged(self):
        before = self.project.read_bytes()
        snapshot = t.t_get_studio_timeline(self.args)
        self.assertEqual(snapshot["duration"], 5)
        self.assertEqual([c["output_start"] for c in snapshot["timeline"]], [0, 1, 4])
        self.assertEqual(snapshot["timeline"][0]["words_file"], "a.words.json")
        cuts = [{"start": 1, "end": 2, "reason": "Remove the first attempt"}]
        t.t_propose_studio_cuts({**self.args, "cuts": cuts})
        self.assertEqual(json.loads(self.proposal.read_text()), {"revision": self.args["revision"], "cuts": cuts})
        self.assertEqual(self.project.read_bytes(), before)

    def test_invalid_and_stale_cuts_do_not_replace_existing_proposal(self):
        cuts = [{"start": 1, "end": 2, "reason": "Pause"}]
        t.t_propose_studio_cuts({**self.args, "cuts": cuts})
        before = self.proposal.read_bytes()
        for bad in (
            [{"start": 0, "end": 5, "reason": "All"}],
            cuts + [{"start": 1.5, "end": 3, "reason": "Overlap"}],
            [{"start": 0, "end": float("nan"), "reason": "Nonfinite"}],
        ):
            with self.assertRaises(ValueError):
                t.t_propose_studio_cuts({**self.args, "cuts": bad})
        with self.project.open("a") as file:
            file.write("\n")
        with self.assertRaisesRegex(ValueError, "timeline changed"):
            t.t_propose_studio_cuts({**self.args, "cuts": cuts})
        self.assertEqual(self.proposal.read_bytes(), before)
