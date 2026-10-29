# Cutmark

**Cutmark is a local-first video production workspace for people and AI agents, built by TriHerm Labs and created by Fernando Abishai.**

Record talking-head video, keep the source files on your Mac, and work with the AI agent you already use on scripts, storyboards, edits, review notes, thumbnails, and post drafts. Cutmark supports Claude Code, Codex, pi, and opencode in its in-app chat, and exposes the same local production workspace through MCP for compatible clients.

## Capabilities

- **Local-first production.** The default library lives at `~/Movies/Cutmark` and uses ordinary files and folders.
- **Provider choice.** Choose Claude Code, Codex, pi, or opencode during first-run setup.
- **Multi-provider chat.** Provider-specific command construction stays inside dedicated adapters while the product works against a shared agent interface.
- **MCP access.** The local Cutmark MCP server supports stdio and Streamable HTTP transports.
- **Video workflow.** Plan → Record → Edit → Export. Prepare a script or talking points, record takes, resume a saved cut, review the finished video, and export a copy. Media, sound, and post drafts remain available inside the editing and export stages.
- **Editing workspace.** A cut preview, filmstrip, waveform, and transcript sections share the same timeline. Click a phrase to listen, split around a mistake, or trim a selected section at the playhead. Effects appear in rendered versions.
- **Starter styles.** Studio, Paper, and Focus include visual samples, colour/type tokens, and guides for assisted edits. They are not live preview filters.
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

Cutmark 0.3.0 uses an explicitly authorized ad-hoc signing channel, like 0.2.0, and is **not notarized**. On first launch, macOS may require **System Settings → Privacy & Security → Open Anyway**. The repository retains a separate, protected Developer ID + Apple notarization path for production-signed releases once Apple credentials are configured.

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
- Camera + Screen takes may keep a local `.capture-events` sidecar with normalized pointer movement, mouse clicks, scroll deltas, and manual markers for later editing features. Cutmark does not record keystrokes in this event format.
- Cutmark does not configure a usage analytics endpoint in the current release.
- API/provider calls follow the privacy and billing terms of the service you choose.
- The MCP HTTP listener binds to loopback by default.

## Development and releases

CI runs the Python MCP suite and Swift tests on macOS. Tags matching `v*` reuse the successful CI result for the same commit, then build `Cutmark.app`, package `Cutmark.dmg`, verify the artifact, and create a GitHub Release. Create the tag after CI on `main` is green; an early tag fails quickly and can be re-run after CI finishes.

The protected production workflow uses the `production-release` GitHub environment with the Apple Developer ID and notarization credentials described in [`docs/releasing.md`](docs/releasing.md). Production signing is fail-closed; it does not fall back to an ad-hoc artifact when credentials or notarization are unavailable. Cutmark 0.2.0 was intentionally published through the legacy ad-hoc channel instead of weakening that production gate.

The iPhone companion source is branded as Cutmark but is not part of the current macOS release path.

## License

Cutmark is released under the MIT License.

Copyright (c) 2026 TriHerm Labs and Fernando Abishai.

Required third-party license notices are retained in [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md).
