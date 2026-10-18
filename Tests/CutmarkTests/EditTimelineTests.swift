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
        let didSplit = draft.apply(.init(op: "split", index: 0, at: 2))
        let didMove = draft.apply(.init(op: "move", index: 2, to: 0))
        let didTrim = draft.apply(.init(op: "trim", index: 2, in: 2.2, out: 3))
        #expect(didSplit && didMove && didTrim)
        #expect(draft.duration == 3 + 1.5 + 0.8)
        #expect(draft.source[0].end == 3.5)
        #expect(draft.actions.count == 3)
        let undoTrim = draft.undoLast()
        #expect(undoTrim)
        #expect(draft.actions.count == 2)
        #expect(draft.segments.last?.start == 2)
        let undoMove = draft.undoLast()
        let undoSplit = draft.undoLast()
        let cannotUndo = draft.undoLast()
        #expect(undoMove && undoSplit && !cannotUndo)
        #expect(draft.segments == draft.source)
    }

    @Test func shortSegmentsAndInvalidNumbersCannotBeAdded() throws {
        var draft = EditTimelineDraft(base: "edits/demo-v1.mp4", fps: 30,
            source: [.init(take: 1, kind: "screen", start: 0, end: 4)],
            segments: [.init(take: 1, kind: "screen", start: 0, end: 4)])
        let removed = draft.apply(.init(op: "remove", index: 0))
        let split = draft.apply(.init(op: "split", index: 0, at: 0.01))
        let unbounded = draft.apply(.init(op: "trim", index: 0, in: -.infinity, out: 3))
        let extended = draft.apply(.init(op: "trim", index: 0, in: 1, out: 5))
        #expect(!removed && !split && !unbounded && !extended)
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
        let didReorder = reordered.apply(.init(op: "move", index: 1, to: 0))
        #expect(didReorder)
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

    @Test func recordedTakeOpensEditableTimelineBeforeAnyPublishedRecipe() throws {
        let take = Take(number: 7, kind: .screen, file: "take-07-screen.mov",
                        startedAt: Date(timeIntervalSince1970: 0), duration: 8)
        let raw = try #require(EditTimelineDraft.fromTake(take, duration: 8, fps: 30))
        #expect(raw.isRawTake)
        #expect(raw.source.count == 1)
        #expect(raw.source[0].kind == "screen")
        var edited = raw
        let split = edited.apply(.init(op: "split", index: 0, at: 4))
        let moved = edited.apply(.init(op: "move", index: 1, to: 0))
        #expect(split && moved)
        let recipe = try #require(edited.initialRecipe())
        let cuts = try #require(recipe["cut"] as? [[String: Any]])
        #expect(cuts.count == 2)
        #expect(cuts[0]["in"] as? Double == 4)

        let root = FileManager.default.temporaryDirectory.appending(path: "cutmark-raw-timeline-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let video = root.appending(path: take.file)
        try edited.save(video: video, session: root)
        let recovered = try #require(EditTimelineDraft.restore(video: video, session: root, original: raw))
        #expect(recovered.segments == edited.segments)
        #expect(!FileManager.default.fileExists(atPath: EditRecipe.url(for: video).path))
    }

    @Test func draggedTrimHandlesClampToTwoFramesAndUndo() throws {
        let take = Take(number: 1, kind: .camera, file: "take-01-camera.mov",
                        startedAt: Date(timeIntervalSince1970: 0), duration: 10)
        let raw = try #require(EditTimelineDraft.fromTake(take, duration: 10, fps: 30))
        let start = try #require(raw.trimProposal(index: 0, edge: .start, dragSeconds: 3.04))
        #expect(abs((start.in ?? 0) - 3.033_333) < 0.000_01)
        var edited = raw
        let trimmed = edited.apply(start)
        #expect(trimmed)
        let end = try #require(edited.trimProposal(index: 0, edge: .end, dragSeconds: -50))
        #expect(abs((end.out ?? 0) - (edited.segments[0].start + 2.0 / 30)) < 0.000_01)
        let valid = edited.apply(end)
        #expect(valid)
        #expect(edited.segments[0].duration >= 2.0 / 30 - 0.000_01)
        let restored = edited.undoLast()
        #expect(restored)
        #expect(edited.segments[0].end == 10)
    }

    @Test func reextendTrimWithoutUndoAndReturnToStartWithNoAction() throws {
        let take = Take(number: 3, kind: .screen, file: "take-03-screen.mov",
                        startedAt: .distantPast, duration: 10)
        let raw = try #require(EditTimelineDraft.fromTake(take, duration: 10, fps: 30))
        var draft = raw
        // A drag that moves inward then returns to its original position should do nothing.
        #expect(raw.trimProposal(index: 0, edge: .start, dragSeconds: 0) == nil)
        let shorter = try #require(draft.trimProposal(index: 0, edge: .start, dragSeconds: 3))
        #expect(shorter.op == "trim")
        let shortened = draft.apply(shorter)
        #expect(shortened)
        #expect(draft.segments[0].start == 3)
        // Subsequent outward drag recovers hidden frames, without an Undo command.
        let extended = try #require(draft.trimProposal(index: 0, edge: .start, dragSeconds: -2))
        #expect(extended.op == "extend")
        let grew = draft.apply(extended)
        #expect(grew)
        #expect(draft.segments[0].start == 1)
        let restore = try #require(draft.trimProposal(index: 0, edge: .start, dragSeconds: -99))
        #expect(restore.in == 0)
        let restored = draft.apply(restore)
        #expect(restored)
        #expect(draft.segments == raw.segments)
        #expect(draft.actions.map(\.op) == ["trim", "extend", "extend"])
        let undoExtend = draft.undoLast()
        #expect(undoExtend && draft.segments[0].start == 1)
        let undoTrim = draft.undoLast()
        #expect(undoTrim && draft.segments[0].start == 3)
    }

    @Test func trimGesturePreviewIsReversibleInOneDragWithoutWritingHistory() throws {
        let segment = EditTimelineDraft.Segment(take: 1, kind: "screen", start: 2, end: 7)
        let original = EditTimelineDraft.Segment(take: 1, kind: "screen", start: 0, end: 10)
        let pps = 50.0
        let shrink = EditTimelineDraft.trimPreviewOffset(edge: .start, proposedPixels: 100,
            segment: segment, bounds: original, pixelsPerSecond: pps, fps: 30)
        let returned = EditTimelineDraft.trimPreviewOffset(edge: .start, proposedPixels: 0,
            segment: segment, bounds: original, pixelsPerSecond: pps, fps: 30)
        let extend = EditTimelineDraft.trimPreviewOffset(edge: .start, proposedPixels: -999,
            segment: segment, bounds: original, pixelsPerSecond: pps, fps: 30)
        #expect(shrink == 100)
        #expect(returned == 0)
        #expect(extend == -100)
        #expect(EditTimelineDraft.trimPreviewOffset(edge: .end, proposedPixels: 999,
            segment: segment, bounds: original, pixelsPerSecond: pps, fps: 30) == 150)
        #expect(EditTimelineDraft.trimPreviewOffset(edge: .end, proposedPixels: 0,
            segment: segment, bounds: original, pixelsPerSecond: pps, fps: 30) == 0)
    }

    @Test func splitAndDuplicateNeverExtendAcrossTheirSourceEnvelopes() throws {
        let take = Take(number: 2, kind: .camera, file: "take-02-camera.mov",
                        startedAt: .distantPast, duration: 10)
        var draft = try #require(EditTimelineDraft.fromTake(take, duration: 10))
        let split = draft.apply(.init(op: "split", index: 0, at: 4))
        #expect(split)
        #expect(draft.trimBounds(index: 0)?.end == 4)
        #expect(draft.trimBounds(index: 1)?.start == 4)
        let trimmed = draft.apply(.init(op: "trim", index: 1, in: 5, out: 8))
        let duplicated = draft.apply(.init(op: "duplicate", index: 1))
        let moved = draft.apply(.init(op: "move", index: 2, to: 0))
        #expect(trimmed && duplicated && moved)
        let outward = try #require(draft.trimProposal(index: 0, edge: .start, dragSeconds: -99))
        #expect(outward.in == 4)
        let recovered = draft.apply(outward)
        #expect(recovered)
        #expect(draft.segments[0].start == 4)
        let beforeSplit = draft.apply(.init(op: "extend", index: 0, in: 3, out: 8))
        let pastSource = draft.apply(.init(op: "extend", index: 0, in: 4, out: 11))
        #expect(!beforeSplit && !pastSource)
    }

    @Test func outwardTrimSavesAndRestoresExactActionHistory() throws {
        let take = Take(number: 5, kind: .screen, file: "take-05-screen.mov",
                        startedAt: .distantPast, duration: 9)
        let raw = try #require(EditTimelineDraft.fromTake(take, duration: 9))
        var draft = raw
        let trimmed = draft.apply(.init(op: "trim", index: 0, in: 2, out: 8))
        let extended = draft.apply(.init(op: "extend", index: 0, in: 0, out: 9))
        #expect(trimmed && extended)
        let root = FileManager.default.temporaryDirectory.appending(path: "cutmark-extend-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let video = root.appending(path: take.file)
        try draft.save(video: video, session: root)
        let loaded = try #require(EditTimelineDraft.restore(video: video, session: root, original: raw))
        #expect(loaded.segments == raw.segments)
        #expect(loaded.actions == draft.actions)
    }
}
