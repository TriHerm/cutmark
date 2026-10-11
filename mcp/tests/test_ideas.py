"""Ideas: one markdown file per idea, an INDEX.md the server keeps in step, notes added, never lost."""
import json
import os
import shutil
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import takes_mcp as t  # noqa: E402


class Ideas(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.mkdtemp()
        os.environ["TAKES_ROOT"] = self.root
        os.environ["TAKES_IDEA_THUMBS"] = "0"
        self.dir = os.path.join(self.root, "_library", "ideas")

    def tearDown(self):
        os.environ.pop("TAKES_ROOT", None)
        os.environ.pop("TAKES_IDEA_THUMBS", None)
        os.environ.pop("TAKES_IMAGE_CMD", None)
        shutil.rmtree(self.root, ignore_errors=True)

    def read(self, name):
        with open(os.path.join(self.dir, name)) as f:
            return f.read()

    def test_add_writes_a_file_with_frontmatter_and_the_index(self):
        out = t.t_add_idea({"title": "Walk-and-talk videos", "text": "Film on the walk.", "tags": ["Video", "#walk"],
                            "source": "phone"})
        self.assertEqual(out["id"], "walk-and-talk-videos")
        fields, body = t.parse_fm(self.read("walk-and-talk-videos.md"))
        self.assertEqual(fields["title"], "Walk-and-talk videos")
        self.assertEqual(fields["status"], "new")
        self.assertEqual(fields["tags"], "video, walk")
        self.assertEqual(fields["source"], "phone")
        self.assertEqual(body.strip(), "Film on the walk.")
        index = self.read("INDEX.md")
        self.assertIn("## New (1)", index)
        self.assertIn("- [Walk-and-talk videos](walk-and-talk-videos.md) · ", index)

    def test_same_title_gets_its_own_file(self):
        a = t.t_add_idea({"title": "Same"})
        b = t.t_add_idea({"title": "Same"})
        self.assertEqual((a["id"], b["id"]), ("same", "same-2"))
        # "Index" as a title never takes the index's name.
        # "Index" never takes the index's name (macOS names are case-blind).
        self.assertEqual(t.t_add_idea({"title": "INDEX"})["id"], "index-2")

    def test_append_keeps_the_text_and_status_moves_it_in_the_index(self):
        t.t_add_idea({"title": "Ideas board", "text": "One file each."})
        out = t.t_update_idea({"id": "ideas-board", "append": "Also on the phone.", "status": "doing"})
        self.assertTrue(out["body"].startswith("One file each.\n\n**"))
        self.assertTrue(out["body"].endswith("Also on the phone."))
        index = self.read("INDEX.md")
        self.assertIn("## Doing (1)", index)
        self.assertNotIn("## New", index)

    def test_list_hides_dropped_unless_asked_and_finds_words(self):
        t.t_add_idea({"title": "Keep", "text": "about hooks"})
        t.t_add_idea({"title": "Gone", "status": "dropped"})
        self.assertEqual([i["id"] for i in t.t_list_ideas({})["ideas"]], ["keep"])
        self.assertEqual(len(t.t_list_ideas({"status": "all"})["ideas"]), 2)
        self.assertEqual([i["id"] for i in t.t_list_ideas({"query": "HOOKS"})["ideas"]], ["keep"])

    def test_bad_ids_and_values_are_refused(self):
        for bad in ["../x", "", "INDEX", ".hidden"]:
            with self.assertRaises(ValueError):
                t.t_get_idea({"id": bad})
        t.t_add_idea({"title": "A"})
        with self.assertRaises(ValueError):
            t.t_update_idea({"id": "a", "status": "maybe"})
        with self.assertRaises(ValueError):
            t.t_add_idea({"title": "  "})

    def test_a_file_written_by_hand_is_read(self):
        os.makedirs(self.dir)
        with open(os.path.join(self.dir, "hand.md"), "w") as f:
            f.write("---\ntitle: By hand\nstatus: Exploring\n---\nText\n")
        i = t.t_get_idea({"id": "hand"})
        self.assertEqual((i["title"], i["status"], i["body"]), ("By hand", "exploring", "Text"))
        self.assertEqual(t.idea_index(t.all_ideas()).count("## Exploring (1)"), 1)

    def test_index_matches_the_apps(self):
        # Tests/TakesTests/Private/IdeasTests.swift checks the app against the same file.
        def i(id_, title, status, created, tags):
            return {"id": id_, "title": title, "status": status, "created": created, "tags": tags}
        ideas = [i("board", "Ideas board", "doing", "2026-10-09 10:00", []), i("old", "Old", "new", "", []),
                 i("walks", "Walk [talk] videos", "new", "2026-10-10 09:00", ["video", "walk"]),
                 i("drop", "Drop", "dropped", "2026-10-01 08:00", ["x"])]
        with open(os.path.join(os.path.dirname(__file__), "ideas_index.md")) as f:
            self.assertEqual(t.idea_index(ideas), f.read())



    def test_a_thumbnail_is_drawn_with_the_prompt_and_his_photos(self):
        out = t.t_add_idea({"title": "Walk videos", "text": "Film on the walk.", "thumbnail_prompt": "The user on a trail."})
        self.assertIn("note", out)  # no photos of him yet
        self.assertEqual(t.idea_json(".prompts.json"), {"walk-videos": "The user on a trail."})
        # Without photos it does not draw, and says why.
        os.environ.pop("TAKES_IDEA_THUMBS")
        self.assertFalse(t.start_idea_thumb("walk-videos"))
        self.assertEqual(t.idea_thumb_state("walk-videos"), "nophotos")
        os.makedirs(t.me_dir())
        with open(os.path.join(t.me_dir(), "me.jpg"), "wb") as f:
            f.write(b"not really a photo")
        seen = os.path.join(self.root, "seen.txt")
        os.environ["TAKES_IMAGE_CMD"] = json.dumps([sys.executable, "-c",
            "import sys; open(sys.argv[1], 'wb').write(b'png'); open(%r, 'w').write(sys.argv[2] + '|' + str(len(sys.argv) - 3))" % seen])
        t.idea_thumb_run("walk-videos")
        self.assertEqual(t.idea_thumb("walk-videos"), "thumbnails/walk-videos-v1.png")
        self.assertEqual(t.idea_thumb_state("walk-videos"), "")
        with open(seen) as f:
            prompt, refs = f.read().rsplit("|", 1)
        self.assertIn("The user on a trail.", prompt)
        self.assertIn("reference photos", prompt)
        self.assertEqual(refs, "1")
        t.idea_thumb_run("walk-videos")
        got = t.t_get_idea({"id": "walk-videos"})
        self.assertTrue(got["thumbnail"].endswith("thumbnails/walk-videos-v2.png"))
        self.assertEqual(got["thumbnail_prompt"], "The user on a trail.")

    def test_a_failed_drawing_says_why(self):
        t.t_add_idea({"title": "Broken"})
        os.makedirs(t.me_dir())
        open(os.path.join(t.me_dir(), "me.png"), "wb").close()
        os.environ["TAKES_IMAGE_CMD"] = json.dumps([sys.executable, "-c", "import sys; sys.exit('no credit')"])
        t.idea_thumb_run("broken")
        self.assertEqual(t.idea_thumb_state("broken"), "error: GPT Image 2.5 Sunburst: no credit GPT Image 2.5 Flare: no credit")
        self.assertEqual(t.idea_out(t.read_idea(t.idea_path("broken")))["thumbnail_state"][:6], "error:")


if __name__ == "__main__":
    unittest.main()
