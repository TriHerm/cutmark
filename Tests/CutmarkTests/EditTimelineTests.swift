import Foundation
import Testing
@testable import Cutmark

struct EditTimelineTests {
    @Test func splitMoveTrimAndUndoByResetNeverChangePublishedRecipe() throws {
        var draft = EditTimelineDraft(base: "edits/demo-v1.mp4", fps: 30,
            source: [.init(take: 1, kind: "screen", start: 0.5, end: 3.5),
                     .init(take: 2, kind: "camera", start: 4, end: 7)],
            segments: [.init(take: 1, kind: "screen", start: 0.5, end: 3.5),
                       .init(take: 2, kind: "camera", start: 4, end: 7)])
        #expect(draft.apply(.init(op: "split", index: 0, at: 2)))
        #expect(draft.apply(.init(op: "move", index: 2, to: 0)))
        #expect(draft.apply(.init(op: "trim", index: 2, in: 2.2, out: 3)))
        #expect(draft.duration == 3 + 1.5 + 0.8)
        #expect(draft.source[0].end == 3.5)
        #expect(draft.actions.count == 3)
    }

    @Test func shortSegmentsAndInvalidNumbersCannotBeAdded() throws {
        var draft = EditTimelineDraft(base: "edits/demo-v1.mp4", fps: 30,
            source: [.init(take: 1, kind: "screen", start: 0, end: 4)],
            segments: [.init(take: 1, kind: "screen", start: 0, end: 4)])
        #expect(!draft.apply(.init(op: "remove", index: 0)))
        #expect(!draft.apply(.init(op: "split", index: 0, at: 0.01)))
        #expect(!draft.apply(.init(op: "trim", index: 0, in: -.infinity, out: 3)))
        #expect(!draft.apply(.init(op: "trim", index: 0, in: 1, out: 5)))
        #expect(draft.actions.isEmpty)
    }

    @Test func privateDraftKeepsEditFilesUntouched() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "cutmark-timeline-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let video = root.appending(path: "edits/demo-v1.mp4")
        let file = try #require(EditTimelineDraft.file(video: video, session: root))
        #expect(file.path.contains("/_edit/.timeline-drafts/"))
        #expect(!file.path.contains("/edits/"))
        let initial = EditTimelineDraft(base: "edits/demo-v1.mp4", fps: 30,
            source: [.init(take: 1, kind: "camera", start: 0, end: 4)],
            segments: [.init(take: 1, kind: "camera", start: 0, end: 4)])
        try initial.save(video: video, session: root)
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(!FileManager.default.fileExists(atPath: EditRecipe.url(for: video).path))
        EditTimelineDraft.clear(video: video, session: root)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }
}
