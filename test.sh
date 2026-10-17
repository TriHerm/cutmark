#!/bin/bash
# Run every test: the MCP server (Python) and the app (Swift Testing). Extra arguments go to swift test.
# With only the Command Line Tools (no Xcode), swift test cannot find the Testing framework on its own,
# so point it there.
set -euo pipefail
cd "$(dirname "$0")"
# Only a --filter or --skip picks the tests; other flags (build.sh passes --quiet) keep the full run.
FULL=1
[[ " $* " == *" --filter "* || " $* " == *" --skip "* ]] && FULL=""
# A full run waits its turn: one at a time on this Mac (scripts/test-queue.sh).
source scripts/test-queue.sh
if [[ -n "$FULL" ]]; then queue_wait; fi
# Its own temp folder, removed when the run ends (2026-10-11). The MCP tests make folders with
# mkdtemp and leave them: 88,000 piled up in a week, some with copies of whole libraries.
RUN_TMP="$(mktemp -d "${TMPDIR:-/tmp}/cutmark-test.XXXXXX")"
cutmark_on_exit "$RUN_TMP"
export TMPDIR="$RUN_TMP/"
# The tree this run tests, to remember when it passes. Only the private repo: the public copy has no git.
TREE=""
if [[ -n "$FULL" && -f scripts/public/check-public-build.sh ]]; then TREE="$(tree_now)"; fi
# Without the Claude chat id: a suite started inside a Claude session must not write seen-rules files
# (2026-10-10). Tests that need an id set it themselves.
# In parallel processes: one by one they took 280 s (mcp/tests/run_parallel.py).
MCP_ARGS=()
[[ -n "${CUTMARK_MCP_JOBS:-}" ]] && MCP_ARGS+=(-j "$CUTMARK_MCP_JOBS")
[[ "${CUTMARK_MCP_FAIL_FAST:-}" == 1 ]] && MCP_ARGS+=(--fail-fast)
# Bash 3.2 with `set -u` treats an empty array expansion as unbound on macOS.
env -u CLAUDE_CODE_SESSION_ID python3 mcp/tests/run_parallel.py "${MCP_ARGS[@]+"${MCP_ARGS[@]}"}" || { echo "MCP tests failed"; exit 1; }
DEV=/Library/Developer/CommandLineTools/Library/Developer
run() {
  local selected
  selected="$(xcode-select -p 2>/dev/null || true)"
  if [[ -d "$DEV/Frameworks/Testing.framework" && "$selected" == /Library/Developer/CommandLineTools* ]]; then
    swift test -Xswiftc -F -Xswiftc "$DEV/Frameworks" \
      -Xlinker -F -Xlinker "$DEV/Frameworks" \
      -Xlinker -rpath -Xlinker "$DEV/Frameworks" -Xlinker -rpath -Xlinker "$DEV/usr/lib" "$@"
  else
    swift test "$@"
  fi
}
# Tests that time real playback, web views or streamed output. Beside 250 parallel tests the Mac is
# too busy for their timing, and they failed the public release (2026-10-06) though each passes
# alone. A full run leaves them out, then runs them by themselves, one at a time.
TIMED='aSteerShowsNoErrorAndGoesOn|theNextArticleUsesALoadedPage|theHiddenDockedChatSkipsStreamedWords|effectPlaysAtItsSecond|resetWhileRunningKeepsTheNewAsk|watcherSeesAWrite|aSlowAgentStopsAtItsTime|newDraftReplacesTheTextWhileTyping|aCodexConversationStartsAThreadAndResumesIt|aPiConversationKeepsItsIDAndTellsTheCutmarkServer|installsThePackOnceAndOpensItOnItsEdit'
if [[ -z "$FULL" ]]; then
  run "$@"
else
  if [[ "${CUTMARK_CI_SERIAL_SWIFT:-}" == 1 ]]; then
    # Hosted CI runs share process-global test hooks (agent overrides, AppKit/WebKit state) across
    # otherwise unrelated suites. Run Swift Testing serially there so the release gate measures the
    # product instead of scheduler order. MCP tests above stay parallel and remain the slowest stage.
    run --no-parallel "$@"
  else
    run --skip "$TIMED" "$@"
    echo "Timed tests, one at a time..."
    run --filter "$TIMED" --no-parallel "$@"
  fi
  # A full run also builds and tests the public copy (2026-10-08): code that uses a private
  # plugin passes here and fails there. Only the private repo has the script.
  if [[ -f scripts/public/check-public-build.sh && "${CUTMARK_SKIP_PUBLIC:-}" != 1 ]]; then
    echo "The public copy..."
    scripts/public/check-public-build.sh
    # Every check passed on this tree: build.sh install does not run them again.
    if [[ -n "$TREE" ]]; then passed_mark "$TREE"; fi
  fi
fi
