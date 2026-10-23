import Foundation
import Testing
@testable import Cutmark

struct TimelineRenderTests {
    private let session = URL(filePath: "/tmp/cutmark-timeline-test/session", directoryHint: .isDirectory)

    @Test func rawTakeRendersCanonicalRecipeWithoutAgentOrPublish() throws {
        let take = Take(number: 7, kind: .screen, file: "take-07-screen.mov",
                        startedAt: .distantPast, duration: 8)
        var draft = try #require(EditTimelineDraft.fromTake(take, duration: 8, fps: 30))
        let didSplit = draft.apply(.init(op: "split", index: 0, at: 4))
        let didMove = draft.apply(.init(op: "move", index: 1, to: 0))
        #expect(didSplit && didMove)
        let data = try TimelineRender.request(draft: draft, session: session)
        let request = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(request["session"] as? String == session.path)
        #expect(request["base"] == nil)
        #expect(request["actions"] == nil)
        #expect(request["publish"] == nil)
        let recipe = try #require(request["recipe"] as? [String: Any])
        #expect(recipe["name"] as? String == "clip-take-07-screen")
        let cuts = try #require(recipe["cut"] as? [[String: Any]])
        #expect(cuts.count == 2)
        #expect(cuts[0]["in"] as? Double == 4)
        #expect(cuts[1]["out"] as? Double == 4)
    }

    @Test func publishedEditSendsOrderedOperationsWithoutRewritingEffects() throws {
        let source = [EditTimelineDraft.Segment(take: 3, kind: "camera", start: 0, end: 8)]
        var draft = EditTimelineDraft(base: "edits/demo-v2.mp4", fps: 30,
                                      source: source, segments: source)
        let didSplit = draft.apply(.init(op: "split", index: 0, at: 3))
        let didMove = draft.apply(.init(op: "move", index: 1, to: 0))
        #expect(didSplit && didMove)
        let data = try TimelineRender.request(draft: draft, session: session)
        let request = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(request["recipe"] == nil)
        #expect(request["base"] as? String == "edits/demo-v2.mp4")
        #expect(request["publish"] == nil)
        let actions = try #require(request["actions"] as? [[String: Any]])
        #expect(actions.count == 2)
        #expect(actions.map { $0["op"] as? String } == ["split", "move"])
        #expect(actions[0]["at"] as? Double == 3)
        #expect(actions[1]["to"] as? Int == 0)
    }

    @Test func cannotRenderStaleOrTamperedDraft() throws {
        let source = [EditTimelineDraft.Segment(take: 1, kind: "screen", start: 0, end: 5)]
        let noEdits = EditTimelineDraft(base: "edits/demo-v1.mp4", fps: 30,
                                        source: source, segments: source)
        #expect(throws: TimelineRender.Failure.self) {
            try TimelineRender.request(draft: noEdits, session: session)
        }
        var edited = noEdits
        let didSplit = edited.apply(.init(op: "split", index: 0, at: 2))
        #expect(didSplit)
        let tampered = EditTimelineDraft(base: edited.base, fps: edited.fps,
                                         source: edited.source, segments: edited.source,
                                         actions: edited.actions)
        #expect(throws: TimelineRender.Failure.self) {
            try TimelineRender.request(draft: tampered, session: session)
        }
        let malformed = EditTimelineDraft(base: edited.base, fps: 30,
                                          source: source, segments: edited.segments,
                                          actions: [.init(op: "remove", index: 6)])
        #expect(throws: TimelineRender.Failure.self) {
            try TimelineRender.request(draft: malformed, session: session)
        }
    }

    @Test func helperFailureReturnsErrorInsteadOfCrashing() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "cutmark-render-helper-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let script = root.appending(path: "failure.py")
        try Data("import sys\nsys.exit(1)\n".utf8).write(to: script)
        await #expect(throws: TimelineRender.Failure.self) {
            try await TimelineRender.run(request: Data(repeating: 88, count: 200_000), script: script)
        }
    }

    @Test func stalledHelperHasBoundedLifetime() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "cutmark-render-stall-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let script = root.appending(path: "stall.py")
        // SIGTERM alone is insufficient: the helper can trap it while blocked.
        try Data("import signal, sys, time\nsignal.signal(signal.SIGTERM, signal.SIG_IGN)\nsys.stdin.read()\ntime.sleep(90)\n".utf8).write(to: script)
        await #expect(throws: TimelineRender.Failure.self) {
            try await TimelineRender.run(request: Data("{}".utf8), script: script, timeoutSeconds: 0.5)
        }
    }
}
