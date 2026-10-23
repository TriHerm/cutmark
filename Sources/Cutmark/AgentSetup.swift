import Foundation

/// First-launch setup for agents so a downloaded Cutmark works without build.sh.
/// `cutmark_mcp.py --setup --once` adds the `cutmark` server to Claude Code, Codex, Cursor,
/// Gemini CLI, opencode, pi and Claude Desktop, each
/// one found on this Mac. It adds it once per agent (Claude Code always), and again only when the
/// app moved. It changes only Cutmark-owned MCP entries. The skills the build ships in
/// Resources/skills go to ~/.claude/skills (Claude Code,
/// Cursor) and ~/.agents/skills (Codex, pi, opencode, Gemini CLI). It touches only the `cutmark`
/// server and installs missing skill folders. Existing skill folders remain user-owned.
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

    nonisolated struct SkillSyncResult {
        var installed: [String] = []
        var preserved: [String] = []
        var failed: [String: String] = [:]
    }

    /// Install a missing skill once. Existing same-name folders can be customized or from an
    /// older version with no provenance, so upgrading them requires a deliberate manual action.
    @discardableResult
    nonisolated static func copySkills(from dir: URL,
                                       to target: URL = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude/skills")) -> SkillSyncResult {
        let fm = FileManager.default
        var result = SkillSyncResult()
        do {
            let sources = try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            guard !sources.isEmpty else { return result }
            try requireSafeTargetPath(target)
            try fm.createDirectory(at: target, withIntermediateDirectories: true)
            for source in sources.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                guard fm.fileExists(atPath: source.appending(path: "SKILL.md").path) else { continue }
                let name = source.lastPathComponent
                let destination = target.appending(path: name)
                if existsIncludingSymlinks(destination) {
                    result.preserved.append(name)
                    continue
                }
                do {
                    try requireSourceTree(source)
                    let stage = target.appending(path: ".cutmark-stage-\(UUID().uuidString)")
                    defer { try? fm.removeItem(at: stage) }
                    try fm.copyItem(at: source, to: stage)
                    try requireSourceTree(stage)
                    try requireSafeTargetPath(target)
                    // Another process may have installed this skill while the copy was staged.
                    if existsIncludingSymlinks(destination) {
                        result.preserved.append(name)
                        continue
                    }
                    // Rename is atomic on this volume and never replaces an existing directory.
                    try fm.moveItem(at: stage, to: destination)
                    result.installed.append(name)
                } catch {
                    result.failed[name] = error.localizedDescription
                }
            }
        } catch {
            result.failed["setup"] = error.localizedDescription
        }
        return result
    }

    nonisolated private static func existsIncludingSymlinks(_ url: URL) -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: url.path)
            || (try? fm.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

    /// Reject symlinked directories or files inside a bundled skill before copying them.
    nonisolated private static func requireSourceTree(_ root: URL) throws {
        let fm = FileManager.default
        func visit(_ path: URL) throws {
            let values = try path.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { throw CocoaError(.fileReadCorruptFile) }
            if values.isDirectory == true {
                for child in try fm.contentsOfDirectory(at: path, includingPropertiesForKeys: nil) {
                    try visit(child)
                }
            } else if values.isRegularFile != true {
                throw CocoaError(.fileReadCorruptFile)
            }
        }
        try visit(root)
        let skill = root.appending(path: "SKILL.md")
        guard (try skill.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true else {
            throw CocoaError(.fileReadCorruptFile)
        }
    }

    /// Do not write through a redirected ~/.claude, ~/.agents or skills ancestor.
    /// Stop at the home/temp root to allow the macOS /var -> /private/var system alias.
    nonisolated private static func requireSafeTargetPath(_ target: URL) throws {
        let fm = FileManager.default
        let boundaries = Set([fm.homeDirectoryForCurrentUser, fm.temporaryDirectory]
            .map { $0.standardizedFileURL.resolvingSymlinksInPath().path })
        var cursor = target.standardizedFileURL
        while cursor.path != "/" {
            if let values = try? cursor.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) {
                guard values.isSymbolicLink != true,
                      values.isDirectory == true || !fm.fileExists(atPath: cursor.path) else {
                    throw CocoaError(.fileReadCorruptFile)
                }
            } else if fm.fileExists(atPath: cursor.path) {
                throw CocoaError(.fileReadCorruptFile)
            }
            if boundaries.contains(cursor.resolvingSymlinksInPath().path) { break }
            let parent = cursor.deletingLastPathComponent()
            if parent.path == cursor.path { break }
            cursor = parent
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
