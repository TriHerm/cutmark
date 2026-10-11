import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import takes_mcp as t  # noqa: E402


class ToolDocsTests(unittest.TestCase):
    """tools/list describes every parameter and gives every tool its hints (2026-10-10): MCP
    directories such as Smithery score both."""

    def test_every_parameter_has_a_description(self):
        missing = []

        def walk(tool, schema, at):
            for k, v in schema.get("properties", {}).items():
                if not v.get("description"):
                    missing.append("%s.%s%s" % (tool, at, k))
                walk(tool, v, at + k + ".")
                if isinstance(v.get("items"), dict):
                    walk(tool, v["items"], at + k + "[].")
        for n, d, props, req, _ in t.TOOLS:
            walk(n, t.listed(n, d, props, req)["inputSchema"], "")
        self.assertEqual(missing, [], "add these to PARAM_DOC or give them a description")

    def test_hint_sets_name_real_tools(self):
        defined = {n[2:] for n in dir(t) if n.startswith("t_")}
        for hints in (t.READ_ONLY, t.DESTRUCTIVE, t.OPEN_WORLD):
            self.assertTrue(hints <= defined, hints - defined)
        self.assertFalse(t.READ_ONLY & t.DESTRUCTIVE)

    def test_listing_leaves_the_table_alone(self):
        self.assertEqual(t.S, {"type": "string"})
        for n, d, props, req, _ in t.TOOLS:
            self.assertIn("annotations", t.listed(n, d, props, req))


if __name__ == "__main__":
    unittest.main()
