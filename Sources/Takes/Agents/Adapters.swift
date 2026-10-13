import Foundation

// The agent CLIs, each in print mode: the request on stdin, one answer, then exit (2026-10-12).
// Output shapes are from real runs on this Mac; AgentsTests keeps a sample of each.

/// `claude -p --output-format json`: one object, `result` is the answer, `is_error` says it failed.
/// --safe-mode leaves out CLAUDE.md, skills, plugins and MCP servers: a session name took 249,000
/// tokens with them ($0.25) and 2,300 without ($0.0005).
struct ClaudeAdapter: AgentAdapter {
    var kind: AgentKind { .claude }

    func arguments(_ r: AgentRequest) -> [String] {
        var a = ["-p", "--output-format", "json", "--no-session-persistence", "--safe-mode", "--strict-mcp-config",
                 "--permission-mode", "dontAsk", "--tools", r.tools == .read ? "Read" : ""]
        if let m = Agents.model(.claude, r.speed) { a += ["--model", m] }
        return a
    }

    func reply(out: String, err: String, status: Int32) -> AgentReply {
        guard let o = try? JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any] else {
            return noAnswer(out, err, status)
        }
        let text = (o["result"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if o["is_error"] as? Bool == true || status != 0 {
            return .failed(text.isEmpty ? lastLine(err) ?? "Claude Code stopped (exit \(status))." : text)
        }
        return text.isEmpty ? noAnswer(out, err, status) : AgentReply(text: text)
    }
}

/// `codex exec --json`: one event per line. The answer is the last agent_message; turn.failed or an
/// error event ends the run. An "error" item (a warning from the user's config) is not a failure.
struct CodexAdapter: AgentAdapter {
    var kind: AgentKind { .codex }

    func arguments(_ r: AgentRequest) -> [String] {
        // Codex has no switch to turn its tools off: read-only is the least it gets.
        var a = ["exec", "--json", "--skip-git-repo-check", "--ephemeral", "-s", "read-only",
                 "-c", "approval_policy=\"never\""]
        if let m = Agents.model(.codex, r.speed) { a += ["-m", m] }
        return a + ["-"]
    }

    func reply(out: String, err: String, status: Int32) -> AgentReply {
        var text: String?, failure: String?
        for line in out.split(whereSeparator: \.isNewline) {
            guard let e = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            switch e["type"] as? String {
            case "item.completed":
                if let item = e["item"] as? [String: Any], item["type"] as? String == "agent_message" {
                    text = item["text"] as? String
                }
            case "turn.failed":
                failure = ((e["error"] as? [String: Any])?["message"] as? String) ?? "Codex stopped."
            case "error":
                failure = e["message"] as? String ?? "Codex stopped."
            default: break
            }
        }
        if let f = failure { return .failed(f) }
        if let t = text?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty { return AgentReply(text: t) }
        return noAnswer(out, err, status)
    }
}

/// `pi -p --mode json`: one event per line; agent_end holds the messages. The answer is the text of the
/// last assistant message; its stopReason "error" carries errorMessage. pi uses the model set in pi.
struct PiAdapter: AgentAdapter {
    var kind: AgentKind { .pi }

    func arguments(_ r: AgentRequest) -> [String] {
        ["-p", "--mode", "json", "--no-session"] + (r.tools == .read ? ["--tools", "read"] : ["--no-tools"])
    }

    func reply(out: String, err: String, status: Int32) -> AgentReply {
        for line in out.split(whereSeparator: \.isNewline).reversed() {
            guard let e = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  e["type"] as? String == "agent_end", let messages = e["messages"] as? [[String: Any]] else { continue }
            guard let last = messages.last(where: { $0["role"] as? String == "assistant" }) else { break }
            if last["stopReason"] as? String == "error" {
                return .failed(last["errorMessage"] as? String ?? "pi stopped.")
            }
            let parts = (last["content"] as? [[String: Any]]) ?? []
            let text = parts.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }
                .joined().trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? noAnswer(out, err, status) : AgentReply(text: text)
        }
        return noAnswer(out, err, status)
    }
}

/// `opencode run --format json`: one terminal JSON event per completed text/tool part. Takes supplies
/// permissions in the process environment so these small feature asks never modify the user's opencode config.
struct OpenCodeAdapter: AgentAdapter {
    var kind: AgentKind { .opencode }

    func arguments(_ r: AgentRequest) -> [String] {
        ["run", "--format", "json"]
    }

    func environment(_ r: AgentRequest, base: [String: String]) -> [String: String] {
        var env = base
        env["OPENCODE_PERMISSION"] = Self.permissions(tools: r.tools)
        return env
    }

    static func permissions(tools: AgentRequest.Tools) -> String {
        let p: [String: String]
        switch tools {
        case .none:
            p = ["*": "deny"]
        case .read:
            p = ["*": "deny", "read": "allow", "list": "allow", "glob": "allow", "grep": "allow"]
        }
        let d = try? JSONSerialization.data(withJSONObject: p, options: [.sortedKeys])
        return d.map { String(decoding: $0, as: UTF8.self) } ?? #"{"*":"deny"}"#
    }

    func reply(out: String, err: String, status: Int32) -> AgentReply {
        var texts: [String] = [], failure: String?
        for line in out.split(whereSeparator: \.isNewline) {
            guard let e = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            switch e["type"] as? String {
            case "text":
                if let p = e["part"] as? [String: Any], let t = p["text"] as? String, !t.isEmpty { texts.append(t) }
            case "error":
                failure = Self.error(e["error"]) ?? e["message"] as? String ?? "opencode stopped."
            default: break
            }
        }
        if let failure { return .failed(failure) }
        if status != 0 {
            return .failed(lastLine(err) ?? "opencode stopped with exit \(status).")
        }
        let text = texts.joined().trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? noAnswer(out, err, status) : AgentReply(text: text)
    }

    static func error(_ value: Any?) -> String? {
        if let s = value as? String, !s.isEmpty { return s }
        if let o = value as? [String: Any] {
            for k in ["message", "name", "type"] {
                if let s = o[k] as? String, !s.isEmpty { return s }
            }
        }
        return nil
    }
}
