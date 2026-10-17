import CoreGraphics
import Foundation
import Testing
@testable import Cutmark

struct CaptureEventsTests {
    private func session() throws -> URL {
        let s = FileManager.default.temporaryDirectory.appending(path: "cutmark-events-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: s, withIntermediateDirectories: true)
        return s
    }

    private func header(take: Int = 7) -> CaptureEventLog.Header {
        .init(take: take, display: .init(id: 1, x: 0, y: 0, width: 1920, height: 1080))
    }

    @Test func appendOnlyLogKeepsHeaderAndCompleteLinesAfterATornTail() throws {
        let s = try session()
        defer { try? FileManager.default.removeItem(at: s) }
        let url = CaptureEventLog.url(in: s, take: 7)
        let writer = try CaptureEventLog.Writer(url: url, header: header())
        #expect(writer.append(.init(t: 0, type: .recordingStarted), durable: true))
        #expect(writer.append(.init(t: 1.25, type: .marker, label: "Check this"), durable: true))
        writer.close()
        let h = try FileHandle(forWritingTo: url)
        try h.seekToEnd()
        try h.write(contentsOf: Data("{\"source\":\"screen\",\"t\":1.5,\"type\":\"key\"}\n".utf8))
        try h.write(contentsOf: Data("{\"t\":2,\"type\":\"move\"".utf8))
        try h.close()

        #expect(CaptureEventLog.header(url) == header())
        let events = CaptureEventLog.read(url)
        #expect(events.count == 2)
        #expect(events.map(\.type) == [.recordingStarted, .marker])
        #expect(events.last?.label == "Check this")
    }

    @Test func eventFileIsHiddenStableAndScreenSpecific() {
        let s = URL(fileURLWithPath: "/tmp/session")
        let url = CaptureEventLog.url(in: s, take: 7)
        #expect(url.deletingLastPathComponent().lastPathComponent == ".capture-events")
        #expect(url.lastPathComponent == "take-07-screen.jsonl")
        #expect(CaptureEventLog.takeNumber(forScreenFile: URL(fileURLWithPath: "/tmp/take-07-screen.mov")) == 7)
        #expect(CaptureEventLog.takeNumber(forScreenFile: URL(fileURLWithPath: "/tmp/take-07-demo-name-screen.mov")) == 7)
        #expect(CaptureEventLog.takeNumber(forScreenFile: URL(fileURLWithPath: "/tmp/take-07-camera.mov")) == nil)
        #expect(CaptureEventLog.takeNumber(forEventFile: url) == 7)
    }

    @Test func removingTheLastSidecarAlsoRemovesItsHiddenDirectory() throws {
        let s = try session()
        defer { try? FileManager.default.removeItem(at: s) }
        let writer = try CaptureEventLog.Writer(url: CaptureEventLog.url(in: s, take: 1), header: header(take: 1))
        writer.close()
        CaptureEventLog.remove(in: s, take: 1)
        #expect(!FileManager.default.fileExists(atPath: CaptureEventLog.directory(in: s).path))
    }

    @Test func existingSidecarWithDifferentHeaderIsNeverReused() throws {
        let s = try session()
        defer { try? FileManager.default.removeItem(at: s) }
        let url = CaptureEventLog.url(in: s, take: 1)
        let writer = try CaptureEventLog.Writer(url: url, header: header(take: 1))
        writer.close()
        let otherDisplay = CaptureEventLog.Header(
            take: 1, display: .init(id: 2, x: 1920, y: 0, width: 1920, height: 1080))
        #expect(throws: RecorderError.self) {
            _ = try CaptureEventLog.Writer(url: url, header: otherDisplay)
        }
    }

    @Test func readerRejectsAHeaderForAnotherTakeOrClock() throws {
        let s = try session()
        defer { try? FileManager.default.removeItem(at: s) }
        let url = CaptureEventLog.url(in: s, take: 3)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let wrong = "{\"clock\":\"wall\",\"coordinates\":\"display_normalized_top_left\",\"display\":{\"height\":1080,\"id\":1,\"width\":1920,\"x\":0,\"y\":0},\"source\":\"screen\",\"take\":4,\"type\":\"header\",\"v\":1}\n{\"source\":\"screen\",\"t\":1,\"type\":\"marker\"}\n"
        try Data(wrong.utf8).write(to: url)
        #expect(CaptureEventLog.read(url).isEmpty)
    }

    @Test func readerBoundsCrashTailToPlayableRecoveredMedia() throws {
        let s = try session()
        defer { try? FileManager.default.removeItem(at: s) }
        let url = CaptureEventLog.url(in: s, take: 2)
        let writer = try CaptureEventLog.Writer(url: url, header: header(take: 2))
        #expect(writer.append(.init(t: 1, type: .down)))
        #expect(writer.append(.init(t: 3, type: .marker)))
        writer.close()
        #expect(CaptureEventLog.read(url, through: 2).map(\.type) == [.down])
    }

    @Test func readerRejectsInvalidNormalizedCoordinates() throws {
        #expect(CaptureEventLog.valid(.init(t: 1, type: .move, x: 0.5, y: 1.0)))
        #expect(!CaptureEventLog.valid(.init(t: 1, type: .move, x: 1.01, y: 0.5)))
        #expect(!CaptureEventLog.valid(.init(t: 1, type: .down, x: 0.5, y: 0.5, button: 7)))
    }

    @Test func writerNeverLetsTheScreenClockRunBackward() throws {
        let s = try session()
        defer { try? FileManager.default.removeItem(at: s) }
        let url = CaptureEventLog.url(in: s, take: 4)
        let writer = try CaptureEventLog.Writer(url: url, header: header(take: 4))
        #expect(writer.append(.init(t: 2, type: .move)))
        #expect(writer.append(.init(t: 1.9, type: .down)))
        writer.close()
        #expect(CaptureEventLog.read(url).map(\.t) == [2, 2])
    }

    @Test func displayCoordinatesAreNormalizedAndOtherDisplaysAreDropped() throws {
        let bounds = CGRect(x: 100, y: -200, width: 1000, height: 500)
        let p = try #require(CaptureEventRecorder.normalized(CGPoint(x: 600, y: 50), in: bounds))
        #expect(abs(p.x - 0.5) < 0.0001)
        #expect(abs(p.y - 0.5) < 0.0001)
        #expect(CaptureEventRecorder.normalized(CGPoint(x: 99, y: 50), in: bounds) == nil)
        #expect(CaptureEventRecorder.normalized(CGPoint(x: 600, y: 301), in: bounds) == nil)
    }

    @Test func eventTimestampBridgesOntoTheMediaHostClock() {
        #expect(abs(CaptureEventRecorder.hostTime(forEventTimestamp: 99.75, uptimeNow: 100, hostNow: 500) - 499.75) < 0.0001)
        // An implausible timestamp is safer at callback time than inventing a large media offset.
        #expect(CaptureEventRecorder.hostTime(forEventTimestamp: 10, uptimeNow: 100, hostNow: 500) == 500)
    }

    @Test func eventsMapThroughTheScreenSourceClock() {
        let source = EditTimeMap.Source(take: 4, kind: .screen)
        let map = EditTimeMap(cuts: [
            .init(source: source, in: 2, out: 5),
            .init(source: source, in: 2.5, out: 3.5),
        ])
        let kept = CaptureEvent(t: 3, type: .down, x: 0.5, y: 0.5)
        let cut = CaptureEvent(t: 1, type: .move, x: 0.1, y: 0.1)
        let mapped = map.outputEvents([kept, cut], take: 4)
        #expect(mapped.count == 2)
        #expect(mapped.map { ($0.outputTime * 10).rounded() / 10 } == [1.0, 3.5])
    }
}
