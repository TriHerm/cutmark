import Foundation

// One way for every feature to ask an agent (2026-10-12). Outside the chat, Takes ran only Claude Code:
// a Mac with only Codex or pi lost session names, comment drafts and more. Now a feature says what it
// wants (AgentRequest), and the adapter for the agent turns that into its CLI's arguments and reads its
// output (AgentReply). Only the files in Agents/ name a CLI: AgentGuardTests fails on one anywhere else.
//
// Which agent: the one picked in Settings › Agents when it is on this Mac, else the first one here
// (Claude Code, Codex, pi, opencode). Tests point `overrides` at fake CLIs.

enum AgentKind: String, CaseIterable, Codable, Sendable {
    case claude, codex, pi, opencode

    var name: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        case .pi: return "pi"
        case .opencode: return "opencode"
        }
    }

    var adapter: AgentAdapter {
        switch self {
        case .claude: return ClaudeAdapter()
        case .codex: return CodexAdapter()
        case .pi: return PiAdapter()
        case .opencode: return OpenCodeAdapter()
        }
    }
}

/// What a feature asks. Never CLI flags: the adapter picks those.
struct AgentRequest: Sendable {
    enum Speed: Sendable { case fast, smart }
    enum Tools: Sendable, Equatable {
        /// Answer from the text alone.
        case none
        /// May read files in `folder`, never change them.
        case read
    }
    /// The instructions. They go on stdin with `input`, so their length has no limit.
    var prompt: String
    /// The text to work on (a script, a post), after the instructions.
    var input: String = ""
    /// `.fast`: the agent's small model (names, short answers). `.smart`: the model picked for the chat.
    var speed: Speed = .smart
    var tools: Tools = .none
    var folder: URL = FileManager.default.temporaryDirectory
    var seconds: Double = 60

    var stdin: String { input.isEmpty ? prompt : prompt + "\n\n" + input }
}

struct AgentReply: Equatable, Sendable {
    var text: String?
    var error: String?

    static func failed(_ e: String) -> AgentReply { AgentReply(text: nil, error: e) }
}

/// One agent CLI: its arguments for a request, and its answer from what it printed.
protocol AgentAdapter: Sendable {
    var kind: AgentKind { get }
    func arguments(_ r: AgentRequest) -> [String]
    /// A request-local environment. The default is Takes' normal agent environment; providers may
    /// add process-only configuration without changing the user's global CLI config.
    func environment(_ r: AgentRequest, base: [String: String]) -> [String: String]
    /// `out`: stdout. `err`: stderr, for when stdout has no answer.
    func reply(out: String, err: String, status: Int32) -> AgentReply
}

extension AgentAdapter {
    func environment(_ r: AgentRequest, base: [String: String]) -> [String: String] { base }

    /// The last line a failed run printed, for the error.
    func lastLine(_ s: String) -> String? {
        s.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.last { !$0.isEmpty }
    }

    func noAnswer(_ out: String, _ err: String, _ status: Int32) -> AgentReply {
        .failed(lastLine(err) ?? lastLine(out) ?? "\(kind.name) stopped with no answer (exit \(status)).")
    }
}

enum Agents {
    /// Tests: a fake CLI per agent. Under test there is no fallback to a real one.
    nonisolated(unsafe) static var overrides: [AgentKind: String] = [:]

    /// The agent's CLI on this Mac, or nil.
    nonisolated static func path(_ k: AgentKind) -> String? {
        if let o = overrides[k] { return o }
        switch k {  // the chat's own test hooks (Chat.swift)
        case .claude: if let o = ClaudeChat.claudeOverride { return o }
        case .codex: if let o = ClaudeChat.codexOverride { return o }
        case .pi, .opencode: break
        }
        return AppModel.testing ? nil : find(k)
    }

    /// In ~/.local/bin, Claude's own folders, Homebrew, or on the login shell's PATH.
    nonisolated static func find(_ k: AgentKind) -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let dirs = ["\(home)/.local/bin"] + (k == .claude ? ["\(home)/.claude/local"] : [])
            + ["/opt/homebrew/bin", "/usr/local/bin"] + ClaudeChat.shellPath.split(separator: ":").map(String.init)
        return dirs.map { "\($0)/\(k.rawValue)" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    nonisolated static var installed: [AgentKind] { AgentKind.allCases.filter { path($0) != nil } }

    /// The agent Takes uses: the one picked in Settings › Agents when it is here, else the first one here.
    nonisolated static func pick(preferred: AgentKind? = AgentKind(rawValue: ChatAgent.current.rawValue),
                                 here: [AgentKind] = installed) -> AgentKind? {
        if let p = preferred, here.contains(p) { return p }
        return here.first
    }

    /// The model for a request, or nil for the agent's own default.
    nonisolated static func model(_ k: AgentKind, _ s: AgentRequest.Speed) -> String? {
        switch (k, s) {
        case (.claude, .fast): return "haiku"
        case (.claude, .smart): return ChatAgent.claude.model.id
        case (.codex, .fast): return CodexModels.list.last?.id
        case (.codex, .smart): return ChatAgent.codex.model.id
        case (.pi, _): return nil  // pi's own pick (pi config): it can be any provider
        case (.opencode, _): return nil  // opencode's provider/model config is its own
        }
    }

    /// Runs the request on `kind`, or on the agent Takes uses. Off the main thread.
    static func run(_ r: AgentRequest, on kind: AgentKind? = nil) async -> AgentReply {
        // Finding the CLI may start a login shell: never on the main thread.
        await Task.detached(priority: .userInitiated) {
            guard let k = kind ?? pick(), let exe = path(k) else {
                return .failed("No agent is set up. Click Finish setup in the sidebar.")
            }
            return execute(exe, k.adapter, r)
        }.value
    }

    nonisolated static func execute(_ exe: String, _ a: AgentAdapter, _ r: AgentRequest) -> AgentReply {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = a.arguments(r)
        p.currentDirectoryURL = r.folder
        p.environment = a.environment(r, base: ClaudeChat.environment())
        let input = Pipe(), out = Pipe(), err = Pipe()
        p.standardInput = input
        p.standardOutput = out
        p.standardError = err
        // Both pipes are read as they fill: a full pipe would stop the agent.
        let o = OutputBuffer(), e = OutputBuffer()
        out.fileHandleForReading.readabilityHandler = { o.append($0.availableData) }
        err.fileHandleForReading.readabilityHandler = { e.append($0.availableData) }
        do { try p.run() } catch { return .failed("\(a.kind.name) did not start: \(error.localizedDescription)") }
        input.fileHandleForWriting.write(Data(r.stdin.utf8))
        try? input.fileHandleForWriting.close()
        var late = false
        let killer = DispatchWorkItem { if p.isRunning { late = true; p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + r.seconds, execute: killer)
        p.waitUntilExit()
        killer.cancel()
        out.fileHandleForReading.readabilityHandler = nil
        err.fileHandleForReading.readabilityHandler = nil
        o.append(out.fileHandleForReading.readDataToEndOfFile())
        e.append(err.fileHandleForReading.readDataToEndOfFile())
        if late { return .failed("\(a.kind.name) took longer than \(Int(r.seconds)) s.") }
        return a.reply(out: String(decoding: o.data, as: UTF8.self), err: String(decoding: e.data, as: UTF8.self),
                       status: p.terminationStatus)
    }
}
