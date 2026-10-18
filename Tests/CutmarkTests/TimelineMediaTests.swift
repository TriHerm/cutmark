import Foundation
import Testing
@testable import Cutmark

struct TimelineMediaTests {
    @Test func sourceURLFollowsRenamedTakeFromSessionMetadata() throws {
        let session = FileManager.default.temporaryDirectory
            .appending(path: "cutmark-timeline-media-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: session) }
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)

        let renamed = "take-03-hook-camera.mov"
        try Data().write(to: session.appending(path: renamed))
        let meta = SessionMeta(title: "Timeline media", createdAt: Date(timeIntervalSince1970: 0), takes: [
            Take(number: 3, kind: .camera, file: renamed, startedAt: Date(timeIntervalSince1970: 0)),
        ])
        try Store.encoder.encode(meta).write(to: session.appending(path: "session.json"))

        let segment = EditTimelineDraft.Segment(take: 3, kind: "camera", start: 1, end: 2)
        #expect(TimelineMedia.sourceURL(for: segment, session: session)?.lastPathComponent == renamed)
    }

    @Test func sourceURLFallsBackToCanonicalRecoveredTake() throws {
        let session = FileManager.default.temporaryDirectory
            .appending(path: "cutmark-timeline-media-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: session) }
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)

        let canonical = "take-07-screen.mov"
        try Data().write(to: session.appending(path: canonical))
        let segment = EditTimelineDraft.Segment(take: 7, kind: "screen", start: 0, end: 1)

        #expect(TimelineMedia.sourceURL(for: segment, session: session)?.lastPathComponent == canonical)
    }

    @Test func sourceURLDoesNotSubstituteCanonicalWhenMetadataFileIsMissing() throws {
        let session = FileManager.default.temporaryDirectory
            .appending(path: "cutmark-timeline-media-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: session) }
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)

        let canonical = "take-05-camera.mov"
        try Data("stale".utf8).write(to: session.appending(path: canonical))
        let meta = SessionMeta(title: "Timeline media", createdAt: Date(timeIntervalSince1970: 0), takes: [
            Take(number: 5, kind: .camera, file: "take-05-renamed-camera.mov",
                 startedAt: Date(timeIntervalSince1970: 0)),
        ])
        try Store.encoder.encode(meta).write(to: session.appending(path: "session.json"))
        let segment = EditTimelineDraft.Segment(take: 5, kind: "camera", start: 0, end: 1)

        #expect(TimelineMedia.sourceURL(for: segment, session: session) == nil)
    }

    @Test func sourceURLAcceptsDirectoryHintSessionRoot() throws {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "cutmark-timeline-media-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let canonical = "take-04-camera.mov"
        try Data().write(to: folder.appending(path: canonical))
        let session = URL(fileURLWithPath: folder.path, isDirectory: true)
        let segment = EditTimelineDraft.Segment(take: 4, kind: "camera", start: 0, end: 1)

        #expect(TimelineMedia.sourceURL(for: segment, session: session)?.lastPathComponent == canonical)
    }

    @Test func sourceURLRejectsTakeSymlinkOutsideSession() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "cutmark-timeline-media-\(UUID().uuidString)")
        let session = root.appending(path: "session")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)

        let outside = root.appending(path: "outside.mov")
        try Data("outside".utf8).write(to: outside)
        let escaped = session.appending(path: "take-09-screen.mov")
        try FileManager.default.createSymbolicLink(at: escaped, withDestinationURL: outside)
        let segment = EditTimelineDraft.Segment(take: 9, kind: "screen", start: 0, end: 1)

        #expect(TimelineMedia.sourceURL(for: segment, session: session) == nil)
    }
}
