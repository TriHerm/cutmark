import Foundation
import Testing
@testable import Cutmark

extension ChatRunTests {
    @MainActor @Suite(.serialized) struct QuickPlanChatTests {
        @Test func organizingUsesASavedCopyAndTheExistingAgentAdapter() async throws {
            let root = FileManager.default.temporaryDirectory.appending(path: "quick-plan-chat-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let previousAgent = ChatAgent.current
            let setup = Setup.shared, agent = setup.agent, signIn = setup.signedIn
            defer {
                ClaudeChat.claudeOverride = nil; ChatAgent.current = previousAgent
                setup.agent = agent; setup.signedIn = signIn
                try? FileManager.default.removeItem(at: root)
            }
            let fake = root.appending(path: "claude")
            try """
            #!/bin/bash
            cat > /dev/null
            echo '{"type":"system","subtype":"init"}'
            echo '{"type":"assistant","message":{"content":[{"type":"text","text":"Ready for review."}]}}'
            echo '{"type":"result","subtype":"success","result":"","modelUsage":{}}'
            """.write(to: fake, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
            ChatAgent.current = .claude; ClaudeChat.claudeOverride = fake.path
            let app = AppModel(); app.library.setRoot(root)
            let doc = try #require(app.library.createSession())
            doc.script = "My rough idea, in my words."; doc.flushScript()
            setup.agent = .missing; setup.signedIn = .missing
            #expect(try app.organizeDraft(doc) == nil && doc.variants.isEmpty)
            setup.agent = .ok; setup.signedIn = .ok
            let slug = try #require(try app.organizeDraft(doc))
            let chat = app.chats.chat(doc.url)
            #expect(doc.activeDraft == slug && doc.activeText == "My rough idea, in my words.")
            #expect(SessionDoc(url: doc.url).readVariants().first(where: { $0.slug == slug })?.text == doc.activeText)
            #expect(chat.messages.first(where: { $0.role == .user })?.text == TakePlan.organizeRequest(variant: slug))
            #expect(app.chats.open && app.chats.docked)
            #expect(try String(contentsOf: doc.url.appending(path: "script.md"), encoding: .utf8) == "My rough idea, in my words.")
            let deadline = Date().addingTimeInterval(10)
            while chat.running && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
            #expect(!chat.running && chat.messages.contains(where: { $0.role == .claude && $0.text == "Ready for review." }))
            #expect(app.library.sessions.count == 1)
        }
    }
}
