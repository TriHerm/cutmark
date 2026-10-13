import Foundation

// Finish setup takes any one signed-in agent (2026-10-12). Before, it asked every Mac for Claude Code,
// so a Codex, pi or opencode user downloaded 240 MB they did not need. A Mac with no agent now chooses
// one first; each agent says here how to install it, check its sign-in and sign in.

extension AgentKind {
    struct Installation: Equatable, Sendable {
        let command: String
        let detail: String
        let hint: String
    }

    /// A provider's supported install path. Setup opens these explicit commands in Terminal only after
    /// the user picks a provider; it never silently chooses or installs one.
    var installation: Installation {
        switch self {
        case .claude:
            return Installation(command: Agents.claudeInstaller,
                                detail: "Uses Anthropic's Claude Code installer in Terminal.",
                                hint: "Install Claude Code for Cutmark.")
        case .codex:
            return Installation(command: "npm install -g @openai/codex@latest",
                                detail: "Installs the official OpenAI Codex CLI with npm. Node.js and npm must already be available on this Mac.",
                                hint: "Install Codex for Cutmark with npm.")
        case .pi:
            return Installation(command: "curl -fsSL https://pi.dev/install.sh | sh",
                                detail: "Uses pi's official installer. It can install the required runtime when needed.",
                                hint: "Install pi for Cutmark.")
        case .opencode:
            return Installation(command: "curl -fsSL https://opencode.ai/install | bash",
                                detail: "Uses opencode's official installer in Terminal.",
                                hint: "Install opencode for Cutmark.")
        }
    }

    /// Whether the agent can answer: signed in, or set up with a key. Runs its CLI: off the main thread.
    nonisolated func signedIn(_ exe: String) -> Bool {
        switch self {
        case .claude: return Self.claudeSignedIn(AgentCheck.run(exe, ["auth", "status"]) ?? "")
        case .codex: return Self.codexSignedIn(AgentCheck.run(exe, ["login", "status"], errors: true))
        case .pi: return Self.piSignedIn()
        // opencode can use stored credentials, environment credentials, or local providers. There is
        // no universal login bit, so an installed CLI is ready and surfaces provider errors on use.
        case .opencode: return true
        }
    }

    /// `claude auth status` prints JSON with "loggedIn", sometimes after a warning line.
    nonisolated static func claudeSignedIn(_ status: String) -> Bool {
        guard let start = status.firstIndex(of: "{"),
              let json = try? JSONSerialization.jsonObject(with: Data(status[start...].utf8)) as? [String: Any]
        else { return false }
        return json["loggedIn"] as? Bool ?? false
    }

    /// `codex login status`: "Logged in using ChatGPT" (or an API key). nil: it failed.
    nonisolated static func codexSignedIn(_ out: String?) -> Bool {
        guard let s = out?.lowercased() else { return false }
        return s.contains("logged in") && !s.contains("not logged in")
    }

    /// pi signs in per provider: one login in auth.json, or one provider of its own in models.json.
    nonisolated static func piSignedIn(dir: URL = piDir) -> Bool {
        func object(_ name: String) -> [String: Any]? {
            (try? Data(contentsOf: dir.appending(path: name))).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        }
        let logins = object("auth.json")?.count ?? 0
        let providers = (object("models.json")?["providers"] as? [String: Any])?.count ?? 0
        return logins + providers > 0
    }

    /// PI_CODING_AGENT_DIR, else ~/.pi/agent.
    nonisolated static var piDir: URL {
        ProcessInfo.processInfo.environment["PI_CODING_AGENT_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".pi/agent")
    }

    /// What Terminal runs to sign in, after the line it shows first.
    var login: (args: [String], hint: String) {
        switch self {
        case .claude: return (["auth", "login"], "Sign in to Claude Code for Cutmark. Your browser opens.")
        case .codex: return (["login"], "Sign in to Codex for Cutmark. Your browser opens.")
        case .pi: return ([], "Sign in to a model provider for pi: type /login, pick one, then type /quit.")
        case .opencode: return (["auth", "login"], "Choose a provider for opencode, then return to Cutmark.")
        }
    }
}

extension Agents {
    /// Anthropic's supported Claude Code installer, offered only when the user explicitly picks Claude.
    static let claudeInstaller = "curl -fsSL https://claude.ai/install.sh | bash"
}
