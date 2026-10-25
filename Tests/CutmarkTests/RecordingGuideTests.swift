import AppKit
import SwiftUI
import Testing
@testable import Cutmark

@MainActor @Suite(.serialized)
struct RecordingGuideTests {
    private func session() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "recording-guide-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func paragraphsKeepTalkingPointsAndSupportingNotesTogether() {
        let cards = RecordingGuide.cards("\n Why this matters\n- One example\n- ¿Qué cambia?\n \n\nDemo\nShow the result\n\nWrap up\n")
        #expect(cards == [.init(title: "Why this matters", detail: "- One example\n- ¿Qué cambia?"),
                          .init(title: "Demo", detail: "Show the result"), .init(title: "Wrap up", detail: "")])
        #expect(RecordingGuide.cards("\n \n\t").isEmpty)
        #expect(RecordingGuide.cards("First\r\nDetail\r\n\r\nSecond").count == 2)
    }

    @Test func boardCanFinishAndGoBackWithoutLeavingItsBounds() {
        #expect(RecordingGuide.position(-1, count: 3) == 0)
        #expect(RecordingGuide.position(3, count: 3) == 3)
        #expect(RecordingGuide.position(4, count: 3) == 3)
        #expect(RecordingGuide.position(2, count: 0) == 0)
    }

    @Test func notesPersistSeparatelyAndFollowSessionReloads() throws {
        let url = try session()
        defer { try? FileManager.default.removeItem(at: url) }
        try "My spoken script".write(to: url.appending(path: "script.md"), atomically: true, encoding: .utf8)
        let doc = SessionDoc(url: url)
        #expect(!FileManager.default.fileExists(atPath: url.appending(path: RecordingGuide.file).path))
        doc.setRecordingNotes("Opening\nRemember the example\n\nConclusion")
        #expect(doc.recordingNotesError == nil)
        #expect(SessionDoc(url: url).recordingNotes == doc.recordingNotes)
        #expect(try String(contentsOf: url.appending(path: "script.md"), encoding: .utf8) == "My spoken script")
        doc.advanceRecordingCue(1)
        #expect(doc.recordingCue == 1)
        doc.advanceRecordingCue(1)
        #expect(doc.recordingCue == 2) // Finished: every point is in Done.
        doc.advanceRecordingCue(1)
        #expect(doc.recordingCue == 2)
        doc.advanceRecordingCue(-1)
        #expect(doc.recordingCue == 1)
        try "New direction".write(to: url.appending(path: RecordingGuide.file), atomically: true, encoding: .utf8)
        doc.reloadRecordingNotes()
        #expect(doc.recordingNotes == "New direction")
        #expect(doc.recordingCue == 0)
        try FileManager.default.removeItem(at: url.appending(path: RecordingGuide.file))
        doc.reloadRecordingNotes()
        #expect(doc.recordingNotes.isEmpty)
    }

    @Test func unreadableNotesAreNotOverwritten() throws {
        let url = try session()
        defer { try? FileManager.default.removeItem(at: url) }
        let file = url.appending(path: RecordingGuide.file)
        let bytes = Data([0xff, 0xfe, 0xff])
        try bytes.write(to: file)
        let doc = SessionDoc(url: url)
        #expect(doc.recordingNotesError != nil)
        doc.setRecordingNotes("Replacement")
        #expect(doc.recordingNotesError != nil)
        #expect(try Data(contentsOf: file) == bytes)
    }

    @Test func guidanceDoesNotListenOrScrollTheScript() {
        let app = AppModel()
        let previous = app.guideMode
        defer { app.guideMode = previous }
        app.guideMode = .board
        #expect(!app.usesTeleprompter && !app.following && !app.scrolling)
        app.guideMode = .notes
        #expect(!app.usesTeleprompter && !app.following && !app.scrolling)
        app.guideMode = .teleprompter
        #expect(app.usesTeleprompter)
    }

    private func until(_ ok: () -> Bool) async {
        let end = Date().addingTimeInterval(5)
        while !ok() && Date() < end { try? await Task.sleep(for: .milliseconds(20)) }
    }

    @Test func typingTheFirstPointKeepsTheEditorOpen() async throws {
        let url = try session()
        defer { try? FileManager.default.removeItem(at: url) }
        let doc = SessionDoc(url: url)
        let app = AppModel()
        let previous = app.guideMode
        defer { app.guideMode = previous }
        app.guideMode = .notes
        let host = NSHostingView(rootView: RecordingGuidePane(doc: doc).environment(app))
        let window = NSWindow(contentRect: NSRect(x: -3000, y: -3000, width: 430, height: 660),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        func editor(in view: NSView) -> NSTextView? {
            if let text = view as? NSTextView { return text }
            return view.subviews.compactMap { editor(in: $0) }.first
        }
        await until { editor(in: host) != nil }
        let text = try #require(editor(in: host))
        text.insertText("O", replacementRange: NSRange(location: 0, length: 0))
        await until { doc.recordingNotes == "O" }
        #expect(doc.recordingNotes == "O")
        let continued = try #require(editor(in: host))
        continued.insertText("pening\n\nDemo", replacementRange: NSRange(location: 1, length: 0))
        await until { doc.recordingNotes == "Opening\n\nDemo" }
        #expect(doc.recordingNotes == "Opening\n\nDemo")
        #expect(SessionDoc(url: url).recordingNotes == doc.recordingNotes)
        // Simulate recording state without opening a camera or capturing the user's screen.
        app.phase = .recording(Date())
        await until { editor(in: host) == nil }
        #expect(editor(in: host) == nil)
        #expect(doc.recordingNotes == "Opening\n\nDemo")
        app.phase = .idle
        window.orderOut(nil)
    }

    private func snapshot(_ view: some View, name: String, width: Double, height: Double, directory: String) throws {
        let host = NSHostingView(rootView: view)
        host.appearance = NSAppearance(named: .darkAqua)
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        let window = NSWindow(contentRect: NSRect(x: -3000, y: -3000, width: width, height: height),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let data = try #require(rep.representation(using: .png, properties: [:]))
        try data.write(to: URL(fileURLWithPath: directory).appending(path: "\(name).png"))
        window.orderOut(nil)
    }

    @Test func renderRecordingGuide() throws {
        guard let directory = ProcessInfo.processInfo.environment["CUTMARK_SNAPSHOT"] else { return }
        let cards = RecordingGuide.cards("The problem\nWhy reading a script can feel rigid\n\nShow the workflow\nOpen the board. Move to the next point.\n\nWrap up\nInvite the viewer to try it")
        for (name, width, height, compact, index) in [
            ("board-wide", 820.0, 560.0, false, 1), ("board-narrow", 380.0, 620.0, false, 1),
            ("board-near-camera", 540.0, 266.0, true, 1), ("board-finished", 540.0, 266.0, true, 3)
        ] {
            let view = RecordingGuideBoard(cards: cards, index: .constant(index), compact: compact)
                .frame(width: width, height: height).background(Theme.paper).environment(\.colorScheme, .dark)
            try snapshot(view, name: name, width: width, height: height, directory: directory)
        }
        let root = try session()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appending(path: "Project/2026-10-24-guide")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let app = AppModel()
        let previous = app.guideMode
        defer { app.guideMode = previous }
        app.library.setRoot(root)
        app.library.select(folder)
        let doc = try #require(app.library.current)
        doc.setRecordingNotes("Opening\nWhy this matters\n\nDemo\nShow the workflow\n\nWrap up\nOne next step")
        app.guideMode = .board
        doc.recordingCue = 1
        try snapshot(ScriptPane(doc: doc).environment(app).environment(\.colorScheme, .dark),
                     name: "record-board", width: 430, height: 660, directory: directory)
        let layout = NotchLayout.make(screen: CGRect(x: 0, y: 0, width: 1512, height: 982),
                                      visibleTop: 950, notch: CGSize(width: 185, height: 32), body: 300)
        try snapshot(NotchView(layout: layout, close: {}).environment(app), name: "guide-notch",
                     width: 596, height: 360, directory: directory)
        app.guideMode = .notes
        try snapshot(ScriptPane(doc: doc).environment(app).environment(\.colorScheme, .dark),
                     name: "record-notes", width: 430, height: 660, directory: directory)
        doc.setRecordingNotes("")
        try snapshot(ScriptPane(doc: doc).environment(app).environment(\.colorScheme, .dark),
                     name: "record-notes-empty", width: 430, height: 660, directory: directory)
    }
}
