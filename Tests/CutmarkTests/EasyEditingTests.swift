import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Cutmark

struct EasyEditingTests {
    private func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "easy-edit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func take() -> Take {
        Take(number: 1, kind: .camera, file: "take-01-camera.mov", startedAt: Date(), duration: 8)
    }
    private func job(_ session: URL, status: JobStatus = .done, time: Date = Date()) -> Job {
        Job(id: "render-1", label: "First cut", outputs: ["_edit/renders/render-1.mp4"], fromChat: false,
            status: status, started: time, ended: time, pid: nil, progress: nil, eta: nil, error: nil,
            stoppedBy: nil, isGenerate: false, folder: session.appending(path: ".jobs"))
    }

    @Test func removalCanBeUndoneRedoneAndSavedWithoutChangingTheSource() throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let video = root.appending(path: take().file)
        try Data("original footage".utf8).write(to: video)
        let original = try #require(EditTimelineDraft.fromTake(take(), duration: 8, fps: 30))
        var draft = original, history = TimelineUndoHistory()
        let outcome1 = history.apply(.init(op: "split", index: 0, at: 3), to: &draft)
        #expect(outcome1)
        let outcome2 = history.apply(.init(op: "remove", index: 0), to: &draft)
        #expect(outcome2)
        #expect(draft.duration == 5)
        let undone = history.undo(&draft)
        #expect(undone && draft.duration == 8)
        let redone = history.redo(&draft)
        #expect(redone && draft.duration == 5)
        try draft.save(video: video, session: root)
        let restored = try #require(EditTimelineDraft.restore(video: video, session: root, original: original))
        #expect(restored.segments == draft.segments && restored.actions == draft.actions)
        #expect(try String(contentsOf: video, encoding: .utf8) == "original footage")
        let outcome3 = history.undo(&draft)
        #expect(outcome3)
        let outcome4 = !history.apply(.init(op: "remove", index: 99), to: &draft)
        #expect(outcome4)
        #expect(!history.redoActions.isEmpty, "A rejected action does not lose redo")
        let outcome5 = history.apply(.init(op: "trim", index: 0, out: 2), to: &draft)
        #expect(outcome5)
        #expect(history.redoActions.isEmpty, "A new edit branches from the undone state")
    }

    @Test func resumeUsesRealFilesAndReplayableDrafts() throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let t = take(), video = root.appending(path: take().file)
        if case .missing = SessionJourney.next(files: SessionJourney.load(session: root, takes: [t]), jobs: []) {} else { Issue.record("Missing footage was called ready") }
        try Data("footage".utf8).write(to: video)
        var files = SessionJourney.load(session: root, takes: [t])
        if case .take(let url, 1) = SessionJourney.next(files: files, jobs: []) { #expect(url == video) } else { Issue.record("No first-cut action") }
        var draft = try #require(EditTimelineDraft.fromTake(t, duration: 8, fps: 30))
        let outcome6 = draft.apply(.init(op: "trim", index: 0, out: 6))
        #expect(outcome6)
        try draft.save(video: video, session: root)
        files = SessionJourney.load(session: root, takes: [t])
        #expect(files.draft == video)
        if case .draft = SessionJourney.next(files: files, jobs: []) {} else { Issue.record("Saved draft did not resume") }
        try Data("broken JSON".utf8).write(to: #require(EditTimelineDraft.file(video: video, session: root)))
        #expect(SessionJourney.load(session: root, takes: [t]).draft == nil)
        #expect(try String(contentsOf: video, encoding: .utf8) == "footage")
    }

    @Test func processingFailuresAndCompletedRendersHaveHonestNextSteps() throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let files = SessionJourney.Files(take: root.appending(path: "take-01-camera.mov"), takeNumber: 1, latestTakeDate: .distantPast)
        if case .processing = SessionJourney.next(files: files, jobs: [job(root, status: .running)]) {} else { Issue.record("Live job hidden") }
        for status in [JobStatus.failed, .lost, .stopped] {
            if case .attention = SessionJourney.next(files: files, jobs: [job(root, status: status)]) {} else { Issue.record("Failure hidden") }
        }
        if case .take = SessionJourney.next(files: files, jobs: [job(root)]) {} else { Issue.record("Missing output called ready") }
        let render = root.appending(path: "_edit/renders/render-1.mp4")
        try FileManager.default.createDirectory(at: render.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("rendered video".utf8).write(to: render)
        if case .result = SessionJourney.next(files: files, jobs: [job(root)]) {} else { Issue.record("Finished render did not get review") }
        var progress = job(root, status: .running); progress.progress = 0.456
        #expect(SessionJourney.jobTitle(progress).contains("46%"))
        progress.progress = .nan
        #expect(!SessionJourney.jobTitle(progress).contains("%"))
    }

    @Test func savingARenderReopensThatSameVersionAndNewerWorkWins() throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let t = take(), video = root.appending(path: take().file)
        try Data("original".utf8).write(to: video)
        var draft = try #require(EditTimelineDraft.fromTake(t, duration: 8, fps: 30))
        let changed = draft.apply(.init(op: "trim", index: 0, out: 6)); #expect(changed)
        try draft.save(video: video, session: root)
        let draftFile = try #require(EditTimelineDraft.file(video: video, session: root))
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-10)], ofItemAtPath: draftFile.path)
        let saved = root.appending(path: "edits/idea-v1.mp4")
        try FileManager.default.createDirectory(at: saved.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("finished".utf8).write(to: saved)
        let recipe: [String: Any] = ["edit": "edits/idea-v1.mp4", "render_id": "render-1"]
        try JSONSerialization.data(withJSONObject: recipe).write(to: saved.deletingPathExtension().appendingPathExtension("recipe.json"))
        #expect(SessionJourney.video(for: job(root)) == saved.resolvingSymlinksInPath())
        var files = SessionJourney.load(session: root, takes: [t])
        #expect(files.draft == nil)
        #expect(files.edit?.standardizedFileURL == saved.standardizedFileURL)
        if case .edit = SessionJourney.next(files: files, jobs: [job(root)]) {} else { Issue.record("Saved render did not become a review/export action") }
        let newer = Take(number: 2, kind: .camera, file: "take-02-camera.mov", startedAt: Date().addingTimeInterval(10), duration: 4)
        try Data("next recording".utf8).write(to: root.appending(path: newer.file))
        files = SessionJourney.load(session: root, takes: [t, newer])
        if case .take(_, 2) = SessionJourney.next(files: files, jobs: []) {} else { Issue.record("An old saved video hid a new recording") }
    }

    @Test func aNewTakeDoesNotResumeAnOldFailure() throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let files = SessionJourney.Files(take: root.appending(path: "new.mov"), takeNumber: 2, latestTakeDate: Date())
        if case .take(_, 2) = SessionJourney.next(files: files, jobs: [job(root, status: .failed, time: .distantPast)]) {} else { Issue.record("Old failure hid the new take") }
    }

    @Test func outputPathsCannotEscapeTheSessionThroughTraversalOrSymlinks() throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let session = root.appending(path: "session"), outside = root.appending(path: "outside.mov")
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        try Data("outside".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: session.appending(path: "linked.mov"), withDestinationURL: outside)
        #expect(SessionJourney.containedVideo("../outside.mov", session: session) == nil)
        #expect(SessionJourney.containedVideo(outside.path, session: session) == nil)
        #expect(SessionJourney.containedVideo("linked.mov", session: session) == nil)
    }

    @Test func exportIsAtomicAndCannotReplaceSessionFiles() throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let session = root.appending(path: "session")
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        let original = session.appending(path: "take.mov"), destination = root.appending(path: "export.mp4")
        try Data("complete movie".utf8).write(to: original)
        try Data("old export".utf8).write(to: destination)
        try VideoExport.copy(original, to: destination, session: session)
        #expect(try Data(contentsOf: destination) == Data(contentsOf: original))
        #expect(throws: VideoExport.Failure.self) { try VideoExport.copy(original, to: original, session: session) }
        #expect(throws: VideoExport.Failure.self) { try VideoExport.copy(root.appending(path: "missing"), to: destination, session: session) }
        #expect(try String(contentsOf: destination, encoding: .utf8) == "complete movie")
        #expect(try String(contentsOf: original, encoding: .utf8) == "complete movie")
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).allSatisfy { !$0.hasPrefix(".cutmark-export-") })
    }

    @Test func soundCheckNeverConfusesSelectionOrStaleSamplesWithHeardSound() {
        let now = Date()
        func message(_ monitoring: Bool, _ sample: Date?, _ signal: Date?, allowed: Bool = true) -> String {
            RecordingSoundCheck.message(permission: allowed, selected: true, monitoring: monitoring, sample: sample, signal: signal, now: now)
        }
        #expect(message(false, now, now).contains("not checked"))
        #expect(message(true, nil, now).contains("not checked"))
        #expect(message(true, now.addingTimeInterval(-5), now).contains("not checked"))
        #expect(message(true, now, nil).contains("No sound"))
        #expect(message(true, now, now.addingTimeInterval(-5)).contains("No sound"))
        #expect(message(true, now, now).contains("Sound detected"))
        #expect(!message(true, now, now, allowed: false).contains("Sound detected"))
    }
}
