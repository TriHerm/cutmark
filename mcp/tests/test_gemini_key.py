"""Auxiliary API keys: process/Keychain precedence stays intact; Cutmark config beats legacy Claude config."""
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import takes_mcp as t  # noqa: E402

NAMES = ("GEMINI_API_KEY", "GOOGLE_AI_API_KEY", "GOOGLE_API_KEY", "OPENAI_API_KEY",
         "REPLICATE_API_TOKEN", "ELEVENLABS_API_KEY", "TAKES_NO_KEYCHAIN")


class GeminiKey(unittest.TestCase):
    def setUp(self):
        self.saved = {k: os.environ.pop(k, None) for k in NAMES + ("HOME",)}
        os.environ["HOME"] = tempfile.mkdtemp()
        os.makedirs(os.path.join(os.environ["HOME"], ".claude"))
        os.makedirs(os.path.join(os.environ["HOME"], ".config", "cutmark"))

    def tearDown(self):
        for k, v in self.saved.items():
            os.environ.pop(k, None)
            if v is not None:
                os.environ[k] = v

    def env(self, text, cutmark=True):
        folder = os.path.join(os.environ["HOME"], ".config", "cutmark") if cutmark else os.path.join(os.environ["HOME"], ".claude")
        with open(os.path.join(folder, ".env"), "w") as f:
            f.write(text)

    def test_the_saved_key_wins_over_an_older_one(self):
        self.env("GOOGLE_AI_API_KEY=old\nexport GEMINI_API_KEY=\"new\"\n")
        self.assertEqual(t.gemini_key(), "new")

    def test_older_name_still_works(self):
        self.env("GOOGLE_AI_API_KEY='g'\n")
        self.assertEqual(t.gemini_key(), "g")

    def test_environment_first_and_none_without_a_key(self):
        self.env("")
        self.assertIsNone(t.gemini_key())
        os.environ["GOOGLE_API_KEY"] = "e"
        self.assertEqual(t.gemini_key(), "e")

    def test_cutmark_config_wins_and_legacy_is_a_fallback_for_all_aux_readers(self):
        self.env("GEMINI_API_KEY=legacy-g\nOPENAI_API_KEY=legacy-o\nREPLICATE_API_TOKEN=legacy-r\nELEVENLABS_API_KEY=legacy-e\n", cutmark=False)
        self.env("GEMINI_API_KEY=cutmark-g\nOPENAI_API_KEY=cutmark-o\nREPLICATE_API_TOKEN=cutmark-r\nELEVENLABS_API_KEY=cutmark-e\n")
        os.environ["TAKES_NO_KEYCHAIN"] = "1"
        self.assertEqual(t.gemini_key(), "cutmark-g")
        self.assertEqual(t.openai_key(), "cutmark-o")
        self.assertEqual(t.rep_key(), "cutmark-r")
        self.assertEqual(t.eleven_key(), "cutmark-e")

        os.remove(os.path.join(os.environ["HOME"], ".config", "cutmark", ".env"))
        self.assertEqual(t.gemini_key(), "legacy-g")
        self.assertEqual(t.openai_key(), "legacy-o")
        self.assertEqual(t.rep_key(), "legacy-r")
        self.assertEqual(t.eleven_key(), "legacy-e")


if __name__ == "__main__":
    unittest.main()
