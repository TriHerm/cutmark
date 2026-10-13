# Cutmark

**Cutmark is a local-first video production workspace for people and AI agents, built by TriHerm Labs.**

Record a talking-head video, keep the source files on your Mac, and let the agent you already use help with scripts, storyboards, edits, review notes, thumbnails, and post drafts. Cutmark can run its in-app chat through Claude Code, Codex, pi, or opencode, and its MCP server can also be used from compatible external clients.

Cutmark is derived from the MIT-licensed [Takes](https://github.com/marvtub/takes-public) project by Marvin Aziz. The original copyright and license are preserved in [`LICENSE`](LICENSE); see [`NOTICE.md`](NOTICE.md) for provenance.

## What is different

- **Provider choice at first run.** Cutmark does not silently install or require Claude Code. Choose Claude Code, Codex, pi, or opencode.
- **Multi-provider chat.** Claude and Codex work directly; pi and opencode can use their own provider/model configuration.
- **Direct MCP access.** The same local library can be exposed to compatible MCP clients without routing through Codex. ChatGPT can use the private Secure MCP Tunnel path when custom MCP access is available for the account or workspace.
- **Independent product state.** Cutmark uses its own bundle identifier, library folder, configuration, update channel, and GitHub releases. It can coexist with Takes on the same Mac.
- **Local-first storage.** The default library is `~/Movies/Cutmark`. Cutmark currently ships with usage reporting disabled and no analytics endpoint configured.

## Requirements

- Apple silicon Mac
- macOS 15 or newer
- Apple's Command Line Tools
- `ffmpeg` and `ffprobe`
- At least one configured chat runner: Claude Code, Codex, pi, or opencode

The first-run setup can guide you through the missing pieces. No AI provider is installed until you choose one and press **Install**.

## Install a release

Download `Cutmark.dmg` from the latest GitHub release, open it, and copy `Cutmark.app` to Applications.

The current open-source release pipeline uses ad-hoc signing and is not notarized. On first launch, macOS may require **System Settings → Privacy & Security → Open Anyway**. Notarization can be added later without changing the app's data format.

## Build from source

```sh
git clone https://github.com/TriHerm/cutmark.git
cd cutmark
./test.sh
./build.sh
```

The app is written in Swift/SwiftUI. The source target is still named `Takes` internally for compatibility with the upstream codebase, while the distributed application is `Cutmark.app` with bundle identifier `com.triherm.cutmark`.

To package the already-built app as the release artifact:

```sh
./scripts/package-dmg.sh
```

This creates `build.noindex/Cutmark.dmg`.

## Library

The default library is a set of ordinary folders under:

```text
~/Movies/Cutmark
```

Projects contain sessions. Sessions contain scripts, recordings, edits, storyboards, thumbnails, post files, and metadata. You can change the library folder from the app. Cutmark does not need a hosted project database for this workflow.

## AI runners

The in-app chat can run through:

| Runner | Account/provider behavior |
| --- | --- |
| Claude Code | Uses the Claude Code account or API configuration already available to the CLI. |
| Codex | Uses the Codex/ChatGPT account or API configuration available to the CLI. |
| pi | Uses the provider and model configured in pi. |
| opencode | Uses the providers and model configured in opencode. |

Cutmark keeps provider-specific command construction inside its agent adapters. The rest of the app asks for an agent capability rather than directly invoking a specific provider.

## MCP

Cutmark includes the inherited Python MCP implementation and extends it with both stdio and Streamable HTTP transports. The packaged server is local-first and can be connected to agent clients on the same Mac.

For ChatGPT, Codex is **not** a required bridge. A private Mac can use OpenAI's Secure MCP Tunnel to launch the local stdio server. See [`docs/chatgpt-mcp.md`](docs/chatgpt-mcp.md).

The HTTP transport listens on loopback by default:

```sh
python3 /Applications/Cutmark.app/Contents/Resources/cutmark_mcp.py --http
# http://127.0.0.1:8765/mcp
```

Do not expose the loopback server directly to the public internet. A public deployment needs a stable HTTPS endpoint and proper authentication/authorization.

## Configuration and secrets

Cutmark's auxiliary environment file is:

```text
~/.config/cutmark/.env
```

For migration only, Cutmark can still read legacy values from `~/.claude/.env` when a value is not present in the Cutmark file. New writes go to Cutmark's own config. Provider CLIs continue to own their own login and model configuration.

## Privacy

- Video, scripts, chats, and project metadata stay in the library on your Mac unless a selected provider or explicit publishing/generation action sends data to an external service.
- Cutmark does not configure a usage analytics endpoint in the current release.
- API/provider calls still follow the privacy and billing terms of the service you choose.
- The MCP HTTP listener binds to loopback by default.

## Development and releases

CI runs the Python MCP suite and Swift tests on macOS. Tags matching `v*` run the release workflow, build `Cutmark.app`, package `Cutmark.dmg`, verify the artifact, and create a GitHub Release.

The first public version is intentionally conservative: preserve the proven local file format and editing infrastructure, while separating product identity, provider choice, configuration, MCP identity, and release infrastructure from upstream Takes.

**v0.1.0 is a macOS release.** The inherited iOS companion source remains in the repository as upstream-derived work, but Cutmark does not start or expose the phone bridge until that companion has its own Cutmark identity and release path.

## License and provenance

Cutmark is distributed under the MIT license inherited from Takes. The original Takes copyright notice remains in [`LICENSE`](LICENSE).

TriHerm Labs' changes include the Cutmark product identity, provider-neutral setup, additional agent adapters, direct MCP transport, configuration isolation, release infrastructure, and subsequent Cutmark-specific work. See [`NOTICE.md`](NOTICE.md).
