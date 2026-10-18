"""Source-clock timeline edits are non-destructive until render_edit is explicitly called."""
import os
import sys
import unittest
from unittest.mock import patch

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
sys.path.insert(0, os.path.dirname(__file__))
import cutmark_mcp as t  # noqa: E402
from test_edit_recipe import Base  # noqa: E402


class TimelineEditing(unittest.TestCase):
    def setUp(self):
        self.cut = [{"take": 1, "kind": "screen", "in": 0.5, "out": 3.5},
                    {"take": 2, "kind": "camera", "in": 4.0, "out": 7.0}]

    def test_split_keeps_source_frames_and_output_order(self):
        result = t.edit_timeline_cut(self.cut, [{"op": "split", "index": 0, "at": 2.0}], fps=30)
        self.assertEqual([(x["take"], x["in"], x["out"]) for x in result],
                         [(1, 0.5, 2), (1, 2, 3.5), (2, 4, 7)])
        self.assertEqual(t.edit_time_map(result)["duration"], 6.0)
        self.assertEqual(self.cut[0]["out"], 3.5)  # Never changes original cut.

    def test_trim_move_duplicate_remove_each_occurrence(self):
        result = t.edit_timeline_cut(self.cut, [
            {"op": "trim", "index": 0, "in": 1.0, "out": 2.0},
            {"op": "duplicate", "index": 0},
            {"op": "move", "index": 2, "to": 0},
            {"op": "remove", "index": 2},
        ])
        self.assertEqual([(x["take"], x["in"], x["out"]) for x in result],
                         [(2, 4, 7), (1, 1, 2)])
        self.assertEqual(t.edit_time_map(result)["duration"], 4.0)

    def test_refuses_unsafe_actions(self):
        bad = ([{"op": "split", "index": 0, "at": 0.51}],
               [{"op": "trim", "index": 0, "in": -1}],
               [{"op": "trim", "index": 0, "out": 4}],
               [{"op": "trim", "index": 0, "out": float("nan")}],
               [{"op": "move", "index": 0, "to": 9}],
               [{"op": "duplicate", "index": True}],
               [{"op": "what", "index": 0}])
        for actions in bad:
            with self.subTest(actions=actions), self.assertRaises(ValueError):
                t.edit_timeline_cut(self.cut, actions)
        with self.assertRaises(ValueError):
            t.edit_timeline_cut(self.cut[:1], [{"op": "remove", "index": 0}])

    def test_public_plan_does_not_write_and_returns_render_request(self):
        base = {"edit": "edits/cut-v1.mp4", "name": "cut", "cut": self.cut,
                "frame": {"shape": "source", "fps": 30}}
        with patch.object(t, "resolve_session", return_value="/scratch/session"), \
                patch.object(t, "pick_base", return_value=(base, [])), \
                patch.object(t, "norm_recipe", side_effect=lambda s, r: r), \
                patch.object(t, "check_recipe") as check:
            out = t.t_plan_timeline_edit({"session": "scratch", "actions": [
                {"op": "split", "index": 0, "at": 1.5}]})
        check.assert_called_once()
        self.assertEqual(out["base"], "edits/cut-v1.mp4")
        self.assertEqual(out["segments"], 3)
        self.assertEqual(out["render_edit"]["changes"], out["changes"])
        self.assertEqual(out["timeline"]["duration"], 6.0)
        self.assertTrue(any(n == "plan_timeline_edit" for n, *_ in t.TOOLS))
        self.assertIn("plan_timeline_edit", t.READ_ONLY)


class TimelineRenderIntegration(Base):
    def test_plan_changes_generate_checked_unpublished_render_without_overwriting_base(self):
        self.add_take(1, secs=6)
        first = self.render(recipe={"name": "demo", "cut": [
            {"take": 1, "in": 0.5, "out": 2.5},
            {"take": 1, "in": 3.5, "out": 5.5},
        ]})
        published = t.t_publish_edit({"session": self.s, "render": first["job"], "note": "Initial cut."})
        recipe_path = os.path.join(self.s, published["recipe"])
        with open(recipe_path, "rb") as f:
            original = f.read()
        actions = [{"op": "split", "index": 0, "at": 1.5},
                   {"op": "remove", "index": 1},
                   {"op": "move", "index": 1, "to": 0},
                   {"op": "trim", "index": 1, "out": 1.25}]
        plan = t.t_plan_timeline_edit({"session": self.s, "base": "demo", "actions": actions})
        self.assertEqual(plan["timeline"]["duration"], 2.75)
        render_args = dict(plan["render_edit"], wait_s=120)
        output = t.t_render_edit(render_args)
        self.assertEqual(output.get("status"), "done", output)
        self.assertTrue(os.path.isfile(os.path.join(self.s, output["render"])))
        with open(recipe_path, "rb") as f:
            self.assertEqual(f.read(), original)
        self.assertEqual(plan["segments"], 2)


if __name__ == "__main__":
    unittest.main()
