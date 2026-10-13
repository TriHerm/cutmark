import AppKit
import Foundation
import Observation
import SwiftUI

/// What a new Mac needs before Takes works (2026-10-05): an agent, signed in, and ffmpeg. Until
/// 2026-10-12 the agent had to be Claude Code; now Claude Code, Codex, pi or opencode will do. A Mac
/// with none asks which one to install instead of silently choosing Claude (Agents/SignIn.swift).
/// Since 2026-10-10 also Apple's developer tools: the takes MCP server runs on /usr/bin/python3,
/// which without them is only a stub, so no agent could use Takes. Their fix opens Apple's dialog.
/// A downloaded Takes checks this at launch and each time it comes to the front. While a step is
/// missing, the sidebar shows Finish setup; its panel fixes each step with one click. The app
/// opens the chosen agent's explicit installer in Terminal and downloads ffmpeg as a static build in
/// ~/.local/bin (no Homebrew needed). Sign-in opens Terminal, because each agent's login needs a terminal.
@MainActor @Observable
final class Setup {
    static let shared = Setup()
    init() {}

    enum Status: Equatable { case unknown, ok, missing, working, failed(String) }

    /// An agent is on this Mac.
    var agent: Status = .unknown
    /// One of the agents here is signed in.
    var signedIn: Status = .unknown
    /// The agent the steps name when one is installed.
    var target: AgentKind = .claude
    /// First-run choice only. Nil means the user has not picked a provider yet.
    var installChoice: AgentKind?
    var ffmpeg: Status = .unknown
    var devTools: Status = .unknown
    private var checking = false

    /// True once a check found something to do. Nothing shows before the first check ends.
    var needed: Bool { [agent, signedIn, ffmpeg, devTools].contains { $0 != .ok && $0 != .unknown } }
    var left: Int { [agent, signedIn, ffmpeg, devTools].filter { $0 != .ok }.count }

    nonisolated static var home: String { FileManager.default.homeDirectoryForCurrentUser.path }
    nonisolated static var localBin: String { home + "/.local/bin" }

    /// ffmpeg or ffprobe: Homebrew, the usual places, or the copy Takes downloads.
    nonisolated static func tool(_ name: String) -> String? {
        ["/opt/homebrew/bin/", "/usr/local/bin/", localBin + "/", "/usr/bin/"].map { $0 + name }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    func start() {
        Task { await check() }
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                let s = Setup.shared
                if s.needed { Task { await s.check() } }
            }
        }
    }

    func check() async {
        guard !checking else { return }
        checking = true
        defer { checking = false }
        let (here, ready, hasFFmpeg, hasTools) = await Task.detached(priority: .utility) {
            let here = Agents.installed
            return (here, here.filter { k in Agents.path(k).map { k.signedIn($0) } ?? false },
                    Self.tool("ffmpeg") != nil && Self.tool("ffprobe") != nil, Self.hasDevTools())
        }.value
        Self.useSignedIn(ready)
        let (pick, ok) = Self.readiness(here: here, ready: ready)
        if here.isEmpty {
            if let installChoice { target = installChoice }
        } else {
            target = pick
            installChoice = nil
        }
        if agent != .working { agent = here.isEmpty ? .missing : .ok }
        if signedIn != .working { signedIn = ok ? .ok : .missing }
        if ffmpeg != .working { ffmpeg = hasFFmpeg ? .ok : .missing }
        if devTools != .working {
            // Tools that came since the last check: the agents get the takes server now.
            if hasTools, devTools == .missing { AgentSetup.run() }
            devTools = hasTools ? .ok : .missing
        }
    }

    /// `xcode-select -p` finds the Command Line Tools (or Xcode) and never opens a dialog.
    nonisolated static func hasDevTools() -> Bool { run("/usr/bin/xcode-select", ["-p"]).0 }

    /// The agent the chat will use (the picked one when it is here, else the first one here) and
    /// whether it is signed in. Another agent being signed in does not count: the chat would fail.
    static func readiness(here: [AgentKind], ready: [AgentKind],
                          preferred: AgentKind = ChatAgent.current.kind) -> (AgentKind, Bool) {
        let pick = Agents.pick(preferred: preferred, here: here) ?? .claude
        return (pick, ready.contains(pick))
    }

    /// A Mac where nobody picked an agent yet, and Claude Code (the default) is not signed in but
    /// another agent is: new conversations start on that one. A pick made in Settings › Agents stays.
    static func useSignedIn(_ ready: [AgentKind], defaults: UserDefaults = .standard) {
        guard defaults.string(forKey: "chatAgent") == nil, let first = ready.first, !ready.contains(.claude) else { return }
        defaults.set(first.rawValue, forKey: "chatAgent")
    }

    // MARK: Fixes

    /// First-run provider choice. Existing-agent setup never calls this path.
    func chooseAgent(_ kind: AgentKind) {
        guard agent != .ok else { return }
        installChoice = kind
        target = kind
        if case .failed = agent { agent = .missing }
    }

    /// Opens the explicitly chosen provider's supported installer in Terminal. The app does not run
    /// an installer until the user chooses a provider and presses Install.
    func installAgent() {
        guard agent != .ok, let kind = installChoice else { return }
        let install = kind.installation
        let text = """
        #!/bin/bash
        clear
        echo "\(install.hint)"
        \(install.command)
        echo
        echo "Done. You can close this window and go back to Cutmark."
        """
        if !Self.openTerminal(text, name: "cutmark-install-agent.command") {
            agent = .failed("Could not open Terminal. Install \(kind.name) in Terminal, then come back to Cutmark.")
        }
    }

    /// Opens Terminal on the agent's login. Takes checks again when it comes back to the front.
    func signIn() {
        guard let exe = Agents.path(target) else { return }
        let login = target.login
        let text = """
        #!/bin/bash
        clear
        echo "\(login.hint)"
        '\(exe)'\(login.args.map { " " + $0 }.joined())
        echo
        echo "Done. You can close this window and go back to Cutmark."
        """
        if !Self.openTerminal(text, name: "cutmark-sign-in.command") {
            signedIn = .failed("Could not open Terminal. Sign in to \(target.name) in Terminal.")
        }
    }

    @discardableResult
    private static func openTerminal(_ text: String, name: String) -> Bool {
        let script = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: name)
        do {
            try text.write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
            NSWorkspace.shared.openSoon(script)
            return true
        } catch {
            return false
        }
    }

    /// Opens Apple's install dialog, then waits for the tools (it takes some minutes) and sets up
    /// the agents. Closing the dialog leaves the step open, to try again.
    func installDevTools() {
        devTools = .working
        Task {
            _ = await Task.detached { Self.run("/usr/bin/xcode-select", ["--install"]) }.value
            for _ in 0..<360 {  // 30 minutes
                try? await Task.sleep(for: .seconds(5))
                if await Task.detached(operation: { Self.hasDevTools() }).value {
                    devTools = .ok
                    AgentSetup.run()
                    return
                }
            }
            devTools = .missing
        }
    }

    func installFFmpeg() {
        ffmpeg = .working
        Task {
            do {
                try await Self.downloadFFmpeg()
                ffmpeg = .ok
            } catch {
                ffmpeg = .failed(error.localizedDescription)
            }
            await check()
        }
    }

    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ s: String) { errorDescription = s }
    }

    /// The static arm64 builds that ffmpeg.org links to, checked against their SHA-256.
    nonisolated static func downloadFFmpeg(to bin: String = localBin) async throws {
        let fm = FileManager.default
        try fm.createDirectory(atPath: bin, withIntermediateDirectories: true)
        for name in ["ffmpeg", "ffprobe"] where !fm.isExecutableFile(atPath: bin + "/" + name) {
            let latest = URL(string: "https://ffmpeg.martin-riedl.de/redirect/latest/macos/arm64/release/\(name).zip")!
            let (zip, response) = try await URLSession.shared.download(from: latest)
            guard let real = response.url, (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw Failure("The \(name) download failed. Try again later.")
            }
            let (sum, _) = try await URLSession.shared.data(from: real.appendingPathExtension("sha256"))
            let want = String(decoding: sum, as: UTF8.self).split(separator: " ").first.map(String.init) ?? ""
            let (_, got) = run("/usr/bin/shasum", ["-a", "256", zip.path])
            guard !want.isEmpty, got.hasPrefix(want) else { throw Failure("The \(name) download did not match its checksum.") }
            let dir = fm.temporaryDirectory.appending(path: "takes-\(name)-\(UUID().uuidString)")
            defer { try? fm.removeItem(at: dir); try? fm.removeItem(at: zip) }
            guard run("/usr/bin/ditto", ["-x", "-k", zip.path, dir.path]).0 else { throw Failure("Could not unpack \(name).") }
            let dest = bin + "/" + name
            try? fm.removeItem(atPath: dest)
            try fm.moveItem(at: dir.appending(path: name), to: URL(fileURLWithPath: dest))
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest)
        }
    }

    nonisolated static func run(_ exe: String, _ args: [String]) -> (Bool, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        for k in env.keys where k.hasPrefix("CLAUDECODE") || k.hasPrefix("CLAUDE_CODE_") { env[k] = nil }
        env["PATH"] = ClaudeChat.shellPath
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        p.standardInput = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return (false, "") }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus == 0, String(decoding: data, as: UTF8.self))
    }
}

/// "Finish setup" at the top of the sidebar while a step is missing. It opens the checklist.
struct SetupButton: View {
    private var setup = Setup.shared
    @Environment(\.openSettings) private var openSettings
    @State private var open = false
    @State private var hover = false

    var body: some View {
        if setup.needed {
            Button { open.toggle() } label: {
                HStack(spacing: 9) {
                    Image(systemName: "checklist").frame(width: 16)
                    Text("Finish setup").font(Theme.sans(13, .semibold))
                    Spacer(minLength: 4)
                    Text(setup.left == 1 ? "1 step" : "\(setup.left) steps").font(Theme.sans(11, .medium)).opacity(0.8)
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).opacity(0.6)
                }
                .padding(.horizontal, 10).padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(hover || open ? Theme.accent.opacity(0.12) : .clear)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hover = $0 }
            .foregroundStyle(Theme.accentInk)
            .background(Theme.accentSoft)
            .clipShape(RoundedRectangle(cornerRadius: 9))
            .padding(.bottom, 4)
            .takesPopover(isPresented: $open, edge: .trailing) { [openSettings] in SetupPanel(setup: setup, settings: openSettings) }
            .transition(.opacity.combined(with: .scale(scale: 0.95)))
        }
    }
}

/// The three steps, each with its state and the button that does it, then the optional Gemini key.
struct SetupPanel: View {
    var setup: Setup
    /// The caller's Settings action: a Takes panel is its own window, outside the app's scenes.
    var settings: OpenSettingsAction? = nil
    @Environment(\.openSettings) private var openSettings
    @State private var hasGemini = GeminiKey.found

    /// Not a step: Takes works without it. It says what the key adds and opens Settings › Gemini.
    private var gemini: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: hasGemini ? "checkmark.circle.fill" : "key")
                .font(.system(size: 13)).foregroundStyle(hasGemini ? Theme.accent : Theme.faint)
                .frame(width: 15).padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text("Optional: a Gemini key").font(Theme.sans(13, .medium)).foregroundStyle(Theme.ink)
                Text("For storyboard sketches, B-roll names and best cuts. Everything else works without it.")
                    .font(Theme.sans(12)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button(hasGemini ? "Details" : "Add Key") {
                UserDefaults.standard.set(SettingsView.SettingsPage.gemini.rawValue, forKey: "settingsPage")
                (settings ?? openSettings)()
            }
        }
    }

    private var agentChoice: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "person.crop.circle.badge.questionmark")
                .font(.system(size: 15)).foregroundStyle(Theme.faint).frame(width: 15).padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text("Choose an AI agent").font(Theme.sans(13, .medium)).foregroundStyle(Theme.ink)
                Text("Pick the provider you want Cutmark to use. Nothing is installed until you press Install.")
                    .font(Theme.sans(12)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            TakesMenuButton(help: "Choose the agent Cutmark should install") {
                HStack(spacing: 4) {
                    Text(setup.installChoice?.name ?? "Choose")
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
                }
                .font(Theme.sans(12.5, .medium)).foregroundStyle(Theme.ink)
            } content: {
                for kind in AgentKind.allCases {
                    MenuButton(kind.name, checked: setup.installChoice == kind) { setup.chooseAgent(kind) }
                }
            }
            .fixedSize()
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Finish setup").font(Theme.display(17))
                Text("Cutmark records on its own. These steps let Cutmark storyboard, edit and write posts for you.")
                    .font(Theme.sans(12)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 18).padding(.top, 16).padding(.bottom, 12)
            Divider().overlay(Theme.border)
            VStack(alignment: .leading, spacing: 14) {
                if setup.agent == .ok {
                    step("\(setup.target.name) is installed", "", setup.agent,
                         action: "Install", busy: "Installing…", setup.installAgent)
                } else {
                    agentChoice
                    if let choice = setup.installChoice {
                        step("Install \(choice.name)", choice.installation.detail, setup.agent,
                             action: "Install", busy: "Installing…", setup.installAgent)
                    }
                }
                let signInAgent = setup.agent == .ok ? setup.target : setup.installChoice
                step(signInAgent.map { "Sign in to \($0.name)" } ?? "Sign in to your agent",
                     signInAgent == .pi
                     ? "Opens pi in Terminal: type /login and pick a provider. Come back here when you are done."
                     : signInAgent == .opencode
                     ? "Opens opencode provider sign-in in Terminal. Pick a provider and come back here when you are done."
                     : "Opens Terminal and then your browser. Come back here when you are done.",
                     setup.agent == .ok ? setup.signedIn : .missing, action: "Sign in", busy: "Waiting…",
                     enabled: setup.agent == .ok, setup.signIn)
                step("Get ffmpeg", "Cuts and exports video. About 60 MB, into ~/.local/bin.",
                     setup.ffmpeg, action: "Download", busy: "Downloading…", setup.installFFmpeg)
                step("Get Apple's developer tools", "Cutmark's link to your agents runs on them. Apple's own installer opens; it takes a few minutes.",
                     setup.devTools, action: "Install", busy: "Installing…", setup.installDevTools)
            }
            .padding(18)
            Divider().overlay(Theme.border)
            gemini.padding(.horizontal, 18).padding(.vertical, 14)
        }
        .frame(width: 400)
        .background(Theme.paper)
        .task { await setup.check(); hasGemini = GeminiKey.found }
    }

    private func step(_ title: String, _ detail: String, _ status: Setup.Status, action: String, busy: String,
                      enabled: Bool = true, _ run: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: status == .ok ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 15)).foregroundStyle(status == .ok ? Theme.accent : Theme.faint)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(Theme.sans(13, .medium)).foregroundStyle(Theme.ink)
                if case .failed(let why) = status {
                    Text(why).font(Theme.sans(12)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                } else if status != .ok {
                    Text(detail).font(Theme.sans(12)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            if status == .working {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text(busy).font(Theme.sans(12)).foregroundStyle(Theme.muted)
                }
            } else if status != .ok {
                Button(action: run) {
                    Text(action).font(Theme.sans(12.5, .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 12).padding(.vertical, 5)
                        .background(Theme.accent.opacity(enabled ? 1 : 0.4), in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(!enabled)
            }
        }
    }
}
