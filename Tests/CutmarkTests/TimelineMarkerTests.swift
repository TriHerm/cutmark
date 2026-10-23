import AppKit
import AVFoundation
import Foundation
import SwiftUI
import Testing
@testable import Cutmark

struct TimelineMarkerTests {
    private func screen(_ take: Int = 4, _ start: Double = 1, _ end: Double = 3,
                        fps: Double = 60) -> EditTimelineDraft.Segment {
        .init(take: take, kind: "screen", start: start, end: end, sourceFPS: fps)
    }

    @Test func trimReorderAndDuplicateProjectEachScreenOccurrenceOnOutputClock() {
        let screen = screen()
        let camera = EditTimelineDraft.Segment(take: 4, kind: "camera", start: 0, end: 1, sourceFPS: 30)
        let draft = EditTimelineDraft(base: "edits/demo-v1.mp4", fps: 60,
                                      source: [screen, camera],
                                      segments: [camera, screen, screen])
        let events = [
            CaptureEvent(t: 0.99, type: .marker, label: "Trimmed"),
            CaptureEvent(t: 1, type: .marker, label: "Beginning"),
            CaptureEvent(t: 1.5, type: .marker, label: "Important"),
            CaptureEvent(t: 3, type: .marker, label: "End boundary"),
            CaptureEvent(t: 2, type: .down, label: "Click"),
        ]
        let pins = TimelineMarkers.project(draft: draft, eventsByTake: [4: events])
        #expect(pins.count == 4)
        #expect(pins.map(\.label) == ["Beginning", "Important", "Beginning", "Important"])
        #expect(pins.map(\.index) == [1, 1, 2, 2])
        #expect(Set(pins.map(\.id)).count == pins.count)
        #expect(abs(pins[0].outputTime - 1) < 0.00001)
        #expect(abs(pins[1].outputTime - 1.5) < 0.00001)
        #expect(abs(pins[2].outputTime - 3) < 0.00001)
        #expect(abs(pins[3].outputTime - 3.5) < 0.00001)
        // The center-screen marker selects the same occurrence as timeline scrubbing.
        #expect(TimelineCanvasLayout.clipIndex(at: pins[1].outputTime,
                    durations: draft.segments.map(\.duration)) == pins[1].index)
    }

    @Test func mixedFPSUsesFrameRoundedPreviewSpansRatherThanRawCutDurations() {
        let mixed = screen(9, 0.007, 1.014, fps: 60)
        let camera = EditTimelineDraft.Segment(take: 5, kind: "camera",
                                              start: 0.011, end: 1.019, sourceFPS: 30)
        let draft = EditTimelineDraft(base: "edits/demo-v2.mp4", fps: 30,
                                      source: [camera, mixed],
                                      segments: [camera, mixed])
        let events = [CaptureEvent(t: 0, type: .marker, label: "Before source trim"),
                      CaptureEvent(t: 0.5, type: .marker, label: "Center"),
                      CaptureEvent(t: 1.014, type: .marker, label: "Boundary")]
        let pins = TimelineMarkers.project(draft: draft, eventsByTake: [9: events])
        #expect(pins.count == 2)
        #expect(abs(pins[0].outputTime - 31.0 / 30.0) < 0.00001)
        #expect(abs(pins[1].outputTime - (31.0 / 30.0 + 0.5)) < 0.00001)
        #expect(draft.segments[1].renderSourceStart == 0)
        #expect(pins.allSatisfy { $0.outputTime < draft.duration })
    }

    @Test func cameraOnlyAndMissingOrCorruptEventsNeverMakePins() throws {
        let camera = EditTimelineDraft.Segment(take: 7, kind: "camera", start: 0, end: 2)
        let onlyCamera = EditTimelineDraft(base: "edits/camera-v1.mp4", fps: 30,
                                           source: [camera], segments: [camera])
        #expect(TimelineMarkers.project(draft: onlyCamera, eventsByTake: [
            7: [.init(t: 1, type: .marker, label: "Screen-only")]]).isEmpty)
        let root = FileManager.default.temporaryDirectory.appending(path: "cutmark-markers-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let renamed = root.appending(path: "take-07-demo-title-screen.mov")
        #expect(CaptureEventLog.markers(in: root, screenFile: renamed, through: 2).isEmpty)
        let file = CaptureEventLog.url(in: root, take: 7)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not a header\n".utf8).write(to: file)
        #expect(CaptureEventLog.markers(in: root, screenFile: renamed, through: 2).isEmpty)
        try FileManager.default.removeItem(at: file)
        let writer = try CaptureEventLog.Writer(url: file,
            header: .init(take: 7, display: .init(id: 1, x: 0, y: 0, width: 800, height: 600)))
        #expect(writer.append(.init(t: 1, type: .marker, label: "Kept"), durable: true))
        #expect(writer.append(.init(t: 3, type: .marker, label: "Too late"), durable: true))
        writer.close()
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"t\":1.5,\"type\":\"marker\"".utf8))
        try handle.close()
        #expect(CaptureEventLog.markers(in: root, screenFile: renamed, through: 2).map(\.label) == ["Kept"])
    }

    @MainActor @Test func markerCacheUsesActualRenamedMovieAndInvalidatesChangedLog() async throws {
        guard let ffmpeg = Setup.tool("ffmpeg") else { return }
        let root = FileManager.default.temporaryDirectory.appending(path: "cutmark-marker-media-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let movieName = "take-07-welcome-screen.mov"
        let source = root.appending(path: movieName)
        let ff = Process()
        ff.executableURL = URL(filePath: ffmpeg)
        ff.arguments = ["-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i",
                        "color=c=black:s=64x64:r=30:d=2", "-c:v", "mpeg4", "-y", source.path]
        ff.standardOutput = FileHandle.nullDevice
        ff.standardError = FileHandle.nullDevice
        try ff.run()
        ff.waitUntilExit()
        #expect(ff.terminationStatus == 0)

        let take = Take(number: 7, kind: .screen, file: movieName, startedAt: .distantPast, duration: 2)
        let meta = SessionMeta(title: "Marker navigation", createdAt: .distantPast, takes: [take])
        try Store.encoder.encode(meta).write(to: root.appending(path: "session.json"))
        let file = CaptureEventLog.url(in: root, take: 7)
        let writer = try CaptureEventLog.Writer(url: file,
            header: .init(take: 7, display: .init(id: 1, x: 0, y: 0, width: 64, height: 64)))
        #expect(writer.append(.init(t: 0.5, type: .marker, label: "Intro"), durable: true))
        writer.close()

        let segment = screen(7, 0, 2, fps: 30)
        let draft = EditTimelineDraft(base: "takes/" + movieName, fps: 30,
                                      source: [segment], segments: [segment])
        let cache = TimelineMarkerCache()
        await cache.load(draft: draft, session: root)
        #expect(cache.pins.count == 1)
        #expect(cache.pins.first?.label == "Intro")
        #expect(cache.pins.first?.outputTime == 0.5)

        let changed = try CaptureEventLog.Writer(url: file,
            header: .init(take: 7, display: .init(id: 1, x: 0, y: 0, width: 64, height: 64)))
        #expect(changed.append(.init(t: 1.5, type: .marker, label: "Recap"), durable: true))
        changed.close()
        await cache.load(draft: draft, session: root)
        #expect(cache.pins.map(\.label) == ["Intro", "Recap"])

        let trimmed = EditTimelineDraft(base: draft.base, fps: 30, source: draft.source,
                                        segments: [screen(7, 1, 2, fps: 30)])
        await cache.load(draft: trimmed, session: root)
        #expect(cache.pins.map(\.label) == ["Recap"])
        cache.clear()
        #expect(cache.pins.isEmpty)

        let outside = FileManager.default.temporaryDirectory.appending(path: "cutmark-marker-outside-\(UUID())")
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.moveItem(at: CaptureEventLog.directory(in: root), to: outside)
        try FileManager.default.createSymbolicLink(at: CaptureEventLog.directory(in: root),
                                                   withDestinationURL: outside)
        await cache.load(draft: draft, session: root)
        #expect(cache.pins.isEmpty)
    }

    @Test func oversizedLogLineIsSkippedAndReaderAndRulerAreBounded() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "cutmark-marker-limits-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = CaptureEventLog.url(in: root, take: 3)
        let writer = try CaptureEventLog.Writer(url: file,
            header: .init(take: 3, display: .init(id: 1, x: 0, y: 0, width: 100, height: 100)))
        #expect(writer.append(.init(t: 0.2, type: .marker, label: "First")))
        writer.close()
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(repeating: 0x58, count: 2 * 1024 * 1024))
        try handle.write(contentsOf: Data("\n".utf8))
        let encoder = JSONEncoder()
        for i in 0..<720 {
            let event = CaptureEvent(t: 1 + Double(i) / 1000, type: .marker,
                                     label: "Marker \(i)")
            try handle.write(contentsOf: encoder.encode(event))
            try handle.write(contentsOf: Data("\n".utf8))
        }
        try handle.close()
        let screenFile = root.appending(path: "take-03-screen.mov")
        let accepted = CaptureEventLog.markers(in: root, screenFile: screenFile, through: 3)
        #expect(accepted.count == 600)
        #expect(accepted.first?.label == "First")
        #expect(accepted.last?.label == "Marker 598")
        #expect(CaptureEventLog.markers(in: root, screenFile: screenFile, through: 3,
                                        shouldCancel: { true }).isEmpty)
        let segment = screen(3, 0, 3, fps: 30)
        let draft = EditTimelineDraft(base: "takes/take-03-screen.mov", fps: 30,
                                      source: [segment], segments: [segment])
        let pins = TimelineMarkers.project(draft: draft, eventsByTake: [3: accepted])
        #expect(pins.count == 320)
        #expect(pins.first?.label == "First")
        #expect(pins.last?.label == "Marker 598")
    }
}

private let markerScreenshotDir = ProcessInfo.processInfo.environment["CUTMARK_MARKER_SHOTS"]

@MainActor @Suite(.serialized)
struct TimelineMarkerShots {
    @Test(.enabled(if: markerScreenshotDir != nil))
    func rulerWithMarkersInLightAndDarkAtFitAndZoom() throws {
        _ = NSApplication.shared
        let dir = try #require(markerScreenshotDir)
        let url = URL(filePath: dir, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let pins: [TimelineMarkerPin] = [
            .init(index: 0, take: 4, ordinal: 0, sourceTime: 1.2, outputTime: 1.2, label: "Introduction"),
            .init(index: 1, take: 4, ordinal: 1, sourceTime: 2.5, outputTime: 3.75, label: "Chapter"),
            .init(index: 2, take: 4, ordinal: 1, sourceTime: 2.5, outputTime: 7.25, label: "Chapter"),
        ]
        for dark in [true, false] {
            for scale in [60.0, 100.0] {
                let size = CGSize(width: 900, height: 150)
                let view = VStack(alignment: .leading, spacing: 0) {
                    TimelineMarkerRuler(pins: pins, pixelsPerSecond: scale, duration: 9,
                                        onSeek: { _ in }, onScrub: { _ in })
                    Rectangle().fill(Theme.paper).overlay(alignment: .topLeading) {
                        Text("Screen · Camera · Screen").font(Theme.sans(12))
                            .foregroundStyle(Theme.muted).padding(12)
                    }
                }
                .frame(width: size.width, height: size.height)
                let host = NSHostingView(rootView: view)
                host.frame = NSRect(origin: .zero, size: size)
                let window = NSWindow(contentRect: NSRect(origin: CGPoint(x: -6000, y: -6000), size: size),
                                      styleMask: [.borderless], backing: .buffered, defer: false)
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                window.contentView = host
                window.orderFrontRegardless()
                host.layoutSubtreeIfNeeded()
                let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: rep)
                window.orderOut(nil)
                let name = "timeline-markers-\(dark ? "dark" : "light")-\(Int(scale)).png"
                try #require(rep.representation(using: .png, properties: [:]))
                    .write(to: url.appending(path: name))
            }
        }
    }
}
