"""Tools stay inside the library: '', '.', '..' and a bare project name are never a session, and a project
name can never be the root or a folder outside it (audit #10, 2026-10-11). Normal names keep working."""
import json
import os
import shutil
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import takes_mcp as t  # noqa: E402


class LibraryPaths(unittest.TestCase):
    def setUp(self):
        self.top = tempfile.mkdtemp()
        self.root = os.path.join(self.top, "Takes")
        self.outside = os.path.join(self.top, "outside")
        os.makedirs(self.outside)
        with open(os.path.join(self.outside, "script.md"), "w") as f:
            f.write("secret")
        os.environ["TAKES_ROOT"] = self.root
        self.s = os.path.join(self.root, "Proj", "2026-10-11-demo")
        os.makedirs(self.s)
        with open(os.path.join(self.s, "session.json"), "w") as f:
            json.dump({"title": "Demo", "createdAt": "2026-10-11T08:00:00Z", "takes": []}, f)
        self.trashed = []
        self._trash, self._open = t.trash, t.open_in_app
        t.trash = lambda paths: self.trashed.extend(paths)
        t.open_in_app = lambda path: None

    def tearDown(self):
        t.trash, t.open_in_app = self._trash, self._open
        shutil.rmtree(self.top)
        os.environ.pop("TAKES_ROOT", None)

    BAD = ("", ".", "..", "Proj", "Proj/..", "Proj/../..", "../outside", "Proj/../../outside")

    def test_bad_session_refs_are_refused(self):
        for bad in self.BAD + (self.root, self.outside, os.path.join(self.root, "Proj")):
            for tool, args in ((t.t_get_session, {}), (t.t_update_session, {"title": "New name"}),
                               (t.t_trash_sessions, None), (t.t_move_sessions, None)):
                a = ({"sessions": [bad]} if tool is t.t_trash_sessions else
                     {"sessions": [bad], "project": "Other"} if tool is t.t_move_sessions else
                     dict(args, session=bad))
                with self.assertRaises(ValueError, msg="%s %r" % (tool.__name__, bad)):
                    tool(a)
        self.assertEqual(self.trashed, [])
        self.assertTrue(os.path.isdir(self.root))
        self.assertTrue(os.path.isdir(self.s))
        self.assertEqual(sorted(os.listdir(self.top)), ["Takes", "outside"])

    def test_bad_project_names_are_refused(self):
        for bad in ("", " ", ".", ".."):
            with self.assertRaises(ValueError, msg=repr(bad)):
                t.t_create_project({"name": bad})
            with self.assertRaises(ValueError, msg=repr(bad)):
                t.t_move_sessions({"sessions": [self.s], "project": bad})
        for bad in (".", ".."):
            with self.assertRaises(ValueError, msg=repr(bad)):
                t.t_create_session({"project": bad, "title": "x", "open": False})
        for bad in ("", ".", "..", "Proj/2026-10-11-demo", self.outside):
            with self.assertRaises(ValueError, msg=repr(bad)):
                t.t_list_sessions({"project": bad})
        self.assertEqual(sorted(os.listdir(self.top)), ["Takes", "outside"])
        self.assertTrue(os.path.isdir(self.s))

    def test_normal_names_keep_working(self):
        p = t.t_create_project({"name": "Ideas v1.2 – Café"})["path"]
        self.assertEqual(os.path.dirname(p), self.root)
        self.assertEqual(t.t_create_project({"name": "a/b"})["project"], "a-b")
        new = t.t_create_session({"project": "Ideas v1.2 – Café", "title": "First one", "open": False})
        self.assertEqual(os.path.dirname(os.path.dirname(new["path"])), self.root)
        self.assertEqual(t.t_get_session({"session": "Proj/2026-10-11-demo"})["title"], "Demo")
        self.assertEqual(t.t_get_session({"session": self.s})["title"], "Demo")
        self.assertEqual(t.t_get_session({"session": self.s + "/"})["title"], "Demo")
        moved = t.t_move_sessions({"sessions": [self.s], "project": "Ideas v1.2 – Café"})["moved"]
        self.assertEqual(moved[0]["to"], os.path.join("Ideas v1.2 – Café", "2026-10-11-demo"))
        # The old path still finds the moved session.
        self.assertEqual(t.t_get_session({"session": "Proj/2026-10-11-demo"})["title"], "Demo")
        t.t_trash_sessions({"sessions": [moved[0]["to"]]})
        self.assertEqual(self.trashed, [os.path.join(self.root, moved[0]["to"])])

    def test_inside_root(self):
        self.assertTrue(t.inside_root(self.root))
        self.assertTrue(t.inside_root(self.s))
        self.assertFalse(t.inside_root(os.path.join(self.root, "..", "outside")))
        self.assertFalse(t.inside_root(self.root + "-other"))
        self.assertTrue(t.is_session_path(self.s))
        self.assertFalse(t.is_session_path(os.path.join(self.root, "Proj")))
        self.assertFalse(t.is_session_path(os.path.join(self.s, "edits")))


if __name__ == "__main__":
    unittest.main()
