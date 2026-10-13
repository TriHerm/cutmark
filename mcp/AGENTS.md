# The `cutmark` MCP server: notes for agents

Read the root `AGENTS.md` first. This file adds what is true only in `mcp/`.

## The file

`takes_mcp.py` is the source of the whole server: one Python file, standard library only, no
packages. Keep it that way: the app packages it as `cutmark_mcp.py` and runs it with
`/usr/bin/python3` (`AgentSetup.swift`).
`clean_voice.py` and `prepare_take.py` (word times with faster-whisper) are separate because they
need packages: they run through `uv`, with ffmpeg.

The file has sections, each with a `# ---------- name ----------` line. Find one with
`grep -n '^# ----------' mcp/takes_mcp.py`. The end of the file holds `TOOLS` (every tool's name,
description, schema and function) and `handle`, the JSON-RPC loop, with the server `instructions`.

## Add or change a tool

1. Write a `t_<name>(a)` function in the section it belongs to.
2. Add its entry to `TOOLS`: name, description, input schema, required fields, function.
3. Add a test in `mcp/tests/` (below).
4. Try it by hand on a scratch library: `CUTMARK_ROOT=/tmp/lib python3 mcp/takes_mcp.py`.
5. When the workflow changes, update the skills in `skills/`.

Write each description for the agent that calls the tool: what it does, when to use it, and what
to call next. A rule for one tool goes in its description. A rule for all of Cutmark goes in the
server `instructions`. Each description goes into every chat's context, so keep it short.

## Rules that hold everywhere

- **The app reads the same files.** A section that says "same format as `Sources/Takes/<Name>.swift`"
  must stay in step with that Swift file. Change both, test both.
- **Write whole files safely.** Write to a temp file, then `os.replace`. A half-written
  `session.json` breaks the app.
- **Never empty a file you cannot read.** When a JSON file exists but does not parse, stop or skip
  it. Do not write a fresh one over it.
- **Never overwrite the user's files.** Versions get the next number (`next_path`). `stills/` and
  `assets/` are read only.
- **Rules before writes.** Tools that write a step call `need_rules(step)`: it refuses once per
  chat for rules the chat has not seen, with the rules in the refusal. Tools that only read or give
  a path call `show_rules(step)` and add the rules to the result. The seen state is
  `_library/.rules-seen/<chat>.json`, keyed by `CLAUDE_CODE_SESSION_ID`. The app deletes that file
  when the chat compacts or a run ends early. A tool that writes a file into `edits/` or
  `thumbnails/` returns `with_rules(out, step…)`, and keeps the `rules` key of a `t_next_path` it
  calls. Tests: call `t.forget_seen()` and set or pop `CLAUDE_CODE_SESSION_ID` in `setUp`.
- **Tools that load at the start.** In a Cutmark chat (`TAKES_CHAT=1`, retained as an internal
  compatibility variable) the tools in `ALWAYS_LOAD` load with the chat, not behind ToolSearch.
  Keep the set small: every Cutmark chat pays for it.
- **Long work runs as a job.** `start_job` runs a command detached: it survives the chat, and the
  app shows it in the session's Jobs row (`Sources/Takes/Jobs.swift`, same files). A tool that takes
  over about 30 s returns a job id instead of blocking. Every detached runner starts through
  `spawn_detached`, never a plain `Popen`: the chat kills its own process tree when it stops.
  A job's command may print `TAKES_STAGE <a few words>`: the runner saves it as the job's `stage`,
  and the Jobs row shows it ("Mixing the sound · 40%").
- **Take time is video time.** Every WAV taken from a take uses `extract_voice`
  (`aresample=async=1:first_pts=0`). Plain `-vn` drops the take's audio offset (0.16-0.24 s) and
  puts the voice 5 frames early. Pair a voice WAV with take times through `voice_offset`.
- **A session has an id.** `resolve_session` accepts the id, an old path (`.moves.json`) or, after
  a project rename, the folder name. Every folder move goes through `record_move` /
  `Store.moveSession`.
- **One segment shape.** `{take, in, out, kind?}` in seconds of the take: `cut_take` segments,
  `rough_cut` cut, recipe `cut`. `_work/` keeps the newest 5 versions per name.
- **An edit is a recipe.** `render_edit` builds a recipe as a job (cut in ProRes, steps, one picture
  encode, one sound mix, mux, `check_file`) and `publish_edit` saves it as `edits/<name>-vN.mp4` with
  `<name>-vN.recipe.json` (written once, never changed). The field rules are at the top of the
  "edit recipes" section. Only takes, the clean voice, music and sfx files and picture layers go in:
  never a file from `edits/` as sound. A version number is claimed by creating its recipe with
  `O_EXCL`, and the video moves in with `link_noclobber`: `versions_in`, `next_path` and the app's
  `Cover.next` count a recipe with no video as taken. A post moves to a new version only when it has no
  pick or `media_by: takes`; the user's star clears `media_by`. `render_plan` is pure: test it directly.
- **Built-in checks compare an edit with its take.** A new one needs a synthetic test that fails
  it and one that passes (`mcp/tests/test_check_edit.py`, media from `check_media.py`). `say` is
  for the user: plain words, no names.
  `edit_source` reads the take: the `source` argument (align must still find 25% of the edit in
  it), the edit's own `made_from`, then the `_work` cut the edit was rendered from (found by align).
  A check fails only on a known take; a cut next to voice from no segment (a pick-up from another
  take) is not judged.
- **Private tools.** `SOCIAL` and `BLOG` switch off the private tools. The public copy sets both to
  `False`. A new private tool goes in `SOCIAL_TOOLS`; `test_private_tools.py` checks the list.

## Tests

- One file per area: `mcp/tests/test_<area>.py`, with `unittest`.
- `setUp` makes a temp folder, sets `os.environ["CUTMARK_ROOT"]` or the legacy test-compatible
  `TAKES_ROOT` to it and clears global state such
  with `t.forget_seen()`. `tearDown` removes the folder and the variable. `test_lessons.py` is a good
  model.
- Call the tool functions directly (`t.t_set_post({...})`) and check the files on disk, not only
  the return value.
- No network: replace the HTTP function with a fake (`t.eleven_http = fake`) and put the real one
  back in `tearDown`. No real keys.
- Run only these tests: `python3 -m unittest discover -q -s mcp/tests`.
