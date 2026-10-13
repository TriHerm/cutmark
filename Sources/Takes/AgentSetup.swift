import Foundation

/// First-launch setup for agents so a downloaded Cutmark works without build.sh.
/// `cutmark_mcp.py --setup --once` adds the `cutmark` server to Claude Code, Codex, Cursor,
/// Gemini CLI, opencode, pi and Claude Desktop, each
/// one found on this Mac. It adds it once per agent (Claude Code always), and again only when the
/// app moved. It never changes an upstream `takes` MCP entry. The skills the build ships in
/// Resources/skills go to ~/.claude/skills (Claude Code,
/// Cursor) and ~/.agents/skills (Codex, pi, opencode, Gemini CLI). It touches only the `cutmark`
/// server and the skill folders it ships. In the background, once per launch.
enum AgentSetup {
    static func run() {
        let resources = Bundle.main.bundleURL.appending(path: "Contents/Resources")
        let server = resources.appending(path: "cutmark_mcp.py").path
        guard FileManager.default.fileExists(atPath: server) else { return }
        Task.detached(priority: .utility) {
            // Without the Command Line Tools, /usr/bin/python3 opens Apple's install dialog.
            guard shell("/usr/bin/xcode-select", ["-p"]).0 else { return }
            _ = shell("/usr/bin/python3", [server, "--setup", "--once"])
            let skills = resources.appending(path: "skills")
            copySkills(from: skills)
            copySkills(from: skills, to: FileManager.default.homeDirectoryForCurrentUser.appending(path: ".agents/skills"))
        }
    }

    /// Copies each shipped skill folder over the user's copy of the same name. Only these names.
    nonisolated static func copySkills(from dir: URL, to target: URL = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude/skills")) {
        let fm = FileManager.default
        guard let skills = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        try? fm.createDirectory(at: target, withIntermediateDirectories: true)
        for s in skills where fm.fileExists(atPath: s.appending(path: "SKILL.md").path) {
            let dest = target.appending(path: s.lastPathComponent)
            try? fm.removeItem(at: dest)
            try? fm.copyItem(at: s, to: dest)
        }
    }

    nonisolated private static func shell(_ exe: String, _ args: [String]) -> (Bool, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        for k in env.keys where k.hasPrefix("CLAUDECODE") || k.hasPrefix("CLAUDE_CODE_") { env[k] = nil }
        env["PATH"] = ClaudeChat.shellPath + ":/opt/homebrew/bin:/usr/local/bin"
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
