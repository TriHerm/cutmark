import AppKit
import SwiftUI
import Testing
@testable import Cutmark

@MainActor @Suite(.serialized)
struct StudioWorkflowTests {
    @Test func editAndExportCoverCameraAndRetainLegacyDestinations() {
        #expect(SessionMode.tabs == [.write, .record, .edit, .export])
        for route in ["edit", "export"] {
            #expect(DetailView.covers(route, previewing: false))
            #expect(DetailView.covers(route, previewing: true))
        }
        #expect(SessionMode.assets.tab == .edit)
        #expect(SessionMode.sounds.tab == .edit)
        #expect(SessionMode.post.tab == .export)
        #expect(Set(SessionMode.allCases.map(\.shortcut)).count == SessionMode.allCases.count)
    }

    @Test func phrasesFollowTrimReorderAndDuplicateOnOutputClock() {
        let a = EditTimelineDraft.Segment(take: 1, kind: "camera", start: 2, end: 5)
        let b = EditTimelineDraft.Segment(take: 2, kind: "screen", start: 0, end: 2)
        let draft = EditTimelineDraft(base: "takes/test.mov", fps: 30, source: [a, b], segments: [b, a, a])
        let words: [String: [Word]] = [
            "1:camera": [.init(word: "Cut away", start: 1, end: 1.5), .init(word: "Keep.", start: 2.5, end: 3), .init(word: "Outside", start: 5, end: 6)],
            "2:screen": [.init(word: "First.", start: 0.5, end: 1)]
        ]
        let phrases = TimelineTranscript.phrases(draft: draft, words: words)
        #expect(phrases.map(\.text) == ["First.", "Keep.", "Keep."])
        #expect(phrases.map(\.time) == [0.5, 2.5, 5.5])
        #expect(phrases.map(\.section) == [0, 1, 2])
        #expect(Set(phrases.map(\.id)).count == 3)
        #expect(TimelineTranscript.phrases(draft: draft, words: [:]).isEmpty)
    }

    @Test func starterStylesSeedWithoutReplacingExistingStyle() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "studio-styles-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let shipped = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "../../assets/styles").standardizedFileURL
        let suite = "studio-seed-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(StyleLib.seed(from: shipped, root: root, defaults: defaults) == ["Focus", "Paper", "Studio"])
        let guide = StyleLib.style("Studio", root: root).appending(path: "README.md")
        try "My custom style".write(to: guide, atomically: true, encoding: .utf8)
        #expect(StyleLib.seed(from: shipped, root: root, defaults: defaults).isEmpty)
        #expect(try String(contentsOf: guide, encoding: .utf8) == "My custom style")
        for name in ["Focus", "Paper", "Studio"] {
            let folder = StyleLib.style(name, root: root)
            #expect(NSImage(contentsOf: folder.appending(path: "preview.png")) != nil)
            #expect(!StyleLib.json(folder.appending(path: "tokens.json")).isEmpty)
        }
    }

    @Test func titlebarDoubleClickFillsScreenAndRestoresPreviousFrame() async throws {
        let host = NSHostingView(rootView: BoardTitleBar(title: "Styles"))
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 900, height: 500),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        func titlebar(_ view: NSView) -> WindowTitlebarArea.TitlebarView? {
            if let area = view as? WindowTitlebarArea.TitlebarView { return area }
            return view.subviews.compactMap { titlebar($0) }.first
        }
        let area = try #require(titlebar(host))
        let blank = area.convert(NSPoint(x: area.bounds.maxX - 20, y: area.bounds.midY), to: host)
        #expect(host.hitTest(blank) === area, "Empty header space must receive native window gestures")
        let old = window.frame
        let event = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 2, pressure: 1))
        area.mouseDown(with: event)
        let deadline = Date().addingTimeInterval(3)
        while window.frame != window.screen?.visibleFrame && Date() < deadline { try? await Task.sleep(for: .milliseconds(20)) }
        #expect(window.frame == window.screen?.visibleFrame)
        area.mouseDown(with: event)
        let restored = Date().addingTimeInterval(3)
        while window.frame != old && Date() < restored { try? await Task.sleep(for: .milliseconds(20)) }
        #expect(window.frame == old)
        window.orderOut(nil)
    }

    @Test func renderStudioSurfaces() async throws {
        guard let directory = ProcessInfo.processInfo.environment["CUTMARK_SNAPSHOT"] else { return }
        let root = FileManager.default.temporaryDirectory.appending(path: "studio-shots-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let app = AppModel(); app.library.setRoot(root)
        let doc = try #require(app.library.createSession())
        doc.meta.title = "A clearer product demo"
        doc.setRecordingNotes("The problem\nWhy the old workflow slows us down\n\nThe demonstration\nShow one useful example\n\nThe takeaway\nOne thing to try today")
        let shipped = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "../../assets/styles").standardizedFileURL
        let defaults = try #require(UserDefaults(suiteName: "studio-shot-\(UUID())"))
        StyleLib.seed(from: shipped, root: root, defaults: defaults)
        var shots: [(String, AnyView, Double, Double)] = []
        if let fixture = ProcessInfo.processInfo.environment["CUTMARK_STUDIO_FIXTURE"] {
            let video = doc.url.appending(path: "take-01-camera.mov")
            try FileManager.default.copyItem(at: URL(fileURLWithPath: fixture), to: video)
            let take = Take(number: 1, kind: .camera, file: video.lastPathComponent, startedAt: Date(), duration: 8)
            doc.meta.takes = [take]; doc.save()
            try Transcript.write([.init(word: "Start with the useful part.", start: 0.5, end: 2),
                                  .init(word: "Show one clear example.", start: 3, end: 4.5),
                                  .init(word: "Finish with the next step.", start: 6, end: 7.5)], source: "synthetic test", for: video)
            var draft = try #require(EditTimelineDraft.fromTake(take, duration: 8))
            let split = draft.apply(.init(op: "split", index: 0, at: 3))
            #expect(split)
            try draft.save(video: video, session: doc.url)
            shots += [("studio-editor", AnyView(TimelineEditorWorkspace(video: video, doc: doc).environment(app)), 1160, 760),
                      ("studio-editor-narrow", AnyView(TimelineEditorWorkspace(video: video, doc: doc).environment(app)), 800, 620)]
        }
        shots += [
            ("studio-edit", AnyView(SessionStudio(doc: doc, exporting: false).environment(app)), 1040.0, 680.0),
            ("studio-export", AnyView(SessionStudio(doc: doc, exporting: true).environment(app)), 1040.0, 680.0),
            ("studio-styles", AnyView(StylesBoard(root: root).environment(app)), 1040.0, 800.0),
            ("studio-header", AnyView(SessionHeader(doc: doc).environment(app).background(Theme.paper)), 1040.0, 60.0)
        ]
        for (name, view, width, height) in shots {
            let host = NSHostingView(rootView: view.environment(\.colorScheme, .light))
            let window = NSWindow(contentRect: NSRect(x: -5000, y: -5000, width: width, height: height), styleMask: .borderless, backing: .buffered, defer: false)
            window.contentView = host; window.orderFrontRegardless()
            let end = Date().addingTimeInterval(name.hasPrefix("studio-editor") ? 3 : 1)
            while Date() < end { try? await Task.sleep(for: .milliseconds(30)); host.layoutSubtreeIfNeeded() }
            let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            try #require(rep.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: directory).appending(path: name + ".png"))
            window.orderOut(nil)
        }
    }
}
