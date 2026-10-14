# Cutmark

**Cutmark is a local-first video production workspace for people and AI agents, built by TriHerm Labs and created by Fernando Abishai.**

Record talking-head video, keep the source files on your Mac, and work with the AI agent you already use on scripts, storyboards, edits, review notes, thumbnails, and post drafts. Cutmark supports Claude Code, Codex, pi, and opencode in its in-app chat, and exposes the same local production workspace through MCP for compatible clients.

## Capabilities

- **Local-first production.** The default library lives at `~/Movies/Cutmark` and uses ordinary files and folders.
- **Provider choice.** Choose Claude Code, Codex, pi, or opencode during first-run setup.
- **Multi-provider chat.** Provider-specific command construction stays inside dedicated adapters while the product works against a shared agent interface.
- **MCP access.** The local Cutmark MCP server supports stdio and Streamable HTTP transports.
- **Video workflow.** Record takes, build storyboards, edit with ffmpeg/Whisper-based tools, review versions, and prepare publishing assets.
- **Private by default.** The release configures no usage analytics endpoint, and the MCP HTTP listener binds to loopback by default.

## Requirements

- Apple silicon Mac
- macOS 15 or newer
- Apple's Command Line Tools
- `ffmpeg` and `ffprobe`
- At least one configured chat runner: Claude Code, Codex, pi, or opencode

The first-run setup can guide you through missing dependencies. No AI provider is installed until you choose one and press **Install**.

## Install a release

Download `Cutmark.dmg` from the latest GitHub release, open it, and copy `Cutmark.app` to Applications.

The current open-source release pipeline uses ad-hoc signing and is not notarized. On first launch, macOS may require **System Settings → Privacy & Security → Open Anyway**.

## Build from source

```sh
git clone https://github.com/TriHerm/cutmark.git
cd cutmark
./test.sh
./build.sh
```

The macOS application is a Swift/SwiftUI package in `Sources/Cutmark`, with tests in `Tests/CutmarkTests`. The distributed application is `Cutmark.app` with bundle identifier `com.triherm.cutmark`.

To package the already-built app as a release artifact:

```sh
./scripts/package-dmg.sh
```

This creates `build.noindex/Cutmark.dmg`.

## Library

The default library is:

```text
~/Movies/Cutmark
```

Projects contain sessions. Sessions contain scripts, recordings, edits, storyboards, thumbnails, post files, and metadata. You can change the library folder from the app. Cutmark does not require a hosted project database for this workflow.

## AI runners

| Runner | Account/provider behavior |
| --- | --- |
| Claude Code | Uses the Claude Code account or API configuration already available to the CLI. |
| Codex | Uses the Codex/ChatGPT account or API configuration available to the CLI. |
| pi | Uses the provider and model configured in pi. |
| opencode | Uses the providers and model configured in opencode. |

## MCP

The packaged Cutmark MCP server is local-first and can be connected to compatible agent clients on the same Mac.

For ChatGPT, a private Mac can use OpenAI's Secure MCP Tunnel to launch the local stdio server. See [`docs/chatgpt-mcp.md`](docs/chatgpt-mcp.md).

The HTTP transport listens on loopback by default:

```sh
python3 /Applications/Cutmark.app/Contents/Resources/cutmark_mcp.py --http
# http://127.0.0.1:8765/mcp
```

Do not expose the loopback server directly to the public internet. A public deployment needs a stable HTTPS endpoint and appropriate authentication and per-user isolation.

## Configuration and secrets

Cutmark's auxiliary environment file is:

```text
~/.config/cutmark/.env
```

Provider CLIs continue to own their own login and model configuration.

## Privacy

- Video, scripts, chats, and project metadata stay in the library on your Mac unless a selected provider or explicit publishing/generation action sends data to an external service.
- Cutmark does not configure a usage analytics endpoint in the current release.
- API/provider calls follow the privacy and billing terms of the service you choose.
- The MCP HTTP listener binds to loopback by default.

## Development and releases

CI runs the Python MCP suite and Swift tests on macOS. Tags matching `v*` run the release workflow, build `Cutmark.app`, package `Cutmark.dmg`, verify the artifact, and create a GitHub Release.

The iPhone companion source is branded as Cutmark but is not part of the current macOS release path.

## License

Cutmark is released under the MIT License.

Copyright (c) 2026 TriHerm Labs and Fernando Abishai.

Required third-party license notices are retained in [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md).
