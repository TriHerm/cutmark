import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Cutmark

/// Optional design evidence uses only a disposable generated movie; never opens the real library.
@MainActor @Suite(.serialized)
struct EasyEditingSnapshotTests {
    @Test func renderEasyEditingFlow() async throws {
        guard let directory = ProcessInfo.processInfo.environment["CUTMARK_EASY_SNAP"] else { return }
        let root = FileManager.default.temporaryDirectory.appending(path: "easy-ui-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = AppModel(); app.library.setRoot(root)
        let doc = try #require(app.library.createSession())
        let movie = doc.url.appending(path: "take-01-screen.mov")
        let ffmpeg = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"].first { FileManager.default.fileExists(atPath: $0) }
        let command = Process(); command.executableURL = URL(filePath: try #require(ffmpeg))
        command.arguments = ["-v", "error", "-f", "lavfi", "-i", "testsrc2=size=640x360:rate=30:duration=6",
                             "-f", "lavfi", "-i", "sine=frequency=440:duration=6", "-c:v", "libx264", "-pix_fmt", "yuv420p",
                             "-c:a", "aac", "-shortest", movie.path]
        command.standardError = FileHandle.nullDevice; command.standardOutput = FileHandle.nullDevice
        try command.run(); command.waitUntilExit(); #expect(command.terminationStatus == 0)
        doc.meta.takes = [Take(number: 1, kind: .screen, file: movie.lastPathComponent,
                               startedAt: Date().addingTimeInterval(-60), duration: 6)]
        doc.meta.title = "One idea, one clear video"; doc.save()
        var draft = try #require(EditTimelineDraft.fromTake(doc.meta.takes[0], duration: 6, fps: Double(ScreenMovieWriter.frameRate), sourceFPS: 30))
        let split = draft.apply(.init(op: "split", index: 0, at: 2)); #expect(split)
        let trim = draft.apply(.init(op: "trim", index: 1, out: 5)); #expect(trim)
        try draft.save(video: movie, session: doc.url)
        revealAtOnce = true; defer { revealAtOnce = false }
        for dark in [false, true] {
            try await shoot(TimelineEditorWorkspace(video: movie, doc: doc).environment(app),
                      name: "editor-\(dark ? "dark" : "light")", width: 1080, height: 720, dark: dark, directory: directory)
        }
        try await shoot(TimelineEditorWorkspace(video: movie, doc: doc).environment(app),
                  name: "editor-compact", width: 780, height: 560, dark: true, directory: directory)
        let home = VStack(spacing: 0) {
            SessionHeader(doc: doc)
            SessionJourneyBar(doc: doc)
            QuickTakePane(doc: doc)
        }.environment(app).background(Theme.paper)
        try await shoot(home, name: "resume", width: 950, height: 600, dark: true, directory: directory)
        try await shoot(RecordingSetupPanel(doc: doc, camera: app.camera, screen: app.screen).environment(app),
                  name: "recording-setup", width: 390, height: 650, dark: true, directory: directory)
        let edits = doc.url.appending(path: "edits")
        try FileManager.default.createDirectory(at: edits, withIntermediateDirectories: true)
        let saved = edits.appending(path: "idea-v1.mp4")
        try FileManager.default.copyItem(at: movie, to: saved)
        try await shoot(TimelineResultReview(job: TimelineResultReview.savedJob(video: saved, session: doc.url)).environment(app),
                  name: "review-and-export", width: 710, height: 520, dark: false, directory: directory)
    }

    private func shoot(_ view: some View, name: String, width: CGFloat, height: CGFloat, dark: Bool, directory: String) async throws {
        let host = NSHostingView(rootView: AnyView(view.frame(width: width, height: height).environment(\.colorScheme, dark ? .dark : .light)))
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        let window = NSWindow(contentRect: NSRect(x: -5000, y: -5000, width: width, height: height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host; window.orderFrontRegardless()
        // Yield the main actor so real SwiftUI .task work can run. Wait for the rendered layout
        // to settle instead of blocking that work inside a synchronous AppKit run loop.
        let deadline = Date().addingTimeInterval(8)
        var previous: Data?, stable = 0, samples = 0
        while Date() < deadline {
            try await Task.sleep(for: .milliseconds(80))
            host.layoutSubtreeIfNeeded()
            if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: rep)
                let data = rep.representation(using: .png, properties: [:])
                stable = data == previous ? stable + 1 : 0; previous = data; samples += 1
                if samples > 10 && stable >= 4 { break }
            }
        }
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        try #require(rep.representation(using: .png, properties: [:]))
            .write(to: URL(filePath: directory).appending(path: name + ".png"))
        window.orderOut(nil); window.contentView = nil
    }
}
