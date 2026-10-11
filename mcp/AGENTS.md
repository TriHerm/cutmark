# The `takes` MCP server: notes for agents

Read the root `AGENTS.md` first. This file adds what is true only in `mcp/`.

## The file

`takes_mcp.py` is the whole server: one Python file, standard library only, no packages. Keep it
that way: the app ships it as is and runs it with `/usr/bin/python3` (`AgentSetup.swift`).
`clean_voice.py` is separate because it needs packages: it runs through `uv`, with ffmpeg.

The file has sections, each with a `# ---------- name ----------` line. Find one with
`grep -n '^# ----------' mcp/takes_mcp.py`. The end of the file holds `TOOLS` (every tool's name,
description, schema and function) and `handle`, the JSON-RPC loop, with the server `instructions`.

## Add or change a tool

1. Write a `t_<name>(a)` function in the section it belongs to.
2. Add its entry to `TOOLS`: name, description, input schema, required fields, function.
3. Add a test in `mcp/tests/` (below).
4. Try it by hand on a scratch library: `TAKES_ROOT=/tmp/lib python3 mcp/takes_mcp.py`.
5. When the workflow changes, update the skills in `skills/`.

Write each description for the agent that calls the tool: what it does, when to use it, and what
to call next. A rule for one tool goes in its description. A rule for all of Takes goes in the
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
- **Rules before writes.** Tools that write a step (post, script, storyboard, edit) call
  `need_rules(step)` first. It refuses once per chat until that step's rules are read.
- **Private tools.** `SOCIAL` and `BLOG` switch off the private tools. The public copy sets both to
  `False`. A new private tool goes in `SOCIAL_TOOLS`; `test_private_tools.py` checks the list.

## Tests

- One file per area: `mcp/tests/test_<area>.py`, with `unittest`.
- `setUp` makes a temp folder, sets `os.environ["TAKES_ROOT"]` to it and clears global state such
  as `t.RULES_SEEN`. `tearDown` removes the folder and the variable. `test_lessons.py` is a good
  model.
- Call the tool functions directly (`t.t_set_post({...})`) and check the files on disk, not only
  the return value.
- No network: replace the HTTP function with a fake (`t.eleven_http = fake`) and put the real one
  back in `tearDown`. No real keys.
- Run only these tests: `python3 -m unittest discover -q -s mcp/tests`.
