import Foundation
import Testing
@testable import Cutmark

// The chat on Codex, and the model pick (2026-10-11). The lines are what `codex exec --json` 0.156
// printed on this Mac.
struct CodexParseTests {
    @Test func aCodexTurnBecomesMessagesAndSteps() {
        var p = ChatParser([])
        for line in [
            #"{"type":"thread.started","thread_id":"01a12be9-f784-7a80-892d-bcdf0970a9bd"}"#,
            #"{"type":"item.completed","item":{"id":"item_0","type":"error","message":"Model metadata for `x` not found."}}"#,
            #"{"type":"turn.started"}"#,
            #"{"type":"item.completed","item":{"id":"item_2","type":"agent_message","text":"I'll look.\n"}}"#,
            #"{"type":"item.started","item":{"id":"item_3","type":"mcp_tool_call","server":"cutmark","tool":"get_session","arguments":{},"status":"in_progress"}}"#,
            #"{"type":"item.started","item":{"id":"item_4","type":"command_execution","command":"/bin/zsh -lc 'ffmpeg -i a.mov'","status":"in_progress"}}"#,
        ] { p.consume(line) }
        #expect(p.started)
        #expect(p.thread == "01a12be9-f784-7a80-892d-bcdf0970a9bd")
        #expect(p.messages.map(\.text) == ["I'll look.", "get session", "Bash · ffmpeg -i a.mov"], "warnings stay out")
        #expect(p.messages.filter { !$0.done }.count == 2)
        p.consume(#"{"type":"item.completed","item":{"id":"item_3","type":"mcp_tool_call","server":"cutmark","tool":"get_session","arguments":{},"status":"completed"}}"#)
        #expect(p.messages[1].done && !p.messages[2].done)
        p.consume(#"{"type":"item.completed","item":{"id":"item_5","type":"agent_message","text":"Done."}}"#)
        p.consume(#"{"type":"turn.completed","usage":{"input_tokens":107988,"cached_input_tokens":92928,"output_tokens":135}}"#)
        #expect(p.finished)
        #expect(p.messages.allSatisfy { $0.done })
        #expect(p.messages.last?.text == "Done.")
        #expect(p.context == ChatContext(used: 108_123, window: 272_000))
    }

    @Test func aFailedTurnShowsTheServersOwnWords() {
        var p = ChatParser([])
        p.consume(#"{"type":"turn.failed","error":{"message":"{\"type\":\"error\",\"status\":400,\"error\":{\"type\":\"invalid_request_error\",\"message\":\"The 'gpt-6.1-sol' model is not supported when using Codex with a ChatGPT account.\"}}"}}"#)
        #expect(p.finished)
        #expect(p.messages.last?.role == .error)
        #expect(p.messages.last?.text == "The 'gpt-6.1-sol' model is not supported when using Codex with a ChatGPT account.")
    }

    @Test func codexModelsComeFromItsOwnList() {
        let json = #"{"models":[{"slug":"gpt-reserve","visibility":"hide","priority":1},{"slug":"gpt-6-sol","display_name":"GPT-6-Sol","visibility":"list","priority":3,"description":"Workhorse."},{"slug":"gpt-6-astra","display_name":"GPT-6-Astra","visibility":"list","priority":2,"description":"Best."},{"slug":"gpt-6-luna","visibility":"list","priority":4},{"slug":"gpt-5.6-sol","visibility":"list","priority":5}]}"#
        let m = CodexModels.parse(json) ?? []
        #expect(m.map(\.id) == ["gpt-6-astra", "gpt-6-sol", "gpt-6-luna"])
        #expect(m.map(\.name) == ["GPT-6 Astra", "GPT-6 Sol", "gpt-6-luna"])
    }

    @Test func signInLines() {
        #expect(AgentsStatus.codexLine("Logged in using ChatGPT\n") == "Signed in · uses your ChatGPT plan")
        #expect(AgentsStatus.codexLine(nil).hasPrefix("Not signed in"))
        #expect(AgentsStatus.claudeLine(#"{"loggedIn": true, "authMethod": "claude.ai"}"#) == "Signed in · uses your Claude plan")
        #expect(AgentsStatus.claudeLine(#"{"loggedIn": false}"#).hasPrefix("Not signed in"))
    }

    @Test func tomlStringsSurviveQuotesAndNewlines() {
        #expect(CodexAdapter.toml("a \"b\"\n\\c\t") == #""a \"b\"\n\\c\t""#)
        #expect(CodexAdapter.toml("\u{1}é") == #""\u0001é""#)
    }

    @MainActor @Test func codexArgumentsForANewAndAResumedThread() {
        let new = CodexAdapter.chatArguments(context: "Be short.", model: "gpt-6-astra", thread: nil, chat: "c-1", board: nil,
                                            access: "bypassPermissions", cutmarkInCodex: true)
        #expect(new.first == "exec" && !new.contains("resume") && new.last == "-")
        #expect(new.contains("sandbox_mode=\"danger-full-access\""))
        #expect(new.contains("developer_instructions=\"Be short.\""))
        #expect(new.contains("mcp_servers.cutmark.env.CUTMARK_CHAT_ID=\"c-1\""))
        #expect(new[new.firstIndex(of: "-m")! + 1] == "gpt-6-astra")
        let resumed = CodexAdapter.chatArguments(context: "x", model: "gpt-6-luna", thread: "t-9", chat: "c-1", board: "board",
                                                access: "acceptEdits", cutmarkInCodex: false)
        #expect(Array(resumed.prefix(2)) == ["exec", "resume"])
        #expect(Array(resumed.suffix(2)) == ["t-9", "-"])
        #expect(resumed.contains("sandbox_mode=\"workspace-write\""))
        #expect(!resumed.contains { $0.hasPrefix("mcp_servers.cutmark") }, "no Cutmark server in Codex: no -c for it")
    }
}

struct OpenCodeParseTests {
    @Test func anOpenCodeTurnBecomesMessagesStepsAndAReusableSession() {
        var p = ChatParser([], adapter: OpenCodeAdapter())
        for line in [
            #"{"type":"step_start","sessionID":"ses-77","part":{"type":"step-start"}}"#,
            #"{"type":"tool_use","sessionID":"ses-77","part":{"type":"tool","callID":"call-1","tool":"read","state":{"status":"completed","input":{"file_path":"script.md"}}}}"#,
            #"{"type":"text","sessionID":"ses-77","part":{"type":"text","text":"Done from opencode."}}"#,
            #"{"type":"step_finish","sessionID":"ses-77","part":{"type":"step-finish","tokens":{"input":120,"output":20,"reasoning":3,"cache":{"read":10,"write":0}}}}"#,
        ] { p.consume(line) }
        #expect(p.started && !p.finished, "step_finish ends one model step, not the whole opencode process")
        #expect(p.thread == "ses-77")
        #expect(p.messages.map(\.text) == ["read · script.md", "Done from opencode."])
        #expect(p.messages.allSatisfy { $0.done })
        #expect(p.context?.used == 153)
    }

    @Test func anOpenCodeToolErrorAndProviderErrorStayVisible() {
        var p = ChatParser([], adapter: OpenCodeAdapter())
        p.consume(#"{"type":"tool_use","sessionID":"ses-1","part":{"type":"tool","callID":"call-1","tool":"bash","state":{"status":"error","input":{"command":"x"}}}}"#)
        #expect(p.messages.last?.failed == true)
        p.consume(#"{"type":"error","sessionID":"ses-1","error":{"message":"Provider unavailable"}}"#)
        #expect(p.finished)
        #expect(p.messages.last?.role == .error && p.messages.last?.text == "Provider unavailable")
    }

    @Test func opencodeChatArgumentsAndEnvironmentAreProcessLocal() {
        let adapter = OpenCodeAdapter()
        let fresh = ChatTurn(context: "Be short.", model: "", conversation: "c-1", thread: nil,
                             started: false, access: "bypassPermissions", board: nil)
        #expect(adapter.chatArguments(fresh) == ["run", "--format", "json", "--agent", "cutmark-chat"])
        let resumed = ChatTurn(context: "Use Cutmark.", model: "", conversation: "c-1", thread: "ses-77",
                               started: true, access: "acceptEdits", board: nil)
        #expect(adapter.chatArguments(resumed).suffix(2) == ["--session", "ses-77"])
        let env = adapter.chatEnvironment(resumed, base: ["CUTMARK_CHAT_ID": "c-1"])
        #expect(env["CUTMARK_CHAT_ID"] == "c-1")
        #expect(env["OPENCODE_CONFIG_CONTENT"]?.contains("cutmark-chat") == true)
        #expect(env["OPENCODE_CONFIG_CONTENT"]?.contains("Use Cutmark.") == true)
        #expect(env["OPENCODE_PERMISSION"]?.contains(#""bash":"deny""#) == true)
    }
}

@MainActor
@Suite(.serialized)
struct OpenCodeRunTests {
    let dir: URL
    let session: URL

    init() throws {
        dir = FileManager.default.temporaryDirectory.appending(path: "fakeopencode-\(UUID().uuidString)")
        session = dir.appending(path: "P/2026-10-13-test")
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        let script = dir.appending(path: "opencode")
        try """
        #!/bin/bash
        n=$(( $(cat "\(dir.path)/n" 2>/dev/null || echo 0) + 1 )); echo $n > "\(dir.path)/n"
        printf '%s\\n' "$@" > "\(dir.path)/args-$n.txt"
        printf '%s' "$OPENCODE_CONFIG_CONTENT" > "\(dir.path)/config-$n.json"
        printf '%s' "$OPENCODE_PERMISSION" > "\(dir.path)/permission-$n.json"
        cat > "\(dir.path)/ask-$n.txt"
        echo '{"type":"step_start","sessionID":"ses-77","part":{"type":"step-start"}}'
        echo '{"type":"text","sessionID":"ses-77","part":{"type":"text","text":"Hi from opencode"}}'
        echo '{"type":"step_finish","sessionID":"ses-77","part":{"type":"step-finish","tokens":{"input":10,"output":2}}}'
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        Agents.overrides[.opencode] = script.path
    }

    func args(_ n: Int) -> [String] {
        ((try? String(contentsOf: dir.appending(path: "args-\(n).txt"), encoding: .utf8)) ?? "").components(separatedBy: "\n")
    }

    func until(_ ok: () -> Bool) async {
        let end = Date().addingTimeInterval(15)
        while !ok() && Date() < end { try? await Task.sleep(for: .milliseconds(50)) }
    }

    func cleanup() {
        Agents.overrides[.opencode] = nil
        try? FileManager.default.removeItem(at: dir)
    }

    @Test func anOpenCodeConversationPersistsAndResumesItsSession() async throws {
        defer { cleanup() }
        let chat = ClaudeChat(session: session)
        chat.switchAgent(to: .opencode, remember: false)
        chat.send("Cut it", title: "Test", onStage: nil)
        await until { !chat.running && chat.messages.count == 2 }
        #expect(chat.messages.map(\.text) == ["Cut it", "Hi from opencode"])
        #expect(!args(1).contains("--session"))
        chat.send("Again", title: "Test", onStage: nil)
        await until { !chat.running && chat.messages.count == 4 }
        #expect(args(2).contains("--session") && args(2).contains("ses-77"))
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let log = try dec.decode(ChatLog.self, from: Data(contentsOf: ClaudeChat.file(session)))
        #expect(log.agent == "opencode" && log.thread == "ses-77")
        let config = try String(contentsOf: dir.appending(path: "config-1.json"), encoding: .utf8)
        #expect(config.contains("cutmark-chat"))
    }

    @Test func aLaterProcessFailureIsNotHiddenByStepFinish() async throws {
        defer { cleanup() }
        let script = dir.appending(path: "opencode")
        try """
        #!/bin/bash
        cat >/dev/null
        echo '{"type":"step_start","sessionID":"ses-fail","part":{"type":"step-start"}}'
        echo '{"type":"text","sessionID":"ses-fail","part":{"type":"text","text":"Partial"}}'
        echo '{"type":"step_finish","sessionID":"ses-fail","part":{"type":"step-finish","tokens":{"input":5,"output":1}}}'
        echo 'provider failed after tool step' >&2
        exit 7
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let chat = ClaudeChat(session: session)
        chat.switchAgent(to: .opencode, remember: false)
        chat.send("Try it", title: "Test", onStage: nil)
        await until { !chat.running && chat.messages.count >= 3 }
        #expect(chat.messages.contains { $0.role == .error && $0.text.contains("provider failed after tool step") })
    }

    @Test func anOutlivingChildCannotHoldTheChatOpenOrLoseItsFinalLine() async throws {
        defer { cleanup() }
        let script = dir.appending(path: "opencode")
        try """
        #!/bin/bash
        cat >/dev/null
        sleep 4 &
        echo '{"type":"step_start","sessionID":"ses-child","part":{"type":"step-start"}}'
        echo '{"type":"text","sessionID":"ses-child","part":{"type":"text","text":"Done before child"}}'
        echo '{"type":"step_finish","sessionID":"ses-child","part":{"type":"step-finish","tokens":{"input":5,"output":1}}}'
        exit 0
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let chat = ClaudeChat(session: session)
        chat.switchAgent(to: .opencode, remember: false)
        chat.send("Try it", title: "Test", onStage: nil)
        try? await Task.sleep(for: .seconds(1))
        #expect(!chat.running, "a child that inherits the pipe must not keep the turn open")
        #expect(chat.messages.map(\.text) == ["Try it", "Done before child"])
    }
}

/// A fake codex: saves its arguments and the ask, starts a thread, answers.
@MainActor
@Suite(.serialized)
struct CodexRunTests {
    let dir: URL
    let session: URL

    init() throws {
        dir = FileManager.default.temporaryDirectory.appending(path: "fakecodex-\(UUID().uuidString)")
        session = dir.appending(path: "P/2026-10-11-test")
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        // Only codex: claudeOverride belongs to the other chat suites, which run side by side.
        for (name, body) in [
            ("codex", #"echo '{"type":"thread.started","thread_id":"thread-77"}'; echo '{"type":"item.completed","item":{"id":"i1","type":"agent_message","text":"Hi from Codex"}}'; echo '{"type":"turn.completed","usage":{"input_tokens":10,"output_tokens":2}}'"#),
        ] {
            let script = dir.appending(path: name)
            try """
            #!/bin/bash
            n=$(( $(cat "\(dir.path)/n" 2>/dev/null || echo 0) + 1 )); echo $n > "\(dir.path)/n"
            printf '%s\\n' "\(name)" "$@" > "\(dir.path)/args-$n.txt"
            cat > "\(dir.path)/ask-$n.txt"
            \(body)
            """.write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        }
        ClaudeChat.codexOverride = dir.appending(path: "codex").path
    }

    func args(_ n: Int) -> [String] {
        ((try? String(contentsOf: dir.appending(path: "args-\(n).txt"), encoding: .utf8)) ?? "").components(separatedBy: "\n")
    }

    func until(_ ok: () -> Bool) async {
        let end = Date().addingTimeInterval(15)
        while !ok() && Date() < end { try? await Task.sleep(for: .milliseconds(50)) }
    }

    func cleanup() {
        ClaudeChat.codexOverride = nil
        try? FileManager.default.removeItem(at: dir)
    }

    @Test func aCodexConversationStartsAThreadAndResumesIt() async throws {
        defer { cleanup() }
        // Other chat tests run side by side: the global pick stays as it is.
        let chat = ClaudeChat(session: session)
        chat.switchAgent(to: .codex, remember: false)
        #expect(chat.agent == .codex)
        chat.send("Cut it", title: "Test", onStage: nil)
        await until { !chat.running && chat.messages.count == 2 }
        #expect(chat.messages.map(\.text) == ["Cut it", "Hi from Codex"])
        #expect(args(1).first == "codex" && !args(1).contains("resume"))
        chat.send("Again", title: "Test", onStage: nil)
        await until { !chat.running && chat.messages.count == 4 }
        #expect(args(2).contains("resume") && args(2).contains("thread-77"))
        // A started conversation stays on Codex.
        #expect(!chat.switchAgent(to: .codex, remember: false))
        #expect(chat.agent == .codex)
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let log = try dec.decode(ChatLog.self, from: Data(contentsOf: ClaudeChat.file(session)))
        #expect(log.agent == "codex" && log.thread == "thread-77")
    }

    @Test func switchingAgentStartsANewConversationAndKeepsTheOld() async throws {
        defer { cleanup() }
        // A Claude Code conversation that has started.
        let log = ChatLog(conversation: "c-claude", started: true, messages: [ChatMessage(role: .user, text: "Hello")], agent: "claude")
        try JSONEncoder().encode(log).write(to: ClaudeChat.file(session))
        let chat = ClaudeChat(session: session)
        #expect(chat.agent == .claude)
        #expect(chat.switchAgent(to: .codex, remember: false), "a started Claude conversation cannot go on in Codex")
        #expect(chat.messages.isEmpty && chat.agent == .codex)
        #expect(chat.past().count == 1)
        // Before its first reply a conversation just follows the pick.
        #expect(!chat.switchAgent(to: .claude, remember: false))
        #expect(chat.agent == .claude)
    }
}
