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
        #expect(draft.undoLast())
        #expect(draft.actions.count == 2)
        #expect(draft.segments.last?.start == 2)
        #expect(draft.undoLast())
        #expect(draft.undoLast())
        #expect(!draft.undoLast())
        #expect(draft.segments == draft.source)
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

    @Test func playheadMapsToOneOccurrenceWithHalfOpenBoundariesAndCover() {
        let first = EditTimelineDraft.Segment(take: 1, kind: "screen", start: 2, end: 4)
        let second = EditTimelineDraft.Segment(take: 1, kind: "screen", start: 7, end: 8)
        let draft = EditTimelineDraft(base: "edits/test-v1.mp4", fps: 30,
                                      source: [first, second], segments: [first, second])
        #expect(draft.outputStart(of: 1, lead: 0.25) == 2.25)
        #expect(draft.sourcePoint(atOutput: 0.24, lead: 0.25) == nil)
        let inside = draft.sourcePoint(atOutput: 1.25, lead: 0.25)
        #expect(inside?.index == 0 && inside?.source == 3)
        let next = draft.sourcePoint(atOutput: 2.25, lead: 0.25)
        #expect(next?.index == 1 && next?.source == 7)
        #expect(draft.sourcePoint(atOutput: 3.25, lead: 0.25) == nil)

        var reordered = draft
        #expect(reordered.apply(.init(op: "move", index: 1, to: 0)))
        #expect(reordered.outputStart(of: 0, lead: 0.25) == 0.25)
        // Even though segment 2 is now first in the draft, the player still shows the published
        // version and its original order. Navigation and playhead editing must use that clock.
        #expect(reordered.originalOutputStart(of: 0, lead: 0.25) == 2.25)
        let original = reordered.originalSourcePoint(atOutput: 0.75, lead: 0.25)
        #expect(original?.take == 1 && original?.kind == "screen" && original?.source == 2.5)
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
