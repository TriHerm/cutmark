"""Edit recipes (2026-10-11): render_edit builds a recipe into a checked render, publish_edit saves it as
the next version with its recipe, the next version starts from that recipe. Media made with ffmpeg in a
temp library; real renders run as real jobs. No network, no money."""
import json
import hashlib
import os
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
sys.path.insert(0, os.path.dirname(__file__))
import cutmark_mcp as t  # noqa: E402
from test_edit_ready import FFMPEG, ff, flash_take  # noqa: E402

REAL = {n: getattr(t, n) for n in ("spawn_detached", "start_job", "trash", "take_clock", "open_in_app",
                                   "link_noclobber", "clone_file", "claimed_outputs")}


def text(path):
    with open(path) as f:
        return f.read()


def jload(path):
    with open(path) as f:
        return json.load(f)


def probe(path):
    out = subprocess.run([shutil.which("ffprobe") or "/opt/homebrew/bin/ffprobe", "-v", "error", "-show_entries",
                          "stream=codec_type,width,height,r_frame_rate:format=duration", "-of", "json", path],
                         capture_output=True, text=True).stdout
    return json.loads(out)


def lufs(path):
    err = subprocess.run([FFMPEG, "-nostats", "-i", path, "-vn", "-af", "ebur128", "-f", "null", "-"],
                         capture_output=True, text=True).stderr
    return float(re.findall(r"I:\s*(-?[\d.]+)\s*LUFS", err.rsplit("Summary:", 1)[-1])[0])


def rgb_at(path, sec):
    raw = subprocess.run([FFMPEG, "-v", "error", "-ss", "%.3f" % sec, "-i", path, "-frames:v", "1", "-vf",
                          "scale=1:1", "-f", "rawvideo", "-pix_fmt", "rgb24", "-"], capture_output=True).stdout
    return tuple(raw[:3])


class Base(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.mkdtemp()
        os.environ["CUTMARK_ROOT"] = self.root
        os.environ["CUTMARK_JOB_TIMEOUT"] = "300"
        os.environ["CUTMARK_HOST_ID"] = "this-mac"
        for k in ("CUTMARK_CHAT", "CUTMARK_BOARD", "CLAUDE_CODE_SESSION_ID", "CUTMARK_STEP_TIMEOUT"):
            os.environ.pop(k, None)
        for k, v in REAL.items():
            setattr(t, k, v)
        t.forget_seen()
        t.CLOCKS.clear()
        self.opened, self.trashed = [], []
        t.open_in_app = lambda p: self.opened.append(p)
        t.trash = lambda paths: self.trashed.extend(paths) or [os.remove(p) for p in paths]
        self.s = os.path.join(self.root, "Proj", "2026-10-11-demo")
        os.makedirs(self.s)
        t.write_meta(self.s, {"title": "demo", "createdAt": "2026-10-11T00:00:00Z", "named": True, "takes": []})

    def tearDown(self):
        for k, v in REAL.items():
            setattr(t, k, v)
        for j in t.all_jobs(self.s) if os.path.isdir(self.s) else []:
            if j["status"] in ("starting", "running") and j.get("pid"):
                try:
                    os.kill(j["pid"], signal.SIGTERM)
                except OSError:
                    pass
        shutil.rmtree(self.root, ignore_errors=True)
        for k in ("CUTMARK_ROOT", "CUTMARK_JOB_TIMEOUT", "CUTMARK_HOST_ID", "CUTMARK_STEP_TIMEOUT"):
            os.environ.pop(k, None)

    def add_take(self, n=1, secs=6, kind="camera", **kw):
        f = "take-%02d-%s.mov" % (n, kind)
        flash_take(os.path.join(self.s, f), secs=secs, **kw)
        meta = t.read_meta(self.s)
        meta["takes"].append({"number": n, "kind": kind, "file": f, "startedAt": "2026-10-11T00:00:00Z",
                              "duration": secs})
        t.write_meta(self.s, meta)
        return f

    def music(self, name="Calm.wav", secs=10, f=300):
        d = os.path.join(self.root, "_library", "audio", "Music")
        os.makedirs(d, exist_ok=True)
        ff("-f", "lavfi", "-i", "sine=f=%d:d=%d" % (f, secs), "-af", "volume=0.3", os.path.join(d, name))
        return "@library/audio/Music/" + name

    def thumb(self, name="hook-v1.png", color="red", size="160x120"):
        d = os.path.join(self.s, "thumbnails")
        os.makedirs(d, exist_ok=True)
        ff("-f", "lavfi", "-i", "color=%s:s=%s" % (color, size), "-frames:v", "1", os.path.join(d, name))
        return "thumbnails/" + name

    def clip(self, rel, size="160x120", secs=1, color="blue"):
        p = os.path.join(self.s, rel)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        ff("-f", "lavfi", "-i", "color=%s:s=%s:r=30:d=%s" % (color, size, secs), "-f", "lavfi", "-i",
           "sine=d=%s" % secs, "-shortest", "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac", p)
        return p

    CUT = [{"take": 1, "in": 0.5, "out": 2.5}, {"take": 1, "in": 3.5, "out": 5.5}]

    def render(self, **a):
        r = t.t_render_edit(dict({"session": self.s, "wait_s": 120}, **a))
        self.assertEqual(r.get("status"), "done", r)
        return r

    def fake_render(self, name="hook", parent=None, passed=True, started=None, size="160x120", extra=None):
        """A finished render without ffmpeg's render: for publish_edit's own rules."""
        rid = t.new_job_id(self.s)
        os.makedirs(os.path.join(self.s, t.RENDERS), exist_ok=True)
        self.clip(os.path.join(t.RENDERS, rid + ".mp4"), size=size)
        res = [{"check": "streams", "pass": True}, {"check": "av_sync", "pass": passed,
                                                    **({} if passed else {"say": "The sound is late."})}]
        r = dict({"recipe": 1, "name": name, "cut": [{"take": 1, "in": 0.5, "out": 2.5, "kind": "camera"}],
                  "frame": {"shape": "source", "w": 160, "h": 120, "fps": 30}, "over": [], "music": [], "sfx": [],
                  "steps": [], "parent": parent, "by": "render_edit", "host": "this-mac", "render_id": rid,
                  "job": rid, "started": started or t.now_iso(), "checks": {"passed": passed, "results": res},
                  "inputs": {}, "commands": []}, **(extra or {}))
        t.write_json(os.path.join(self.s, t.RENDERS, rid + t.RECIPE_EXT), r)
        with open(os.path.join(self.s, t.RENDERS, rid + ".words.json"), "w") as f:
            json.dump({"words": []}, f)
        return rid

    def recipe(self, rel):
        with open(os.path.join(self.s, rel)) as f:
            return json.load(f)

    def auto_zoom(self, items, take=1, digest=None, through=3.0, plan=None):
        """A normalized-looking v1 contract for pure recipe tests."""
        digest = digest or "a" * 64
        plan = plan or "b" * 64
        made = []
        for z in items:
            semantic = dict({"take": take, "kind": "screen", "trigger": 1.0, "in": 0.8, "out": 2.0,
                             "focus": {"x": 0.5, "y": 0.5}, "scale": 1.35,
                             "reason": "primary_click"}, **z)
            semantic.setdefault("id", t.auto_zoom_id(semantic))
            semantic.setdefault("ease", 0.18)
            made.append(semantic)
        return {"v": 1, "planner": t.AUTO_ZOOM_PLANNER, "plan": plan,
                "inputs": [{"take": take, "sha256": digest, "through": through}], "items": made}


class Pure(Base):
    def test_merge_patch(self):
        base = {"a": {"b": 1, "c": 2}, "l": [1, 2], "x": 1}
        self.assertEqual(t.merge_patch(base, {"a": {"b": 5}, "l": [3], "x": None, "y": {"z": None}}),
                         {"a": {"b": 5, "c": 2}, "l": [3], "y": {}})

    def test_diff_names_values_a_list_replace_dropped(self):
        a = {"music": [{"file": "m", "in": 14.0, "gain_db": -18}]}
        changes = {"music": [{"file": "m", "gain_db": -21}]}
        b = t.merge_patch(a, changes)
        d = t.recipe_diff(a, b)
        self.assertEqual(d["music[0].gain_db"], [-18, -21])
        self.assertEqual(d["music[0].in"], [14.0, None])
        warn = t.unnamed_changes(d, changes)
        self.assertEqual(len(warn), 1)
        self.assertIn("music[0].in went from 14.0", warn[0])
        # An emptied list is on purpose: no warning.
        self.assertEqual(t.unnamed_changes(t.recipe_diff(a, {"music": []}), {"music": []}), [])

    def test_norm_and_fill_defaults(self):
        self.add_take()
        song = self.music()
        r = t.norm_recipe(self.s, {"name": "Hook One", "cut": self.CUT,
                                   "music": [{"file": os.path.join(self.root, "_library/audio/Music/Calm.wav")}]})
        self.assertEqual(r["name"], "hook-one")
        self.assertEqual(r["music"][0]["file"], song)  # an absolute library path is stored as @library/...
        self.assertEqual(r["music"][0]["gain_db"], -18)
        self.assertEqual(r["cut"][0]["kind"], "camera")
        t.fill_recipe(self.s, r)
        self.assertEqual(r["voice"]["source"], "take")
        self.assertEqual((r["frame"]["w"], r["frame"]["h"], r["frame"]["fps"]), (160, 120, 30))
        self.assertEqual(r["takes"][0]["file"], "take-01-camera.mov")
        self.assertIn("take-01-camera.mov", r["inputs"])
        # A clean voice that is done: the recipe uses it, keyed by number and kind, with its chain.
        key = t.voice_key(1, "camera")
        os.makedirs(os.path.join(self.s, "voice"))
        ff("-f", "lavfi", "-i", "sine=d=6", "-ac", "1", "-ar", "48000", t.voice_files(self.s, key)["mix"])
        t.write_voice(self.s, key, {"state": "done", "on": True, "strength": 0.7, "loudness": "quiet",
                                    "clock": "video", "steps": ["clearvoice"]})
        r2 = t.norm_recipe(self.s, {"name": "hook", "cut": self.CUT})
        t.fill_recipe(self.s, r2)
        self.assertEqual(r2["voice"]["source"], "clean")
        self.assertEqual(r2["voice"]["keys"][key], os.path.join("voice", key + ".wav"))
        self.assertEqual(r2["voice"]["chain"][key]["strength"], 0.7)
        self.assertEqual(t.recipe_target(r2), -18.0)  # a quiet voice aims at -18, not a fixed -14
        r2["loudness"] = -16
        self.assertEqual(t.recipe_target(r2), -16.0)

    def test_refusals(self):
        self.add_take()
        song = self.music()
        self.clip("edits/hook-v1.mp4")
        ok = {"name": "hook", "cut": self.CUT}

        def refused(rec, part):
            with self.assertRaises(ValueError) as e:
                r = t.norm_recipe(self.s, rec)
                t.check_recipe(self.s, r)
            self.assertIn(part, str(e.exception))
        refused(dict(ok, music=[{"file": "edits/hook-v1.mp4"}]), "final mix is never an input")
        self.clip("_edit/renders/job-abc123.mp4")
        self.clip("_edit/hook/.versions/v1/mix.mp4")
        refused(dict(ok, music=[{"file": "_edit/renders/job-abc123.mp4"}]), "final mix is never an input")
        refused(dict(ok, sfx=[{"file": "_edit/hook/.versions/v1/mix.mp4", "at": 0}]), "final mix is never an input")
        refused(dict(ok, loudness="loud"), "loudness is a number in LUFS, e.g. -14.")
        refused(dict(ok, music=[{"file": song}, {"file": song, "at": 3}]), "One song at a time")
        refused(dict(ok, sfx=[{"file": "gone.wav", "at": 1}]), "gone.wav is gone")
        refused(dict(ok, steps=[{"run": ["true"], "cwd": "edits"}]), "must be inside _edit/hook/")
        refused(dict(ok, steps=[{"run": "npx hyperframes render"}]), "not a shell line")
        refused(dict(ok, steps=[{"run": ["x"], "makes": ["../../evil.mov"]}]), "must be inside")
        refused(dict(ok, cut=[{"take": 1, "in": 2, "out": 60}]), "Give 0 <= in < out")
        outside = os.path.join(tempfile.gettempdir(), "cutmark-outside-%d.wav" % os.getpid())
        ff("-f", "lavfi", "-i", "sine=d=1", outside)
        try:
            refused(dict(ok, sfx=[{"file": outside, "at": 1}]), "Copy it into the session or the library first")
        finally:
            os.remove(outside)
        refused({"cut": self.CUT}, "Give name")
        # Music entries that follow each other are fine.
        r = t.norm_recipe(self.s, dict(ok, music=[{"file": song, "out": 3}, {"file": song, "at": 3}]))
        t.check_recipe(self.s, r)

    def test_take_gone_and_disk_full(self):
        self.add_take()
        os.remove(os.path.join(self.s, "take-01-camera.mov"))
        with self.assertRaises(ValueError) as e:
            t.t_render_edit({"session": self.s, "recipe": {"name": "hook", "cut": self.CUT}})
        self.assertIn("take-01-camera.mov is gone. Pick another take in cut.", str(e.exception))
        self.add_take(2)
        real = shutil.disk_usage
        t.shutil.disk_usage = lambda p: real(p)._replace(free=1000)
        try:
            with self.assertRaises(ValueError) as e:
                t.t_render_edit({"session": self.s, "recipe": {"name": "hook", "cut": [{"take": 2, "in": 0, "out": 2}]}})
        finally:
            t.shutil.disk_usage = real
        self.assertRegex(str(e.exception), r"Not enough free disk: this render needs about \d+ [MG]B, 1 MB is free\.")

    def test_edit_time_map_handles_multiple_sources_reuse_and_lead(self):
        cut = [
            {"take": 2, "kind": "screen", "in": 5.0, "out": 7.0},
            {"take": 1, "kind": "camera", "in": 1.0, "out": 4.0},
            {"take": 2, "kind": "screen", "in": 5.5, "out": 6.5},
        ]
        m = t.edit_time_map(cut, lead=0.1)
        self.assertEqual([(x["take"], x["kind"]) for x in m["spans"]], [(2, "screen"), (1, "camera"), (2, "screen")])
        self.assertEqual([round(x["at"], 3) for x in m["spans"]], [0.1, 2.1, 5.1])
        self.assertAlmostEqual(m["duration"], 6.1)
        # The same source moment may intentionally appear more than once in an edit.
        self.assertEqual([round(x, 3) for x in t.source_to_outputs(m, 2, "screen", 6.0)], [1.1, 5.6])
        self.assertEqual(t.output_to_source(m, 3.1), (1, "camera", 2.0))
        self.assertEqual(t.output_to_source(m, 2.1), (1, "camera", 1.0))  # a cut boundary belongs to the next span
        self.assertEqual(t.source_to_outputs(m, 2, "screen", 7.0), [])
        self.assertIsNone(t.output_to_source(m, 0.05))
        rounded = t.edit_time_map([{"take": 1, "kind": "camera", "in": 1.0, "out": 1.0333, "len": 2 / 30.0}])
        self.assertAlmostEqual(rounded["spans"][0]["out"], 1.0 + 2 / 30.0)
        self.assertAlmostEqual(t.span_source_to_output(rounded["spans"][0], 1.0 + 2 / 30.0), 2 / 30.0)

    def test_capture_events_skip_torn_lines_and_share_the_edit_time_map(self):
        path = t.capture_events_file(self.s, 8)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        events = [
            {"t": 1.8, "type": "marker", "source": "screen"},
            {"t": 1.0, "type": "down", "source": "screen", "x": 0.5, "y": 0.4},
        ]
        with open(path, "w") as f:
            f.write(json.dumps({"v": 1, "type": "header", "take": 8, "source": "screen", "clock": "screen_pts",
                                "coordinates": "display_normalized_top_left",
                                "display": {"id": 1, "x": 0, "y": 0, "width": 1920, "height": 1080}}) + "\n")
            for e in events:
                f.write(json.dumps(e) + "\n")
            f.write(json.dumps({"t": 1.5, "type": "key", "source": "screen"}) + "\n")
            f.write('{"t":2,"type":"move"')  # a crash can tear only the last append
        self.assertEqual(t.read_capture_events(self.s, 8), events)

        timeline = t.edit_time_map([
            {"take": 8, "kind": "camera", "in": 1.0, "out": 4.0},
            {"take": 8, "kind": "screen", "in": 0.0, "out": 3.0},
        ])
        mapped = t.map_capture_events(timeline, 8, events)
        marker = [x for x in mapped if x["event"]["type"] == "marker"]
        self.assertEqual([round(x["output"], 1) for x in marker], [4.8])
        click = [x for x in mapped if x["event"]["type"] == "down"]
        self.assertEqual([(x["kind"], round(x["output"], 1)) for x in click], [("screen", 4.0)])

        # Recovered media can be shorter than the JSONL tail; metadata bounds what readers expose.
        meta = t.read_meta(self.s)
        meta["takes"].append({"number": 8, "kind": "screen", "file": "take-08-screen.mov",
                              "startedAt": "2026-10-11T00:00:00Z", "duration": 1.5})
        t.write_meta(self.s, meta)
        self.assertEqual([e["type"] for e in t.read_capture_events(self.s, 8)], ["down"])

    def test_auto_zoom_planner_is_deterministic_click_focused_and_ignores_move_only_activity(self):
        events = [
            {"t": 0.90, "type": "move", "source": "screen", "x": 0.01, "y": 0.04},
            {"t": 0.98, "type": "move", "source": "screen", "x": 0.02, "y": 0.05},
            {"t": 1.00, "type": "down", "source": "screen", "x": 0.01, "y": 0.05, "button": 0, "count": 1},
            {"t": 1.45, "type": "down", "source": "screen", "x": 0.53, "y": 0.51, "button": 0, "count": 1},
            {"t": 1.70, "type": "down", "source": "screen", "x": 0.80, "y": 0.20, "button": 0, "count": 1},
            {"t": 2.00, "type": "scroll", "source": "screen", "x": 0.7, "y": 0.2, "dx": 0, "dy": 20},
            {"t": 2.20, "type": "down", "source": "screen", "x": 0.1, "y": 0.9, "button": 1, "count": 1},
        ]
        a = t.plan_auto_zooms(events, 4)
        b = t.plan_auto_zooms(list(reversed(events)), 4)
        self.assertEqual(a, b)
        self.assertEqual(len(a), 1)
        self.assertEqual(a[0]["trigger"], 1.70)  # rapid burst keeps the final navigation target
        self.assertEqual(a[0]["in"], 0.88)      # but keeps pre-roll from the first click in the burst
        self.assertEqual(a[0]["focus"], {"x": 0.80, "y": 0.20})
        self.assertEqual(a[0]["scale"], 1.35)
        self.assertEqual(t.plan_auto_zooms([events[0], events[1]], 4), [])

    def test_auto_zoom_interval_mapping_respects_cuts_reuse_rate_and_camera_identity(self):
        timeline = t.edit_time_map([
            {"take": 4, "kind": "screen", "in": 2.0, "out": 5.0},
            {"take": 4, "kind": "camera", "in": 0.0, "out": 1.0},
            {"take": 4, "kind": "screen", "in": 2.5, "out": 4.0, "rate": 2.0},
        ], lead=0.1)
        zoom = {"take": 4, "kind": "screen", "trigger": 3.0, "in": 2.88, "out": 4.35,
                "focus": {"x": 0.5, "y": 0.5}, "scale": 1.35, "reason": "primary_click"}
        mapped = t.map_auto_zooms(timeline, 4, [zoom])
        self.assertEqual(len(mapped), 2)
        self.assertEqual([round(x["output_trigger"], 2) for x in mapped], [1.10, 4.35])
        self.assertEqual([(round(x["output_in"], 2), round(x["output_out"], 2)) for x in mapped],
                         [(0.98, 2.45), (4.29, 4.85)])
        # A trigger removed by the cut does not leak its pre/post window into a kept span.
        removed = dict(zoom, trigger=1.5, **{"in": 1.4, "out": 2.4})
        self.assertEqual(t.map_auto_zooms(timeline, 4, [removed]), [])

    def test_suggest_auto_zooms_is_read_only_versioned_and_uses_recovered_duration(self):
        self.add_take(n=3, secs=2, kind="screen")
        path = t.capture_events_file(self.s, 3)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as f:
            f.write(json.dumps({"v": 1, "type": "header", "take": 3, "source": "screen", "clock": "screen_pts",
                                "coordinates": "display_normalized_top_left",
                                "display": {"id": 1, "x": 0, "y": 0, "width": 1920, "height": 1080}}) + "\n")
            f.write(json.dumps({"t": 1.0, "type": "down", "source": "screen", "x": 0.4, "y": 0.6,
                                "button": 0, "count": 1}) + "\n")
            f.write(json.dumps({"t": 2.4, "type": "down", "source": "screen", "x": 0.8, "y": 0.2,
                                "button": 0, "count": 1}) + "\n")
        with open(path, "rb") as f:
            before = f.read()
        out = t.t_suggest_auto_zooms({"session": self.s, "take": 3})
        self.assertEqual(out["planner"], "click_focus_v1")
        self.assertFalse(out["applied"])
        self.assertEqual([z["trigger"] for z in out["suggestions"]], [1.0])
        self.assertEqual(out["suggestions"][0]["out"], 2.0)
        self.assertEqual(out["inputs"][0]["through"], 2.0)
        self.assertEqual(out["inputs"][0]["sha256"], hashlib.sha256(before).hexdigest())
        self.clip("edits/hook-v1.mp4", secs=1)
        cover = self.thumb()
        t.write_json(os.path.join(self.s, "edits", "hook-v1.recipe.json"),
                     {"name": "hook", "edit": "edits/hook-v1.mp4",
                      "cut": [{"take": 3, "kind": "screen", "in": 0.5, "out": 1.5}],
                      "frame": {"shape": "source"}, "cover": {"image": cover, "seconds": 0.1}})
        mapped = t.t_suggest_auto_zooms({"session": self.s, "take": 3, "edit": "hook-v1"})
        self.assertEqual(mapped["base"], "hook-v1")
        self.assertRegex(mapped["plan"], r"^[0-9a-f]{64}$")
        self.assertEqual(len(mapped["output"]), 1)
        self.assertEqual(round(mapped["output"][0]["output_trigger"], 2), 0.60)
        self.assertEqual((round(mapped["output"][0]["output_in"], 2), round(mapped["output"][0]["output_out"], 2)),
                         (0.48, 1.10))
        self.assertEqual(mapped["applicable_ids"], [mapped["suggestions"][0]["id"]])
        self.assertIn("apply_auto_zooms", mapped["next"])
        with open(path, "rb") as f:
            self.assertEqual(f.read(), before)

    def test_smart_speed_planner_only_finds_long_silent_interaction_free_gaps(self):
        events = [
            {"t": 0.0, "type": "visual_active", "source": "screen"},
            {"t": 0.6, "type": "visual_idle", "source": "screen"},
            {"t": 3.7, "type": "visual_active", "source": "screen"},
            {"t": 8.6, "type": "visual_idle", "source": "screen"},
            {"t": 11.7, "type": "visual_active", "source": "screen"},
        ]
        planned = t.plan_smart_speeds(events, [{"word": "hello", "start": 5.0, "end": 6.0}], [], 2, 12.0)
        self.assertEqual(len(planned), 2)
        self.assertEqual([(round(x["in"], 2), round(x["out"], 2)) for x in planned], [(0.85, 3.45), (8.85, 11.45)])
        self.assertTrue(all(x["rate"] == 1.5 and x["reason"] == "idle_silence" for x in planned))
        self.assertTrue(all(re.fullmatch(r"ss-[0-9a-f]{12}", x["id"]) for x in planned))

        guarded = t.plan_smart_speeds([
            {"t": 0.0, "type": "visual_active", "source": "screen"},
            {"t": 0.25, "type": "visual_idle", "source": "screen"},
            {"t": 4.5, "type": "marker", "source": "screen", "label": "keep normal"},
            {"t": 9.75, "type": "visual_active", "source": "screen"},
        ], [], [], 1, 10.0)
        self.assertEqual([(round(x["in"], 2), round(x["out"], 2)) for x in guarded], [(0.5, 3.75), (5.25, 9.5)])

        with_sound = t.plan_smart_speeds([
            {"t": 0.0, "type": "visual_active", "source": "screen"},
            {"t": 0.25, "type": "visual_idle", "source": "screen"},
            {"t": 8.75, "type": "visual_active", "source": "screen"},
        ], [], [[4.0, 5.0]], 1, 9.0)
        self.assertEqual([(round(x["in"], 2), round(x["out"], 2)) for x in with_sound], [(0.5, 3.6), (5.4, 8.5)])

        # Silence + a quiet pointer does not prove the screen is idle: keyboard-driven activity is not
        # captured by design, so an old/mouse-only log must never create a speed suggestion.
        self.assertEqual(t.plan_smart_speeds([
            {"t": 0.0, "type": "recording_started", "source": "screen"},
            {"t": 4.0, "type": "move", "source": "screen", "x": 0.5, "y": 0.5},
        ], [], [], 1, 12.0), [])

    def test_smart_speed_mapping_splits_cuts_reuse_and_never_targets_camera(self):
        timeline = t.edit_time_map([
            {"take": 4, "kind": "screen", "in": 1.0, "out": 5.0},
            {"take": 4, "kind": "camera", "in": 1.0, "out": 5.0},
            {"take": 4, "kind": "screen", "in": 2.0, "out": 5.0, "rate": 2.0},
        ], lead=0.1)
        idle = {"id": "ss-aaaaaaaaaaaa", "take": 4, "kind": "screen", "in": 1.5, "out": 4.5,
                "rate": 1.5, "reason": "idle_silence"}
        mapped = t.map_smart_speeds(timeline, 4, [idle])
        self.assertEqual(len(mapped), 2)
        self.assertEqual([x["span"] for x in mapped], [0, 2])
        self.assertEqual([(round(x["output_in"], 2), round(x["output_out"], 2)) for x in mapped],
                         [(0.6, 3.6), (8.1, 9.35)])
        self.assertEqual([round(x["suggested_output_duration"], 3) for x in mapped], [2.0, 0.833])
        tiny = t.edit_time_map([{"take": 4, "kind": "screen", "in": 2.0, "out": 3.2}])
        self.assertEqual(t.map_smart_speeds(tiny, 4, [idle]), [])

    def test_suggest_smart_speed_is_read_only_fingerprinted_and_refuses_to_guess_without_words(self):
        self.add_take(n=1, secs=12, kind="screen", size="160x120")
        events_path = t.capture_events_file(self.s, 1)
        os.makedirs(os.path.dirname(events_path), exist_ok=True)
        with open(events_path, "w") as f:
            f.write(json.dumps({"v": 1, "type": "header", "take": 1, "source": "screen", "clock": "screen_pts",
                                "coordinates": "display_normalized_top_left",
                                "display": {"id": 1, "x": 0, "y": 0, "width": 160, "height": 120}}) + "\n")
            for e in [
                {"t": 0.0, "type": "visual_active", "source": "screen"},
                {"t": 0.6, "type": "visual_idle", "source": "screen"},
                {"t": 3.7, "type": "visual_active", "source": "screen"},
                {"t": 8.6, "type": "visual_idle", "source": "screen"},
                {"t": 11.7, "type": "visual_active", "source": "screen"},
            ]:
                f.write(json.dumps(e) + "\n")
        words_path = os.path.splitext(os.path.join(self.s, "take-01-screen.mov"))[0] + ".words.json"
        t.write_json(words_path, {"v": 2, "clock": "video", "duration": 12.0, "onsets": 1,
                                  "words": [{"word": "hello", "start": 5.0, "end": 6.0}], "sounds": []})
        with open(events_path, "rb") as f:
            events_before = f.read()
        with open(words_path, "rb") as f:
            words_before = f.read()

        self.clip("edits/hook-v1.mp4", secs=12)
        t.write_json(os.path.join(self.s, "edits", "hook-v1.recipe.json"),
                     {"name": "hook", "edit": "edits/hook-v1.mp4",
                      "cut": [{"take": 1, "kind": "screen", "in": 0.0, "out": 12.0}],
                      "frame": {"shape": "source"}})
        mapped = t.t_suggest_smart_speed({"session": self.s, "take": 1, "edit": "hook-v1"})
        self.assertEqual(mapped["planner"], "idle_silence_v1")
        self.assertFalse(mapped["applied"])
        self.assertEqual(mapped["base"], "hook-v1")
        self.assertRegex(mapped["plan"], r"^[0-9a-f]{64}$")
        self.assertEqual(mapped["rate"], 1.5)
        self.assertEqual(len(mapped["suggestions"]), 2)
        self.assertEqual(len(mapped["applicable_ids"]), 2)
        self.assertEqual(len(mapped["output"]), 2)
        self.assertGreater(mapped["projected_savings_s"], 0)
        self.assertEqual(mapped["inputs"][0]["events_sha256"], hashlib.sha256(events_before).hexdigest())
        self.assertEqual(mapped["inputs"][0]["words_sha256"], hashlib.sha256(words_before).hexdigest())
        self.assertIsInstance(mapped["inputs"][0]["media"], list)
        self.assertIn("not enabled", mapped["next"])
        with open(events_path, "rb") as f:
            self.assertEqual(f.read(), events_before)
        with open(words_path, "rb") as f:
            self.assertEqual(f.read(), words_before)

        # Old event logs remain safe: no visual-idle state means no inference from mouse inactivity.
        with open(events_path, "w") as f:
            f.write(json.dumps({"v": 1, "type": "header", "take": 1, "source": "screen", "clock": "screen_pts",
                                "coordinates": "display_normalized_top_left",
                                "display": {"id": 1, "x": 0, "y": 0, "width": 160, "height": 120}}) + "\n")
            f.write(json.dumps({"t": 4.0, "type": "move", "source": "screen", "x": 0.5, "y": 0.5}) + "\n")
        old = t.t_suggest_smart_speed({"session": self.s, "take": 1, "edit": "hook-v1"})
        self.assertEqual(old["suggestions"], [])
        self.assertIn("will not infer idle", old["skipped"][0]["why"])

        # With visual evidence restored, missing audio timing also fails closed.
        with open(events_path, "wb") as f:
            f.write(events_before)
        os.remove(words_path)
        missing = t.t_suggest_smart_speed({"session": self.s, "take": 1, "edit": "hook-v1"})
        self.assertEqual(missing["suggestions"], [])
        self.assertIn("will not guess over audio", missing["skipped"][0]["why"])

        # A screen movie with no microphone stream needs no speech-model evidence: visual-idle alone
        # is sufficient because there is no audio that smart-speed could distort or skip over.
        ff("-f", "lavfi", "-i", "color=black:s=160x120:r=30:d=12", "-c:v", "libx264", "-pix_fmt", "yuv420p",
           os.path.join(self.s, "take-01-screen.mov"))
        no_audio = t.t_suggest_smart_speed({"session": self.s, "take": 1, "edit": "hook-v1"})
        self.assertEqual(len(no_audio["suggestions"]), 2)
        self.assertEqual(no_audio["inputs"][0]["words_sha256"], "no_audio")

    def test_recipe_zooms_are_source_clock_screen_only_and_map_per_cut_span(self):
        self.add_take(n=1, secs=3, kind="camera", size="160x120")
        self.add_take(n=2, secs=3, kind="screen", size="320x180")
        recipe = {"name": "zoomed", "cut": [
            {"take": 1, "kind": "camera", "in": 0, "out": 1},
            {"take": 2, "kind": "screen", "in": 0, "out": 2},
            {"take": 2, "kind": "screen", "in": 0.5, "out": 1.5},
        ], "auto_zoom": self.auto_zoom([
            {"take": 2, "trigger": 1.0, "in": 0.5, "out": 1.5, "focus": {"x": 0.75, "y": 0.25}}
        ], take=2)}
        r = t.norm_recipe(self.s, recipe)
        item = r["auto_zoom"]["items"][0]
        self.assertEqual(item["scale"], 1.35)
        self.assertEqual(item["ease"], 0.18)
        t.check_recipe(self.s, r)
        t.fill_recipe(self.s, r)
        self.assertEqual([(x["width"], x["height"]) for x in r["takes"]], [(160, 120), (320, 180)])
        px, py, cw, ch = t.zoom_focus_on_canvas(r, item)
        self.assertEqual((round(px, 2), round(py, 2), cw, ch), (120.0, 37.5, 160.0, 120.0))
        self.assertEqual(tuple(round(x, 4) for x in t.zoom_focus_in_baseline(r, item)),
                         (0.75, 0.3125))
        mapped = t.map_recipe_auto_zoom(t.edit_time_map(r["cut"]), r["auto_zoom"]["items"])
        self.assertEqual([(round(x["output_in"], 2), round(x["output_out"], 2), x["span"]) for x in mapped],
                         [(1.5, 2.5, 1), (3.0, 4.0, 2)])

    def test_recipe_zoom_refuses_camera_overlap_and_a_static_crop_that_excludes_focus(self):
        self.add_take(n=1, secs=3, kind="screen", size="160x120")
        base = {"name": "zoomed", "cut": [{"take": 1, "kind": "screen", "in": 0, "out": 3}]}
        with self.assertRaisesRegex(ValueError, "kind must be screen"):
            t.norm_recipe(self.s, dict(base, auto_zoom=self.auto_zoom([
                {"kind": "camera", "trigger": 1.0, "in": 0.5, "out": 1.5}
            ])))
        overlap = t.norm_recipe(self.s, dict(base, auto_zoom=self.auto_zoom([
            {"trigger": 1.0, "in": 0.5, "out": 1.5, "focus": {"x": 0.4, "y": 0.5}},
            {"trigger": 1.6, "in": 1.4, "out": 2.0, "focus": {"x": 0.7, "y": 0.5}},
        ])))
        with self.assertRaisesRegex(ValueError, "overlaps"):
            t.check_recipe(self.s, overlap)
        cropped = t.norm_recipe(self.s, dict(base,
            frame={"shape": "source", "crop": {"x": 40, "y": 20, "w": 80, "h": 80}},
            auto_zoom=self.auto_zoom([
                {"trigger": 1.0, "in": 0.5, "out": 1.5, "focus": {"x": 0.05, "y": 0.5}}
            ])))
        t.check_recipe(self.s, cropped)
        with self.assertRaisesRegex(ValueError, "baseline viewport"):
            t.fill_recipe(self.s, cropped)

    def test_zoom_picture_chain_is_dynamic_but_keeps_authored_overlays_outside_it(self):
        self.add_take(n=1, secs=3, kind="screen", size="160x120")
        self.clip("_edit/zoomed/layer.mov", secs=1)
        r = t.norm_recipe(self.s, {"name": "zoomed", "cut": [{"take": 1, "kind": "screen", "in": 0, "out": 3}],
                                   "frame": {"shape": "source", "w": 90, "h": 160},
                                   "auto_zoom": self.auto_zoom([
                                       {"trigger": 1.2, "in": 0.8, "out": 2.2,
                                        "focus": {"x": 0.55, "y": 0.5}, "scale": 1.4}
                                   ]),
                                   "over": [{"file": "_edit/zoomed/layer.mov", "at": 1.0, "out": 1.0}]})
        t.check_recipe(self.s, r)
        t.fill_recipe(self.s, r)
        chain = t.picture_chain(r, r["cut"], 90, 160, 30)
        self.assertIn("eval=frame", chain)
        self.assertIn("cos(PI", chain)
        self.assertIn("crop=90:160", chain)
        self.assertEqual(chain.count("scale="), 1)
        self.assertIn("force_original_aspect_ratio=increase", chain)
        plan = t.render_plan(self.s, r, "TMP", "OUT.mp4", {"length": 3.0, "cut": r["cut"]})
        graph = plan["picture"][plan["picture"].index("-filter_complex") + 1]
        self.assertIn("overlay=", graph)
        self.assertLess(graph.index("eval=frame"), graph.index("overlay="))

        # Neutral time must be pixel-identical to the legacy no-zoom framing, including awkward
        # aspect ratios where the visible source viewport is fractional (160x120 -> 90x160).
        pattern = os.path.join(self.s, "pattern.mp4")
        ff("-f", "lavfi", "-i", "testsrc2=s=160x120:r=30:d=3", "-c:v", "libx264", "-pix_fmt", "yuv420p", pattern)
        legacy = "scale=90:160:force_original_aspect_ratio=increase,crop=90:160,setsar=1,fps=30,format=yuv420p"
        dynamic = chain.removeprefix("[0:v]")
        def first_frame(filters):
            return subprocess.run([FFMPEG, "-v", "error", "-i", pattern, "-vf", filters,
                                   "-frames:v", "1", "-f", "rawvideo", "-pix_fmt", "rgb24", "-"],
                                  check=True, capture_output=True).stdout
        self.assertEqual(first_frame(dynamic), first_frame(legacy))

    def test_auto_zoom_baseline_geometry_and_effect_endpoint_are_strict(self):
        r = {"takes": [{"take": 1, "kind": "screen", "width": 1920, "height": 1080}],
             "frame": {"w": 1080, "h": 1920}}
        self.assertEqual(t.baseline_viewport(r), (656.25, 0.0, 607.5, 1080.0))
        r["frame"] = {"w": 1080, "h": 1080}
        self.assertEqual(t.baseline_viewport(r), (420.0, 0.0, 1080.0, 1080.0))
        r["frame"] = {"w": 1080, "h": 1350}
        self.assertEqual(t.baseline_viewport(r), (528.0, 0.0, 864.0, 1080.0))
        item = {"id": "az-aaaaaaaaaaaa", "take": 1, "kind": "screen", "trigger": 2.0,
                "in": 1.8, "out": 2.2, "focus": {"x": 0.5, "y": 0.5}, "scale": 1.35,
                "ease": 0.18, "reason": "primary_click"}
        timeline = t.edit_time_map([{"take": 1, "kind": "screen", "in": 0, "out": 2.0}])
        self.assertEqual(t.map_recipe_auto_zoom(timeline, [item]), [])
        self.assertEqual(t.map_auto_zooms(timeline, 1, [item]), [])
        item["trigger"] = 1.0
        item["in"], item["out"] = 0.8, 1.8
        timeline = t.edit_time_map([
            {"take": 1, "kind": "screen", "in": 0, "out": 2.0},
            {"take": 1, "kind": "screen", "in": 0.9, "out": 1.1},
        ])
        self.assertEqual(len(t.map_recipe_auto_zoom(timeline, [item])), 1)
        self.assertEqual(len(t.map_auto_zooms(timeline, 1, [item])), 1)

    def test_auto_zoom_preview_uses_the_same_frame_rounded_cut_as_render(self):
        self.add_take(n=1, secs=2, kind="screen", size="160x120")
        rounded = t.rounded_render_cut(self.s, [
            {"take": 1, "kind": "screen", "in": 0.0, "out": 1.016},
        ])
        self.assertAlmostEqual(rounded[0]["out"], 1.0, places=6)
        self.assertAlmostEqual(rounded[0]["len"], 1.0, places=6)
        item = {"id": "az-bbbbbbbbbbbb", "take": 1, "kind": "screen", "trigger": 1.01,
                "in": 0.9, "out": 1.2, "focus": {"x": 0.5, "y": 0.5}, "scale": 1.35,
                "ease": 0.18, "reason": "primary_click"}
        timeline = t.edit_time_map(rounded)
        self.assertEqual(t.map_auto_zooms(timeline, 1, [item]), [])
        self.assertEqual(t.map_recipe_auto_zoom(timeline, [item]), [])
        recipe = t.norm_recipe(self.s, {"name": "edge", "cut": [
            {"take": 1, "kind": "screen", "in": 0.0, "out": 1.016},
        ], "auto_zoom": self.auto_zoom([
            {"trigger": 1.01, "in": 0.9, "out": 1.2, "focus": {"x": 0.5, "y": 0.5}},
        ])})
        with self.assertRaisesRegex(ValueError, "outside the kept screen frames"):
            t.check_recipe(self.s, recipe)

    def test_auto_zoom_rounding_uses_first_source_fps_for_cut_movie_lengths(self):
        self.add_take(n=1, secs=2, kind="camera", size="160x120", rate=30)
        self.add_take(n=2, secs=2, kind="screen", size="160x120", rate=60)
        rounded = t.rounded_render_cut(self.s, [
            {"take": 1, "kind": "camera", "in": 0.0, "out": 1.0},
            {"take": 2, "kind": "screen", "in": 0.0, "out": 0.358},
        ])
        # render_run snaps the screen endpoint to its own 60 fps grid (0.35 s), then render_cut
        # quantizes the segment duration to cut.mov's first-source 30 fps grid (10 frames = 1/3 s).
        self.assertAlmostEqual(rounded[1]["out"], 0.35, places=6)
        self.assertAlmostEqual(rounded[1]["len"], 10 / 30.0, places=6)
        timeline = t.edit_time_map(rounded)
        self.assertAlmostEqual(timeline["spans"][1]["at"], 1.0, places=6)
        self.assertAlmostEqual(timeline["spans"][1]["end"], 1.0 + 10 / 30.0, places=6)

    def test_auto_zoom_inherits_null_removes_and_direct_injection_is_refused(self):
        self.add_take(n=1, secs=3, kind="screen")
        auto = self.auto_zoom([{"trigger": 1.0, "in": 0.8, "out": 2.0}])
        original = {"name": "hook", "cut": [{"take": 1, "kind": "screen", "in": 0, "out": 3}],
                    "auto_zoom": auto}
        normalized = t.norm_recipe(self.s, original)
        self.assertEqual(t.agent_part(normalized)["auto_zoom"], normalized["auto_zoom"])
        inherited = t.norm_recipe(self.s, t.merge_patch(t.agent_part(normalized), {"loudness": -16}))
        self.assertEqual(inherited["auto_zoom"], normalized["auto_zoom"])
        removed = t.norm_recipe(self.s, t.merge_patch(t.agent_part(normalized), {"auto_zoom": None}))
        self.assertNotIn("auto_zoom", removed)
        with self.assertRaisesRegex(ValueError, r"suggest_auto_zooms \+ apply_auto_zooms"):
            t.t_render_edit({"session": self.s, "recipe": original})
        # MCP dispatch forwards raw arguments; an undeclared/hidden-looking flag must not become a
        # capability for callers to bypass the verified apply path.
        with self.assertRaisesRegex(ValueError, r"suggest_auto_zooms \+ apply_auto_zooms"):
            t.t_render_edit({"session": self.s, "recipe": original, "_auto_zoom_verified": True})

    def test_apply_auto_zoom_verifies_fingerprint_and_never_mutates_base_or_raw_events(self):
        self.add_take(n=1, secs=3, kind="screen")
        path = t.capture_events_file(self.s, 1)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as f:
            f.write(json.dumps({"v": 1, "type": "header", "take": 1, "source": "screen", "clock": "screen_pts",
                                "coordinates": "display_normalized_top_left",
                                "display": {"id": 1, "x": 0, "y": 0, "width": 160, "height": 120}}) + "\n")
            f.write(json.dumps({"t": 1.0, "type": "down", "source": "screen", "x": 0.55, "y": 0.5,
                                "button": 0, "count": 1}) + "\n")
        self.clip("edits/hook-v1.mp4", secs=3)
        base_path = os.path.join(self.s, "edits", "hook-v1.recipe.json")
        t.write_json(base_path, {"name": "hook", "edit": "edits/hook-v1.mp4",
                                 "cut": [{"take": 1, "kind": "screen", "in": 0, "out": 3}],
                                 "frame": {"shape": "source"}})
        plan = t.t_suggest_auto_zooms({"session": self.s, "edit": "hook-v1", "take": 1})
        self.assertEqual(len(plan["applicable_ids"]), 1)
        captured = []
        real = t._render_edit
        t._render_edit = lambda a, allow_new_auto_zoom=False: captured.append((a, allow_new_auto_zoom)) or {
            "job": "job-autozoom", "status": "running"}
        try:
            out = t.t_apply_auto_zooms({"session": self.s, "base": plan["base"], "plan": plan["plan"],
                                        "accept": plan["applicable_ids"], "take": 1})
        finally:
            t._render_edit = real
        self.assertFalse(out["auto_zoom"]["published"])
        self.assertEqual(captured[0][0]["base"], "hook-v1")
        self.assertTrue(captured[0][1])
        self.assertNotIn("_auto_zoom_verified", captured[0][0])
        accepted = captured[0][0]["changes"]["auto_zoom"]
        self.assertEqual([x["id"] for x in accepted["items"]], plan["applicable_ids"])
        self.assertEqual(accepted["plan"], plan["plan"])

        with open(base_path, "rb") as f:
            base_before = f.read()
        with open(path, "a") as f:
            f.write(json.dumps({"t": 1.8, "type": "down", "source": "screen", "x": 0.6, "y": 0.5,
                                "button": 0, "count": 1}) + "\n")
        with open(path, "rb") as f:
            raw_before = f.read()
        with self.assertRaisesRegex(ValueError, "plan is stale"):
            t.t_apply_auto_zooms({"session": self.s, "base": plan["base"], "plan": plan["plan"],
                                  "accept": plan["applicable_ids"], "take": 1})
        with open(base_path, "rb") as f:
            self.assertEqual(f.read(), base_before)
        with open(path, "rb") as f:
            self.assertEqual(f.read(), raw_before)

    def test_render_plan_is_pure_and_the_voice_goes_in_once(self):
        self.add_take()
        song = self.music()
        cover = self.thumb()
        self.clip("_edit/hook/layer.mov")
        r = t.norm_recipe(self.s, {"name": "hook", "cut": self.CUT, "music": [{"file": song}], "cover": {"image": cover},
                                   "over": [{"file": "_edit/hook/layer.mov", "at": 1, "out": 1, "alpha": True}],
                                   "sfx": [{"file": song, "at": 3.5, "gain_db": -12}]})
        t.fill_recipe(self.s, r)
        meas = {"length": 4.0, "music": {song: -20.0}, "voice": -18.0, "gain": 1.5}
        listed = sorted(os.listdir(self.s))
        a = t.render_plan(self.s, r, "TMP", "OUT.mp4", meas)
        b = t.render_plan(self.s, r, "TMP", "OUT.mp4", meas)
        self.assertEqual(a, b)
        self.assertEqual(sorted(os.listdir(self.s)), listed)  # it writes nothing
        sound = " ".join(a["sound"])
        voice = sound.split("-filter_complex", 1)[1].split(";")[0]
        for f in ("acompressor", "afftdn", "highpass", "loudnorm", "equalizer"):
            self.assertNotIn(f, sound)
        self.assertIn("adelay=100", voice)  # the cover's 0.1 s before the voice
        self.assertIn("sidechaincompress", sound)
        self.assertIn("volume=-12.00dB", sound)  # the song to -14 LUFS once (+6), then its gain_db (-18)
        picture = a["picture"]
        self.assertEqual(" ".join(picture).count("libx264") + " ".join(a["mux"]).count("libx264"), 1)
        self.assertIn("-an", picture)
        self.assertIn("copy", a["mux"])
        self.assertIn("[cv][cb]concat", " ".join(picture))
        self.assertIn("overlay=enable='between(t,1.100,2.100)'", " ".join(picture))
        self.assertIn("volume=1.50dB", " ".join(a["mux"]))
        self.assertAlmostEqual(a["total"], 4.1)

    def test_a_quiet_mix_says_why(self):
        r = {"name": "hook", "mix": {"target": -14.0, "lufs": -20.9}, "voice": {"source": "take"},
             "checks": {"results": []}}
        v = t.render_view(self.s, "job-1", r)
        self.assertEqual(v["warnings"], ["The edit is at -20.9 LUFS, not -14: its loudest peaks hold it down (Cutmark adds "
                                         "no limiter). Clean the voice with clean_voice, then render again."])
        r["mix"]["lufs"] = -14.2
        self.assertNotIn("warnings", t.render_view(self.s, "job-1", r))

    def test_final_gain_never_passes_true_peak(self):
        self.assertEqual(t.final_gain(-14, -20, -10), 6.0)
        self.assertEqual(t.final_gain(-14, -20, -5), 4.0)
        self.assertEqual(t.final_gain(-14, float("-inf"), float("-inf")), 0.0)


class Bases(Base):
    def setUp(self):
        super().setUp()
        self.add_take()

    def published(self, name, n, recipe=True, made=None):
        rel = os.path.join("edits", "%s-v%d.mp4" % (name, n))
        self.clip(rel)
        if recipe:
            r = t.norm_recipe(self.s, {"name": name, "cut": self.CUT})
            t.fill_recipe(self.s, r)
            r.update(edit=rel, made=made or t.now_iso(), note="v%d" % n, host="this-mac",
                     parent=os.path.join("edits", "%s-v%d.mp4" % (name, n - 1)) if n > 1 else None)
            t.write_json(os.path.join(self.s, t.recipe_path(rel)), r)
        return rel

    def test_old_base_refused_unless_go_back(self):
        self.published("hook", 4)
        self.published("hook", 6)
        with self.assertRaises(ValueError) as e:
            t.pick_base(self.s, {"base": "hook-v4"})
        self.assertEqual(str(e.exception), "hook-v4 is old: hook-v6 is the newest. Use base=hook to build on hook-v6, "
                                           "or add go_back=true to build on hook-v4 on purpose.")
        base, warns = t.pick_base(self.s, {"base": "hook-v4", "go_back": True})
        self.assertEqual(base["edit"], "edits/hook-v4.mp4")
        self.assertEqual(t.pick_base(self.s, {"base": "hook"})[0]["edit"], "edits/hook-v6.mp4")

    def test_newest_without_recipe_warns(self):
        self.published("hook", 4)
        self.published("hook", 5, recipe=False)
        base, warns = t.pick_base(self.s, {"base": "hook"})
        self.assertEqual(base["edit"], "edits/hook-v4.mp4")
        self.assertEqual(warns, ["hook-v5 has no recipe: its changes are not in this base."])

    def test_two_names_need_base(self):
        self.published("hook", 1)
        self.published("hook-vertical", 1)
        with self.assertRaises(ValueError) as e:
            t.pick_base(self.s, {})
        self.assertEqual(str(e.exception), "This session has 2 edits: hook, hook-vertical. Say which one with base=<name>.")

    def test_steps_from_another_mac_do_not_run(self):
        rel = self.published("hook", 1)
        r = self.recipe(t.recipe_path(rel))
        r.update(host="other-mac", steps=[{"run": ["true"], "cwd": "_edit/hook", "makes": []}])
        t.write_json(os.path.join(self.s, t.recipe_path(rel)), r)
        with self.assertRaises(ValueError) as e:
            t.t_render_edit({"session": self.s, "base": "hook", "changes": {"cover": None}})
        self.assertEqual(str(e.exception), "hook-v1 came from another Mac. Its steps did not run. Pass steps again to run them.")

    def stub_start(self):
        started = []
        t.start_job = lambda s, cmd, outputs, label, estimate_s=None, job_id=None: started.append(job_id) or {"id": job_id}
        return started

    def test_a_base_with_a_gone_file_takes_changes_that_replace_it(self):
        old, cover = self.music("Old.wav"), self.thumb()
        rel = self.published("hook", 1)
        r = self.recipe(t.recipe_path(rel))
        r.update(t.norm_recipe(self.s, dict(t.agent_part(r), music=[{"file": old}], cover=cover)))
        t.write_json(os.path.join(self.s, t.recipe_path(rel)), r)
        os.remove(t.lib_path(old))
        os.remove(os.path.join(self.s, cover))
        started = self.stub_start()
        # Only the merged recipe must be whole: what the changes replace may be gone.
        with self.assertRaises(ValueError) as e:
            t.t_render_edit({"session": self.s, "base": "hook", "changes": {"cover": None}})
        self.assertEqual(str(e.exception), "Old.wav is gone. Pick another file for music[0].")
        out = t.t_render_edit({"session": self.s, "base": "hook",
                               "changes": {"music": [{"file": self.music("New.wav")}], "cover": None}})
        self.assertEqual(out["status"], "running")
        self.assertEqual(out["changed"]["music[0].file"], ["@library/audio/Music/Old.wav", "@library/audio/Music/New.wav"])
        self.add_take(2)
        os.remove(os.path.join(self.s, "take-01-camera.mov"))
        out = t.t_render_edit({"session": self.s, "base": "hook", "changes": {
            "music": None, "cover": None, "cut": [{"take": 2, "in": 0.5, "out": 2.5}]}})
        self.assertEqual(len(started), 2)

    def test_one_render_of_a_name_at_a_time(self):
        rid = t.new_job_id(self.s)
        os.makedirs(os.path.join(self.s, t.RENDERS))
        t.write_json(os.path.join(self.s, t.RENDERS, rid + t.RECIPE_EXT), {"name": "hook"})
        t.claimed_outputs = lambda s: {os.path.join(t.RENDERS, rid + ".mp4"): rid}
        started = self.stub_start()
        with self.assertRaises(ValueError) as e:
            t.t_render_edit({"session": self.s, "recipe": {"name": "hook", "cut": self.CUT}})
        self.assertEqual(str(e.exception), "A render of hook runs now (%s). Wait for it with get_job id=%s wait_s=50, "
                                           "or stop it with stop_job id=%s. Then call render_edit again." % (rid, rid, rid))
        self.assertEqual(started, [])
        t.t_render_edit({"session": self.s, "recipe": {"name": "hook-tall", "cut": self.CUT}})
        self.assertEqual(len(started), 1)

    def test_a_crop_larger_than_the_take_is_refused(self):
        self.stub_start()
        with self.assertRaises(ValueError) as e:
            t.t_render_edit({"session": self.s, "recipe": {"name": "hook", "cut": self.CUT, "frame": {
                "shape": "9:16", "crop": {"x": 100, "y": 0, "w": 900, "h": 900}}}})
        self.assertEqual(str(e.exception), "frame.crop is larger than the take (160x120). Give x+w <= 160, y+h <= 120.")

    def test_a_lost_render_says_render_again(self):
        rid = t.new_job_id(self.s)
        b = t.job_brief(self.s, {"id": rid, "status": "lost", "outputs": [os.path.join(t.RENDERS, rid + ".mp4")]})
        self.assertEqual(b["next"], "The render stopped (the Mac restarted or the job quit). Call render_edit again "
                                    "with the same base and changes.")

    def test_broken_recipe_is_never_rewritten(self):
        rel = self.published("hook", 1)
        p = os.path.join(self.s, t.recipe_path(rel))
        with open(p, "w") as f:
            f.write("{not json")
        with self.assertRaises(ValueError) as e:
            t.t_get_edit_recipe({"session": self.s, "edit": "hook-v1"})
        self.assertIn("cannot read edits/hook-v1.recipe.json", str(e.exception))
        with self.assertRaises(ValueError):
            t.t_render_edit({"session": self.s, "base": "hook-v1", "changes": {}})
        self.assertEqual(text(p), "{not json")

    def test_get_edit_recipe_lineage_stops_at_a_missing_parent(self):
        self.published("hook", 2)
        self.published("hook", 3)
        out = t.t_get_edit_recipe({"session": self.s, "edit": "hook"})
        self.assertEqual(out["recipe"]["edit"], "edits/hook-v3.mp4")
        self.assertEqual([x["edit"] for x in out["lineage"]], ["edits/hook-v2.mp4"])
        self.assertEqual(out["missing"], ["edits/hook-v1.mp4"])
        self.assertEqual(t.t_get_edit_recipe({"session": self.s, "edit": "hook-v2"})["newer"], ["edits/hook-v3.mp4"])

    def test_get_session_shows_the_recipe_and_hides_its_files(self):
        self.clip("edits/old-v1.mp4")
        g = t.t_get_session({"session": self.s})
        self.assertIsNone(g["edit_recipe"])
        self.assertIn("No recipe yet", g["edit_recipe_note"])
        self.published("hook", 1)
        self.clip("_edit/hook/layer.mov")
        g = t.t_get_session({"session": self.s})
        short = g["edit_recipe"]
        self.assertEqual(short["edit"], "edits/hook-v1.mp4")
        self.assertEqual(short["cut"], "2 parts")
        self.assertEqual(short["full"], "get_edit_recipe edit=hook-v1")
        self.assertEqual(g["edit_log"][0]["note"], "v1")
        files = [x["file"] for x in g["assets"]]
        self.assertNotIn("edits/hook-v1.recipe.json", files)
        self.assertFalse(any(f.startswith("_edit") for f in files))
        self.assertEqual(g["warnings"], [])

    def test_a_new_clean_voice_warns(self):
        rel = self.published("hook", 1)
        base = self.recipe(t.recipe_path(rel))
        key = t.voice_key(1, "camera")
        base["voice"] = {"source": "clean", "keys": {key: "voice/%s.wav" % key},
                         "chain": {key: {"steps": [], "strength": 1.0, "loudness": "normal"}}}
        os.makedirs(os.path.join(self.s, "voice"))
        ff("-f", "lavfi", "-i", "sine=d=6", "-ac", "1", "-ar", "48000", t.voice_files(self.s, key)["mix"])
        t.write_voice(self.s, key, {"state": "done", "on": True, "strength": 0.5, "loudness": "normal", "steps": []})
        r = t.norm_recipe(self.s, t.agent_part(base))
        warns = t.fill_recipe(self.s, r, base)
        self.assertEqual(warns, ["The clean voice changed since hook-v1 (new strength). This version uses the new one."])

    def test_next_path_counts_a_claim(self):
        self.published("hook", 2)
        t.write_json(os.path.join(self.s, "edits", "hook-v3.recipe.json"), {"name": "hook", "render_id": "job-x"})
        self.assertEqual(t.t_next_path({"kind": "edit", "name": "hook", "session": self.s})["version"], 4)


class Publish(Base):
    def setUp(self):
        super().setUp()
        self.add_take()

    def test_publish_writes_version_recipe_words_and_moves_the_check(self):
        rid = self.fake_render()
        t.save_check(self.s, os.path.join(t.RENDERS, rid + ".mp4"), {"v": 2, "mtime": 0, "results": []})
        os.makedirs(os.path.join(self.s, "_edit", "hook", "node_modules"))
        with open(os.path.join(self.s, "_edit", "hook", "index.html"), "w") as f:
            f.write("<html>")
        with open(os.path.join(self.s, "_edit", "hook", "node_modules", "x.js"), "w") as f:
            f.write("x")
        before = time.time()
        out = t.t_publish_edit({"session": self.s, "render": rid, "note": "First cut."})
        self.assertEqual(out["edit"], "edits/hook-v1.mp4")
        r = self.recipe("edits/hook-v1.recipe.json")
        self.assertEqual((r["note"], r["edit"], r["render_id"], r["fixed"], r["accepted"]),
                         ("First cut.", "edits/hook-v1.mp4", rid, [], []))
        self.assertTrue(os.path.exists(os.path.join(self.s, "edits/hook-v1.words.json")))
        self.assertFalse(os.path.exists(os.path.join(self.s, t.RENDERS, rid + ".mp4")))
        self.assertGreaterEqual(os.path.getmtime(os.path.join(self.s, "edits/hook-v1.mp4")), before - 1)
        checks = jload(os.path.join(self.s, "checks.json"))
        self.assertIn("edits/hook-v1.mp4", checks)
        self.assertNotIn(os.path.join(t.RENDERS, rid + ".mp4"), checks)
        self.assertEqual(r["src"], "_edit/hook/.versions/v1")
        self.assertTrue(os.path.exists(os.path.join(self.s, "_edit/hook/.versions/v1/index.html")))
        self.assertFalse(os.path.exists(os.path.join(self.s, "_edit/hook/.versions/v1/node_modules")))
        self.assertEqual(self.opened, [os.path.join(self.s, "edits/hook-v1.mp4")])
        with self.assertRaises(ValueError) as e:
            t.t_publish_edit({"session": self.s, "render": rid, "note": "Again."})
        self.assertEqual(str(e.exception), "This render is saved already as edits/hook-v1.mp4.")

    def test_note_rules(self):
        rid = self.fake_render()
        with self.assertRaises(ValueError) as e:
            t.t_publish_edit({"session": self.s, "render": rid, "note": "x" * 61})
        self.assertEqual(str(e.exception), "note is too long: at most 60 characters.")
        with self.assertRaises(ValueError):
            t.t_publish_edit({"session": self.s, "render": rid, "note": " "})

    def test_failed_check_refuses_and_accept_saves(self):
        rid = self.fake_render(passed=False)
        with self.assertRaises(ValueError) as e:
            t.t_publish_edit({"session": self.s, "render": rid, "note": "x"})
        self.assertIn("1 check fails on the render: av_sync (The sound is late.)", str(e.exception))
        self.assertIn("Nothing was saved.", str(e.exception))
        self.assertFalse(os.path.isdir(os.path.join(self.s, "edits")) and os.listdir(os.path.join(self.s, "edits")))
        out = t.t_publish_edit({"session": self.s, "render": rid, "note": "x",
                                "accept": [{"rule": "av_sync", "why": "On purpose."}]})
        self.assertEqual(out["checks"]["accepted"], ["av_sync (The sound is late.)"])
        self.assertEqual(self.recipe("edits/hook-v1.recipe.json")["accepted"], [{"rule": "av_sync", "why": "On purpose."}])

    def test_accept_by_rule_id(self):
        rid = self.fake_render()
        p = os.path.join(self.s, t.RENDERS, rid + t.RECIPE_EXT)
        r = jload(p)
        r["checks"]["results"].append({"rule": "sound-4", "pass": False, "say": "Pause."})
        t.write_json(p, r)
        out = t.t_publish_edit({"session": self.s, "render": rid, "note": "x",
                                "accept": [{"rule": "sound-4", "why": "The pause is on purpose."}]})
        self.assertTrue(out["checks"]["passed"])

    def test_a_version_saved_during_the_render_refuses(self):
        rid = self.fake_render(started="2020-01-01T00:00:00Z")
        self.clip("edits/hook-v1.mp4")
        with self.assertRaises(ValueError) as e:
            t.t_publish_edit({"session": self.s, "render": rid, "note": "x"})
        self.assertEqual(str(e.exception), "hook-v1 was saved while this render ran, and its changes are not in it. "
                                           "Render again with base=hook.")
        out = t.t_publish_edit({"session": self.s, "render": rid, "note": "x", "go_back": True})
        self.assertEqual(out["edit"], "edits/hook-v2.mp4")

    def test_two_publishes_at_once_take_two_versions(self):
        a, b = self.fake_render(), self.fake_render()
        got, errs = [], []

        def go(rid):
            try:
                got.append(t.t_publish_edit({"session": self.s, "render": rid, "note": rid, "go_back": True})["edit"])
            except Exception as e:
                errs.append(e)
        th = [threading.Thread(target=go, args=(x,)) for x in (a, b)]
        [x.start() for x in th]
        [x.join() for x in th]
        self.assertEqual(errs, [])
        self.assertEqual(sorted(got), ["edits/hook-v1.mp4", "edits/hook-v2.mp4"])

    def test_the_same_render_published_twice_at_once_saves_once(self):
        rid = self.fake_render()
        got, errs = [], []

        def slow(src, dst):
            time.sleep(0.3)
            return REAL["link_noclobber"](src, dst)
        t.link_noclobber = slow

        def go():
            try:
                got.append(t.t_publish_edit({"session": self.s, "render": rid, "note": "Twice."})["edit"])
            except ValueError as e:
                errs.append(str(e))
        th = [threading.Thread(target=go) for _ in range(2)]
        [x.start() for x in th]
        [x.join() for x in th]
        self.assertEqual(got, ["edits/hook-v1.mp4"])
        self.assertEqual(errs, ["This render is saved already as edits/hook-v1.mp4."])
        self.assertEqual(sorted(os.listdir(os.path.join(self.s, "edits"))),
                         ["hook-v1.mp4", "hook-v1.recipe.json", "hook-v1.words.json"])

    def test_a_render_gone_during_the_move_leaves_no_claim(self):
        rid = self.fake_render()

        def gone(src, dst):
            os.remove(src)
            return REAL["link_noclobber"](src, dst)
        t.link_noclobber = gone
        with self.assertRaises(ValueError) as e:
            t.t_publish_edit({"session": self.s, "render": rid, "note": "x"})
        self.assertIn("The render %s is gone." % rid, str(e.exception))
        self.assertEqual(os.listdir(os.path.join(self.s, "edits")), [])

    def test_a_crash_between_claim_and_move_finishes_on_the_second_call(self):
        rid = self.fake_render()
        calls = []

        def boom(src, dst):
            calls.append(dst)
            if len(calls) == 1:
                raise OSError("crash")
            return REAL["link_noclobber"](src, dst)
        t.link_noclobber = boom
        with self.assertRaises(OSError):
            t.t_publish_edit({"session": self.s, "render": rid, "note": "x"})
        self.assertTrue(os.path.exists(os.path.join(self.s, "edits/hook-v1.recipe.json")))
        out = t.t_publish_edit({"session": self.s, "render": rid, "note": "x"})
        self.assertEqual(out["edit"], "edits/hook-v1.mp4")
        self.assertEqual(sorted(os.listdir(os.path.join(self.s, "edits"))),
                         ["hook-v1.mp4", "hook-v1.recipe.json", "hook-v1.words.json"])

    def test_another_writer_between_claim_and_move_keeps_its_file(self):
        rid = self.fake_render()

        def race(src, dst):
            if dst.endswith("hook-v1.mp4") and not os.path.exists(dst):
                with open(dst, "w") as f:  # the app's Cover got there first
                    f.write("app")
            return REAL["link_noclobber"](src, dst)
        t.link_noclobber = race
        out = t.t_publish_edit({"session": self.s, "render": rid, "note": "x", "go_back": True})
        self.assertEqual(out["edit"], "edits/hook-v2.mp4")
        self.assertEqual(text(os.path.join(self.s, "edits/hook-v1.mp4")), "app")
        self.assertFalse(os.path.exists(os.path.join(self.s, "edits/hook-v1.recipe.json")))
        self.assertTrue(os.path.exists(os.path.join(self.s, "edits/hook-v2.recipe.json")))

    def test_link_falls_back_to_a_copy_and_never_overwrites(self):
        src = os.path.join(self.root, "a.bin")
        with open(src, "w") as f:
            f.write("a")
        dst = os.path.join(self.root, "b.bin")
        real = os.link
        t.os.link = lambda a, b: (_ for _ in ()).throw(OSError(18, "cross-device"))
        try:
            t.link_noclobber(src, dst)
        finally:
            t.os.link = real
        self.assertEqual(text(dst), "a")
        self.assertFalse(os.path.exists(src))
        with open(src, "w") as f:
            f.write("c")
        with self.assertRaises(FileExistsError):
            t.link_noclobber(src, dst)
        self.assertEqual(text(dst), "a")

    def test_freeze_skips_and_falls_back(self):
        d = os.path.join(self.s, "_edit", "hook")
        os.makedirs(os.path.join(d, ".cache"))
        with open(os.path.join(d, "a.txt"), "w") as f:
            f.write("a")
        with open(os.path.join(d, "big.mov"), "w") as f:
            f.write("b")
        t.clone_file = lambda a, b: False
        real = t.FREEZE_MAX
        t.FREEZE_MAX = 0
        try:
            src, skipped = t.freeze_sources(self.s, "hook", 1)
        finally:
            t.FREEZE_MAX = real
        self.assertEqual(src, "_edit/hook/.versions/v1")
        self.assertEqual(sorted(skipped), ["_edit/hook/a.txt", "_edit/hook/big.mov"])
        t.freeze_sources(self.s, "hook", 2)
        self.assertTrue(os.path.exists(os.path.join(d, ".versions/v2/a.txt")))
        self.assertFalse(os.path.exists(os.path.join(d, ".versions/v2/.versions")))

    def test_posts_follow_the_edit_and_a_starred_post_stays(self):
        self.clip("edits/hook-v1.mp4")
        self.clip("edits/hook-vertical-v1.mp4", size="90x160")
        os.utime(os.path.join(self.s, "edits/hook-vertical-v1.mp4"), (time.time() - 100,) * 2)
        os.utime(os.path.join(self.s, "edits/hook-v1.mp4"), (time.time() - 50,) * 2)
        cover = self.thumb()
        t.write_post_file(self.s, {}, "LinkedIn text\n", "linkedin")
        t.write_post_file(self.s, {"media": "edits/hook-v1.mp4"}, "X text\n", "x")  # starred by the user
        t.write_post_file(self.s, {"media": "edits/hook-vertical-v1.mp4", "media_by": "cutmark",
                                   "cover_from": "edits/a.mp4", "cover_video": "edits/b.mp4"}, "Tall\n", "vertical")
        t.write_post_file(self.s, {"media": "edits/hook-v1.mp4", "media_by": "cutmark", "cover_from": "edits/hook-v0.mp4",
                                   "cover_video": "edits/hook-v1.mp4", "cover": "thumbnails/old.png"}, "Wide\n", "youtube")
        rid = self.fake_render(size="160x90", extra={"cover": {"image": cover, "seconds": 0.1}})
        out = t.t_publish_edit({"session": self.s, "render": rid, "note": "x", "go_back": True})
        self.assertEqual(out["edit"], "edits/hook-v2.mp4")
        self.assertEqual(out["posts"]["linkedin"], "edits/hook-v2.mp4")
        self.assertEqual(out["posts"]["x"], "edits/hook-v1.mp4 (kept: The user picked it)")
        self.assertEqual(out["posts"]["vertical"], "edits/hook-vertical-v1.mp4 (kept: other shape)")
        self.assertEqual(out["posts"]["youtube"], "edits/hook-v2.mp4")
        li, _ = t.post_file(self.s, "linkedin")
        self.assertEqual((li["media"], li["media_by"], li["cover"]), ("edits/hook-v2.mp4", "cutmark", cover))
        x, text = t.post_file(self.s, "x")
        self.assertEqual((x["media"], x.get("media_by"), text), ("edits/hook-v1.mp4", None, "X text\n"))
        yt, _ = t.post_file(self.s, "youtube")
        self.assertEqual((yt["media"], yt["cover"], yt.get("cover_from"), yt.get("cover_video")),
                         ("edits/hook-v2.mp4", cover, None, None))
        v, _ = t.post_file(self.s, "vertical")
        self.assertEqual(v["media"], "edits/hook-vertical-v1.mp4")

    def test_a_post_without_pick_on_another_edit_stays_on_it(self):
        self.clip("edits/intro-v1.mp4")
        t.write_post_file(self.s, {}, "LinkedIn\n", "linkedin")
        rid = self.fake_render()
        out = t.t_publish_edit({"session": self.s, "render": rid, "note": "x"})
        self.assertEqual(out["posts"]["linkedin"], "edits/intro-v1.mp4 (kept: another edit)")
        self.assertEqual(t.post_file(self.s, "linkedin")[0]["media"], "edits/intro-v1.mp4")

    def test_a_vertical_post_without_pick_follows_its_tall_edit(self):
        self.clip("edits/short-v1.mp4", size="90x160")
        os.utime(os.path.join(self.s, "edits/short-v1.mp4"), (time.time() - 100,) * 2)
        self.clip("edits/wide-v1.mp4")
        t.write_post_file(self.s, {}, "Tall\n", "vertical")
        rid = self.fake_render(name="short", size="90x160")
        out = t.t_publish_edit({"session": self.s, "render": rid, "note": "x", "go_back": True})
        self.assertEqual(out["posts"]["vertical"], "edits/short-v2.mp4")

    def test_x_follows_a_linkedin_star(self):
        self.clip("edits/hook-v1.mp4")
        t.write_post_file(self.s, {"media": "edits/hook-v1.mp4"}, "LinkedIn\n", "linkedin")
        t.write_post_file(self.s, {}, "X\n", "x")
        rid = self.fake_render()
        out = t.t_publish_edit({"session": self.s, "render": rid, "note": "x", "go_back": True})
        self.assertEqual(out["posts"]["x"], "edits/hook-v1.mp4 (kept: The user picked it)")
        self.assertIsNone(t.post_file(self.s, "x")[0].get("media"))

    def test_a_post_cover_missing_from_the_recipe_warns(self):
        self.thumb()
        t.write_post_file(self.s, {"cover": "thumbnails/hook-v1.png"}, "LinkedIn\n", "linkedin")
        r = t.t_render_edit({"session": self.s, "recipe": {"name": "hook", "cut": [{"take": 1, "in": 0.5, "out": 1.5}]}})
        self.assertIn("The LinkedIn post has a cover, and this version has none. Add cover to the recipe to keep it.",
                      r["warnings"])
        t.t_get_job({"id": r["job"], "wait_s": 50})

    def test_set_post_marks_its_pick(self):
        self.clip("edits/hook-v1.mp4")
        t.t_set_post({"session": self.s, "text": "Hi", "media": "edits/hook-v1.mp4"})
        self.assertEqual(t.post_file(self.s)[0]["media_by"], "cutmark")
        t.t_set_post({"session": self.s, "text": "Hi again"})
        self.assertEqual(t.post_file(self.s)[0]["media_by"], "cutmark")

    def test_replies_resolve_with_the_new_version(self):
        self.clip("edits/hook-v1.mp4")
        t.write_comments(self.s, {"comments": [
            {"id": "c1", "file": "edits/hook-v1.mp4", "text": "Too loud", "start": 1.0, "status": "open"},
            {"id": "c2", "file": "edits/hook-v1.mp4", "text": "Cut this", "start": 2.0, "status": "open"}]})
        rid = self.fake_render()
        with self.assertRaises(ValueError) as e:
            t.t_publish_edit({"session": self.s, "render": rid, "note": "x", "go_back": True,
                              "replies": [{"id": "c1", "text": "Softer."}]})
        self.assertIn("Give each reply a lesson (c1)", str(e.exception))
        self.assertFalse(os.path.exists(os.path.join(self.s, "edits/hook-v2.mp4")))
        out = t.t_publish_edit({"session": self.s, "render": rid, "note": "Music softer.", "go_back": True,
                                "replies": [{"id": "c1", "text": "Softer.", "lesson": "one-off"},
                                            {"id": "c2", "text": "Cut.", "lesson": "one-off"}]})
        self.assertEqual(out["replied"], ["c1", "c2"])
        self.assertEqual(out["open_comments"], 0)
        cs = {c["id"]: c for c in t.read_comments(self.s)["comments"]}
        self.assertEqual(cs["c1"]["status"], "resolved")
        self.assertEqual(cs["c1"]["replies"][-1]["file"], "edits/hook-v2.mp4")
        self.assertEqual(self.recipe("edits/hook-v2.recipe.json")["fixed"], ["c1", "c2"])

    def test_old_renders_go_to_the_trash(self):
        old, kept, busy = self.fake_render(), self.fake_render(), self.fake_render()
        week = time.time() - 8 * 86400
        for rid in (old, kept, busy):
            os.utime(os.path.join(self.s, t.RENDERS, rid + t.RECIPE_EXT), (week, week))
        os.makedirs(os.path.join(self.s, "edits"))
        t.write_json(os.path.join(self.s, "edits", "hook-v1.recipe.json"), {"render_id": kept})
        real = t.claimed_outputs
        t.claimed_outputs = lambda s: {os.path.join(t.RENDERS, busy + ".mp4"): busy}
        try:
            t.sweep_renders(self.s)
        finally:
            t.claimed_outputs = real
        gone = {os.path.basename(p) for p in self.trashed}
        self.assertIn(old + ".mp4", gone)
        self.assertIn(old + t.RECIPE_EXT, gone)
        self.assertFalse(any(kept in g or busy in g for g in gone))

    def test_a_stopped_render_frees_its_parts_at_once(self):
        d = os.path.join(self.s, t.RENDERS)
        for rid in ("job-dead01", "job-live01"):
            os.makedirs(os.path.join(d, rid + ".tmp"))
            with open(os.path.join(d, rid + ".tmp", "cut.mov"), "w") as f:
                f.write("prores")
            with open(os.path.join(d, rid + ".mp4.part"), "w") as f:
                f.write("part")
        t.claimed_outputs = lambda s: {os.path.join(t.RENDERS, "job-live01.mp4"): "job-live01"}
        t.sweep_renders(self.s)
        left = sorted(os.listdir(d))
        self.assertNotIn("job-dead01.tmp", left)
        self.assertNotIn("job-dead01.mp4.part", left)
        self.assertIn("job-live01.tmp", left)
        self.assertIn("job-live01.mp4.part", left)


class Render(Base):
    """Real renders, as jobs."""

    def test_apply_auto_zooms_starts_a_checked_unpublished_render(self):
        self.add_take(n=1, secs=3, kind="screen", size="160x120")
        first = self.render(recipe={"name": "hook", "cut": [{"take": 1, "kind": "screen", "in": 0, "out": 3}]})
        t.t_publish_edit({"session": self.s, "render": first["job"], "note": "Base screen cut.",
                          "accept": [{"rule": x.split(" ")[0], "why": "Base screen cut."}
                                     for x in first["checks"].get("failed", [])]})
        path = t.capture_events_file(self.s, 1)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as f:
            f.write(json.dumps({"v": 1, "type": "header", "take": 1, "source": "screen", "clock": "screen_pts",
                                "coordinates": "display_normalized_top_left",
                                "display": {"id": 1, "x": 0, "y": 0, "width": 160, "height": 120}}) + "\n")
            f.write(json.dumps({"t": 1.0, "type": "down", "source": "screen", "x": 0.55, "y": 0.5,
                                "button": 0, "count": 1}) + "\n")
        plan = t.t_suggest_auto_zooms({"session": self.s, "edit": "hook-v1", "take": 1})
        out = t.t_apply_auto_zooms({"session": self.s, "base": plan["base"], "plan": plan["plan"],
                                    "accept": plan["applicable_ids"], "take": 1, "wait_s": 120})
        self.assertEqual(out["status"], "done")
        self.assertFalse(out["auto_zoom"]["published"])
        self.assertFalse(os.path.exists(os.path.join(self.s, "edits", "hook-v2.mp4")))
        rr = self.recipe(os.path.join(t.RENDERS, out["job"] + t.RECIPE_EXT))
        self.assertEqual(rr["auto_zoom"]["plan"], plan["plan"])
        self.assertEqual([x["id"] for x in rr["auto_zoom"]["items"]], plan["applicable_ids"])
        p = probe(os.path.join(self.s, out["render"]))
        v = next(x for x in p["streams"] if x["codec_type"] == "video")
        self.assertEqual((v["width"], v["height"], v["r_frame_rate"]), (160, 120, "30/1"))
        self.assertAlmostEqual(float(p["format"]["duration"]), 3.0, delta=0.04)

    def test_source_clock_zoom_renders_with_fixed_output_size_and_duration(self):
        self.add_take(n=1, secs=3, kind="screen", size="160x120")
        r = t._render_edit({"session": self.s, "wait_s": 120,
                            "recipe": {"name": "screen-zoom",
                                       "cut": [{"take": 1, "kind": "screen", "in": 0, "out": 3}],
                                       "frame": {"shape": "source", "w": 90, "h": 160},
                                       "auto_zoom": self.auto_zoom([
                                           {"trigger": 1.2, "in": 0.7, "out": 2.3,
                                            "focus": {"x": 0.55, "y": 0.5}, "scale": 1.35}
                                       ])}}, allow_new_auto_zoom=True)
        self.assertEqual(r.get("status"), "done", r)
        p = probe(os.path.join(self.s, r["render"]))
        v = next(x for x in p["streams"] if x["codec_type"] == "video")
        self.assertEqual((v["width"], v["height"], v["r_frame_rate"]), (90, 160, "30/1"))
        self.assertAlmostEqual(float(p["format"]["duration"]), 3.0, delta=0.04)
        rr = self.recipe(os.path.join(t.RENDERS, r["job"] + t.RECIPE_EXT))
        self.assertEqual(rr["auto_zoom"]["items"][0]["focus"], {"x": 0.55, "y": 0.5})
        picture = next(c for c in rr["commands"] if "-filter_complex" in c and any("eval=frame" in x for x in c))
        self.assertEqual(sum("libx264" in x for x in picture), 1)

    def test_mixed_fps_render_uses_cut_movie_grid_for_words_and_zoom_timing(self):
        self.add_take(n=1, secs=3, kind="camera", size="160x120", rate=30)
        self.add_take(n=2, secs=3, kind="screen", size="160x120", rate=60)
        r = t._render_edit({"session": self.s, "wait_s": 120,
                            "recipe": {"name": "mixed-fps-zoom", "cut": [
                                {"take": 1, "kind": "camera", "in": 0.0, "out": 1.0},
                                {"take": 2, "kind": "screen", "in": 0.0, "out": 0.358},
                                {"take": 2, "kind": "screen", "in": 0.5, "out": 1.5},
                            ], "auto_zoom": self.auto_zoom([
                                {"take": 2, "trigger": 0.8, "in": 0.6, "out": 1.2,
                                 "focus": {"x": 0.55, "y": 0.5}}
                            ], take=2)}}, allow_new_auto_zoom=True)
        self.assertEqual(r.get("status"), "done", r)
        words = self.recipe(os.path.join(t.RENDERS, r["job"] + ".words.json"))
        made = words["made_from"]["cut"]
        # The 60 fps source endpoint snaps to 0.35 s, but cut.mov is on the first source's 30 fps
        # grid, so that segment is 10 frames (1/3 s) and the next segment starts at 1.3333 s.
        self.assertAlmostEqual(made[1]["out"], 1 / 3.0, places=4)
        self.assertAlmostEqual(made[2]["at"], 1.0 + 10 / 30.0, places=4)
        rr = self.recipe(os.path.join(t.RENDERS, r["job"] + t.RECIPE_EXT))
        graph = next(x[x.index("-filter_complex") + 1] for x in rr["commands"]
                     if "-filter_complex" in x and any("eval=frame" in y for y in x))
        self.assertIn("1.43333333", graph)  # 1.3333 segment start + (0.6 - 0.5) source offset
        self.assertNotIn("1.45000000", graph)

    def test_render_publish_and_next_version(self):
        self.add_take()
        song = self.music()
        cover = self.thumb()
        r = self.render(recipe={"name": "hook", "cut": self.CUT, "music": [{"file": song}], "cover": {"image": cover}})
        rel = r["render"]
        self.assertFalse(os.path.exists(os.path.join(self.s, t.RENDERS, r["job"] + ".tmp")))
        p = probe(os.path.join(self.s, rel))
        kinds = sorted(x["codec_type"] for x in p["streams"])
        self.assertEqual(kinds, ["audio", "video"])
        v = next(x for x in p["streams"] if x["codec_type"] == "video")
        self.assertEqual((v["width"], v["height"], v["r_frame_rate"]), (160, 120, "30/1"))
        self.assertAlmostEqual(float(p["format"]["duration"]), 4.1, delta=0.04)
        self.assertLess(abs(lufs(os.path.join(self.s, rel)) - (-14.0)), 1.0)
        red = rgb_at(os.path.join(self.s, rel), 0.0)
        self.assertGreater(red[0], 180)
        self.assertLess(red[2], 80)
        job = jload(os.path.join(self.s, ".jobs", r["job"] + ".json"))
        self.assertEqual(job["label"], "New version of hook")
        self.assertEqual(job["stage"], t.RENDER_DONE)
        out = t.t_publish_edit({"session": self.s, "render": r["job"], "note": "First cut.",
                                "accept": [{"rule": x.split(" ")[0], "why": "Music under the voice."}
                                           for x in r["checks"].get("failed", [])]})
        v1 = self.recipe("edits/hook-v1.recipe.json")
        for k in ("takes", "cut", "voice", "style", "music", "sfx", "cover", "checks", "fixed", "commands", "parent",
                  "frame", "over", "inputs", "note"):
            self.assertIn(k, v1)
        self.assertEqual(v1["music"][0]["file"], song)
        self.assertEqual(v1["takes"][0]["take"], 1)
        self.assertTrue(any("libx264" in c for c in v1["commands"]))
        # The next version: change one value; only that value and Cutmark' own fields differ.
        entry = dict(v1["music"][0], gain_db=-21)
        r2 = self.render(base="hook", changes={"music": [entry]})
        self.assertEqual(r2["changed"], {"music[0].gain_db": [-18, -21]})
        self.assertEqual(r2["warnings"], [])
        t.t_publish_edit({"session": self.s, "render": r2["job"], "note": "Music softer.",
                          "accept": [{"rule": x.split(" ")[0], "why": "Music."} for x in r2["checks"].get("failed", [])]})
        v2 = self.recipe("edits/hook-v2.recipe.json")
        self.assertEqual(v2["parent"], "edits/hook-v1.mp4")
        allowed = {"music[0].gain_db", "parent", "edit", "made", "note", "render_id", "src", "fixed", "accepted",
                   "started", "rendered", "commands", "checks", "inputs", "mix"}
        diff = {k if k.startswith("music") else re.split(r"[.\[]", k)[0] for k in t.recipe_diff(v1, v2)}
        self.assertTrue(diff <= allowed, diff - allowed)
        # Same recipe, same inputs: same commands (job paths aside) and the same loudness.
        norm = lambda cs, rid: [[x.replace(rid, "JOB") for x in c] for c in cs]  # noqa: E731
        r3 = self.render(base="hook", changes={"music": [dict(entry)]})
        r3r = self.recipe(os.path.join(t.RENDERS, r3["job"] + t.RECIPE_EXT))
        self.assertEqual(norm(r3r["commands"], r3["job"]), norm(v2["commands"], v2["render_id"]))
        self.assertAlmostEqual(lufs(os.path.join(self.s, r3["render"])), lufs(os.path.join(self.s, "edits/hook-v2.mp4")),
                               delta=0.1)
        # A take renamed after v1 still resolves by number and kind.
        os.rename(os.path.join(self.s, "take-01-camera.mov"), os.path.join(self.s, "take-01-intro-camera.mov"))
        meta = t.read_meta(self.s)
        meta["takes"][0]["file"] = "take-01-intro-camera.mov"
        t.write_meta(self.s, meta)
        r4 = self.render(base="hook", changes={"cover": None, "music": []})
        self.assertAlmostEqual(r4["length_s"], 4.0, delta=0.04)

    def test_steps_and_an_alpha_layer(self):
        self.add_take()
        step = [FFMPEG, "-v", "error", "-y", "-f", "lavfi", "-i", "color=green@0.0:s=160x120:r=30:d=4,format=rgba,"
                "drawbox=x=0:y=0:w=80:h=120:color=green:t=fill", "-c:v", "qtrle", "graphics.mov"]
        r = self.render(recipe={"name": "hook", "cut": self.CUT, "steps": [{"run": step, "makes": ["graphics.mov"]}],
                                "over": [{"file": "_edit/hook/graphics.mov", "at": 0, "alpha": True}]})
        self.assertEqual(r["runs"], [step])
        out = os.path.join(self.s, r["render"])
        self.assertGreater(rgb_at(out, 0.5)[1], 40)  # the green half covers the take's black picture
        self.assertTrue(os.path.exists(os.path.join(self.s, "_edit/hook/words.json")))

    def test_get_job_and_check_edit_know_a_render(self):
        self.add_take()
        r = self.render(recipe={"name": "hook", "cut": self.CUT})
        b = t.t_get_job({"id": r["job"]})
        self.assertIn("publish_edit render=%s" % r["job"], b["next"])
        self.assertEqual(b["result"]["render"], r["render"])
        c = t.t_check_edit({"session": self.s, "file": r["render"]})
        self.assertEqual(c["file"], r["render"])

    def test_a_session_renamed_during_the_render(self):
        self.add_take()
        sid = t.session_id(self.s)
        r = t.t_render_edit({"session": self.s, "recipe": {"name": "hook", "cut": self.CUT, "steps": [
            {"run": [sys.executable, "-c", "import time; time.sleep(2)"]}]}})
        new = self.s + "-renamed"
        os.rename(self.s, new)
        t.record_move(self.s, new)
        self.s = new
        b = t.t_get_job({"id": r["job"], "wait_s": 50})
        while b["status"] in ("starting", "running"):
            b = t.t_get_job({"id": r["job"], "wait_s": 50})
        self.assertEqual(b["status"], "done", b)
        out = t.t_publish_edit({"session": sid, "render": r["job"], "note": "x",
                                "accept": [{"rule": x.split(" ")[0], "why": "test"} for x in b["result"]["checks"].get("failed", [])]})
        self.assertTrue(os.path.exists(os.path.join(new, out["edit"])))

    def test_a_failed_step_stops_with_a_plain_reason(self):
        self.add_take()
        r = t.t_render_edit({"session": self.s, "wait_s": 120, "recipe": {
            "name": "hook", "cut": self.CUT, "steps": [{"run": [sys.executable, "-c", "raise SystemExit(3)"]}]}})
        self.assertEqual(r["status"], "failed")
        self.assertEqual(r["error"], "Stopped: the graphics step failed. Nothing was saved. Ask Cutmark in the chat to "
                                     "try again.")
        self.assertFalse(os.path.exists(os.path.join(self.s, r["render"])))
        with self.assertRaises(ValueError) as e:
            t.t_publish_edit({"session": self.s, "render": r["job"], "note": "x"})
        self.assertIn("did not finish", str(e.exception))

    def test_a_step_that_hangs_is_stopped(self):
        self.add_take()
        os.environ["CUTMARK_STEP_TIMEOUT"] = "1"
        r = t.t_render_edit({"session": self.s, "wait_s": 120, "recipe": {
            "name": "hook", "cut": self.CUT, "steps": [{"run": [sys.executable, "-c", "import time; time.sleep(30)"]}]}})
        self.assertEqual(r["status"], "failed")
        self.assertIn("Stopped: the graphics step took more than 1 s.", r["error"])


if __name__ == "__main__":
    unittest.main()
