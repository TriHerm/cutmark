import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Cutmark

struct SetupTests {
    @Test func readsSignInFromAuthStatus() {
        #expect(AgentKind.claudeSignedIn("{\n  \"loggedIn\": true,\n  \"authMethod\": \"claude.ai\"\n}"))
        #expect(!AgentKind.claudeSignedIn("{\"loggedIn\": false}"))
        #expect(AgentKind.claudeSignedIn("Warning: something\n{\"loggedIn\": true}"))
        #expect(!AgentKind.claudeSignedIn("error: not found"))
        #expect(!AgentKind.claudeSignedIn(""))
    }

    @Test func readsSignInOfCodexAndPi() throws {
        #expect(AgentKind.codexSignedIn("Logged in using ChatGPT\n"))
        #expect(AgentKind.codexSignedIn("Logged in using an API key - sk-***"))
        #expect(!AgentKind.codexSignedIn("Not logged in"))
        #expect(!AgentKind.codexSignedIn(nil))
        let dir = FileManager.default.temporaryDirectory.appending(path: "pi-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(!AgentKind.piSignedIn(dir: dir))
        try Data("{}".utf8).write(to: dir.appending(path: "auth.json"))
        #expect(!AgentKind.piSignedIn(dir: dir))
        try Data(#"{"providers":{"ollama":{}}}"#.utf8).write(to: dir.appending(path: "models.json"))
        #expect(AgentKind.piSignedIn(dir: dir))
        try Data(#"{"providers":{}}"#.utf8).write(to: dir.appending(path: "models.json"))
        try Data(#"{"openai-codex":{"type":"oauth"}}"#.utf8).write(to: dir.appending(path: "auth.json"))
        #expect(AgentKind.piSignedIn(dir: dir))
    }

    /// A Codex-only Mac: new conversations start on Codex, unless an agent was picked.
    @Test @MainActor func startsOnTheSignedInAgent() throws {
        let d = try #require(UserDefaults(suiteName: "cutmark-setup-\(UUID().uuidString)"))
        Setup.useSignedIn([.codex], defaults: d)
        #expect(d.string(forKey: "chatAgent") == "codex")
        d.set("pi", forKey: "chatAgent")
        Setup.useSignedIn([.codex], defaults: d)
        #expect(d.string(forKey: "chatAgent") == "pi")
        let none = try #require(UserDefaults(suiteName: "cutmark-setup-\(UUID().uuidString)"))
        Setup.useSignedIn([], defaults: none)
        #expect(none.string(forKey: "chatAgent") == nil)
    }

    /// Setup is done only when the agent the chat uses is signed in (review of 2026-10-12).
    @Test @MainActor func setupFollowsTheAgentTheChatUses() {
        #expect(Setup.readiness(here: [.claude, .pi], ready: [.claude], preferred: .pi) == (.pi, false))
        #expect(Setup.readiness(here: [.claude, .pi], ready: [.claude], preferred: .claude) == (.claude, true))
        #expect(Setup.readiness(here: [.codex], ready: [.codex], preferred: .claude) == (.codex, true))
        #expect(Setup.readiness(here: [], ready: [], preferred: .claude) == (.claude, false))
    }

    @Test func eachFirstRunAgentHasAnExplicitInstaller() {
        #expect(AgentKind.claude.installation.command == Agents.claudeInstaller)
        #expect(AgentKind.codex.installation.command == "npm install -g @openai/codex@latest")
        #expect(AgentKind.pi.installation.command == "curl -fsSL https://pi.dev/install.sh | sh")
        #expect(AgentKind.opencode.installation.command == "curl -fsSL https://opencode.ai/install | bash")
        #expect(AgentKind.allCases.allSatisfy { !$0.installation.detail.isEmpty && !$0.installation.hint.isEmpty })
    }

    @Test @MainActor func firstRunRequiresAnExplicitProviderChoice() {
        let s = Setup()
        s.agent = .missing
        #expect(s.installChoice == nil)
        #expect(!s.canInstallAgent, "welcome must disable Install before choosing a provider")
        s.installAgent()
        #expect(s.installChoice == nil, "a disabled first-run action must not silently pick Claude")
        s.chooseAgent(.codex)
        #expect(s.installChoice == .codex && s.target == .codex)
        #expect(s.canInstallAgent, "the welcome's Install action can now install the chosen agent")
        s.agent = .failed("old provider failed")
        s.chooseAgent(.opencode)
        #expect(s.agent == .missing && s.installChoice == .opencode && s.target == .opencode)
        s.agent = .ok
        #expect(!s.canInstallAgent)
        s.chooseAgent(.pi)
        #expect(s.installChoice == .opencode && s.target == .opencode, "an installed-agent setup ignores first-run choices")
    }

    @Test @MainActor func nothingShowsBeforeTheFirstCheck() {
        let s = Setup()
        #expect(!s.needed)
        s.agent = .ok; s.signedIn = .missing; s.ffmpeg = .ok; s.devTools = .ok
        #expect(s.needed && s.left == 1)
        s.signedIn = .ok
        #expect(!s.needed && s.left == 0)
    }

    @Test func pathGetsTheLocalBinOnce() {
        #expect(ClaudeChat.withLocalBin("/usr/bin:/bin", bin: "/h/.local/bin") == "/usr/bin:/bin:/h/.local/bin")
        #expect(ClaudeChat.withLocalBin("/h/.local/bin:/usr/bin", bin: "/h/.local/bin") == "/h/.local/bin:/usr/bin")
    }
}

/// Downloads about 60 MB, so it runs only with CUTMARK_NET=1.
@Test(.enabled(if: ProcessInfo.processInfo.environment["CUTMARK_NET"] == "1"))
func ffmpegDownloadsAndRuns() async throws {
    let dir = FileManager.default.temporaryDirectory.appending(path: "cutmark-ffmpeg-\(UUID().uuidString)").path
    defer { try? FileManager.default.removeItem(atPath: dir) }
    try await Setup.downloadFFmpeg(to: dir)
    for name in ["ffmpeg", "ffprobe"] {
        let (ok, out) = Setup.run(dir + "/" + name, ["-version"])
        #expect(ok && out.contains("\(name) version"))
    }
}

/// CUTMARK_SNAPSHOT=1 draws the sidebar row and the panel, light and dark, to $TMPDIR.
@Test(.enabled(if: ProcessInfo.processInfo.environment["CUTMARK_SNAPSHOT"] != nil)) @MainActor
func setupSnapshot() throws {
    let s = Setup.shared
    s.agent = .ok; s.signedIn = .missing; s.ffmpeg = .working; s.devTools = .missing
    let failed = Setup()
    failed.agent = .missing; failed.signedIn = .missing; failed.ffmpeg = .failed("The ffmpeg download did not match its checksum."); failed.devTools = .ok
    for dark in [false, true] {
        NSAppearance.current = NSAppearance(named: dark ? .darkAqua : .aqua)
        let view = HStack(alignment: .top, spacing: 24) {
            SetupButton().frame(width: 240)
            SetupPanel(setup: s)
            SetupPanel(setup: failed)
        }
        .padding(24).background(Theme.paper)
        .environment(\.colorScheme, dark ? .dark : .light)
        let host = NSHostingView(rootView: view)
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        host.layoutSubtreeIfNeeded()
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let url = FileManager.default.temporaryDirectory.appending(path: "setup-\(dark ? "dark" : "light").png")
        try rep.representation(using: .png, properties: [:])!.write(to: url)
        print("SNAPSHOT \(url.path)")
    }
}
