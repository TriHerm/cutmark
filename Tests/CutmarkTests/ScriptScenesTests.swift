import AppKit
import SwiftUI
import Testing
@testable import Cutmark

@MainActor @Suite(.serialized)
struct ScriptScenesTests {
    private func board() -> Storyboard {
        var opening = StoryShot(id: "opening", section: .hook, kind: "DESK", say: "Why does recording feel difficult?")
        opening.how = "Look at the camera. Give one familiar example."
        opening.error = StoryShot.noSketchKeyMessage
        var demo = StoryShot(id: "demo", kind: "SCREEN", say: "Start with one idea. Then show the next step.")
        demo.how = "Show the scene beside its script, then open Record."
        demo.error = StoryShot.noSketchKeyMessage
        var ending = StoryShot(id: "ending", section: .end, kind: "END", say: "Record the first take while the idea is fresh.")
        ending.how = "Return to the camera and finish with one next step."
        ending.error = StoryShot.noSketchKeyMessage
        return Storyboard(shots: [opening, demo, ending], format: "16:9", nokey: true)
    }

    @Test func sceneNavigationMatchesSourceWhitespaceAndUnicode() throws {
        let b = Storyboard(shots: [StoryShot(id: "one", say: "¿Qué cambia?"), StoryShot(id: "two", say: "Show one idea.")])
        let script = "🎬 Introduction\n\n¿Qué   cambia?\n\n[DESK. To camera.]\n\nShow\none idea."
        let ranges = SceneScript.ranges(b, in: script)
        #expect((script as NSString).substring(with: try #require(ranges["one"])) == "¿Qué   cambia?")
        #expect((script as NSString).substring(with: try #require(ranges["two"])) == "Show\none idea.")
    }

    @Test func repeatedLinesKeepTheCorrectSceneAndMissingLinesDoNotGuess() throws {
        let b = Storyboard(shots: [StoryShot(id: "one", say: "Try again."), StoryShot(id: "two", say: "Try again."),
                                   StoryShot(id: "missing", say: "Something different"), StoryShot(id: "visual", say: "")])
        let ranges = SceneScript.ranges(b, in: "Try again.\n\nA new example.\n\nTry again.")
        #expect(try #require(ranges["two"]).location > #require(ranges["one"]).location)
        #expect(ranges["missing"] == nil && ranges["visual"] == nil)
        #expect(SceneScript.ranges(b, in: "An alternative script").isEmpty)
        #expect(SceneScript.ranges(Storyboard(shots: [StoryShot(id: "word", say: "record")]), in: "A prerecorded take").isEmpty)
    }

    @Test func onlyMissingKeyPlaceholdersAreNeutral() {
        var shot = StoryShot()
        shot.error = StoryShot.noSketchKeyMessage
        #expect(shot.sketchNeedsSetup)
        shot.error = "Generation failed: quota exceeded"
        #expect(!shot.sketchNeedsSetup)
        shot.error = StoryShot.noSketchKeyMessage
        shot.image = "saved.png"
        #expect(!shot.sketchNeedsSetup)
    }

    @Test func explicitScrollModesKeepExistingPreferencesAndStartBehavior() {
        let app = AppModel()
        let oldVoice = app.followVoice, oldGuide = app.guideMode, oldStart = app.autoScroll, oldSpeed = app.speed
        defer { app.followVoice = oldVoice; app.guideMode = oldGuide }
        app.guideMode = .teleprompter
        app.followVoice = true
        #expect(app.prompterScrollMode == .voice)
        app.prompterScrollMode = .automatic
        #expect(!app.followVoice && !app.following)
        #expect(!UserDefaults.standard.bool(forKey: "prompterFollowVoice"))
        app.prompterScrollMode = .voice
        #expect(app.followVoice)
        #expect(app.autoScroll == oldStart && app.speed == oldSpeed && !app.scrolling)
    }

    private func until(_ ok: () -> Bool) async {
        let end = Date().addingTimeInterval(5)
        while !ok() && Date() < end { try? await Task.sleep(for: .milliseconds(20)) }
    }

    private func textView(_ view: NSView) -> NSTextView? {
        (view as? NSTextView) ?? view.subviews.compactMap { textView($0) }.first
    }

    @Test func jumpingToARepeatedSceneKeepsTheCompleteEditableScript() async throws {
        let script = "Opening.\n\nTry again.\n\nA new example.\n\nTry again.\n\nThe end."
        let b = Storyboard(shots: [StoryShot(id: "one", say: "Try again."), StoryShot(id: "two", say: "Try again.")])
        let range = try #require(SceneScript.ranges(b, in: script)["two"])
        let host = NSHostingView(rootView: Prompter(text: .constant(script), contentKey: "scene-jump", fontSize: 20,
                                                   scrolling: false, speed: 40, editable: true, resetToken: 0,
                                                   revealRange: (range, 1)).frame(width: 440, height: 300))
        let window = NSWindow(contentRect: NSRect(x: -3000, y: -3000, width: 440, height: 300), styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        await until { self.textView(host)?.selectedRange() == range }
        let editor = try #require(textView(host))
        #expect(editor.selectedRange() == range)
        #expect(editor.string == script && editor.isEditable)
        window.orderOut(nil)
    }

    @Test func sceneJumpSurvivesVersionSwitchWithoutChangingEitherScript() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "scene-versions-\(UUID().uuidString)")
        let folder = root.appending(path: "Demo/2026-10-25-version-jump")
        try FileManager.default.createDirectory(at: Storyboard.folder(folder), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let script = "Start here.\n\n" + String(repeating: "Give some useful context.\n", count: 12) + "\nTry again.\n\n" + String(repeating: "Continue with the example.\n", count: 12)
        try script.write(to: folder.appending(path: "script.md"), atomically: true, encoding: .utf8)
        let bytes = Data(#"{"nokey":true,"shots":[{"id":"one","say":"Start here."},{"id":"two","say":"Try again."}]}"#.utf8)
        try bytes.write(to: Storyboard.file(folder))
        let app = AppModel()
        app.library.setRoot(root); app.library.select(folder)
        let doc = try #require(app.library.current)
        let alternative = "A different introduction.\n\n" + script
        doc.newVariant(name: "Different intro", text: alternative)
        let version = doc.activeDraft
        doc.activeDraft = "main"; doc.focusedSceneID = "two"
        let board = try #require(Storyboard.read(folder))
        let host = NSHostingView(rootView: ScriptPage(doc: doc).environment(app).frame(width: 430, height: 680))
        let window = NSWindow(contentRect: NSRect(x: -3000, y: -3000, width: 430, height: 680), styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host; host.layoutSubtreeIfNeeded()
        let first = try #require(SceneScript.ranges(board, in: script)["two"])
        await until { self.textView(host)?.selectedRange() == first }
        #expect(textView(host)?.selectedRange() == first)
        #expect((textView(host)?.enclosingScrollView?.documentVisibleRect.minY ?? 0) > 0)
        doc.activeDraft = version
        let next = try #require(SceneScript.ranges(board, in: alternative)["two"])
        await until { self.textView(host)?.string == alternative && self.textView(host)?.selectedRange() == next }
        #expect(textView(host)?.string == alternative)
        #expect(textView(host)?.selectedRange() == next)
        #expect(try String(contentsOf: folder.appending(path: "script.md"), encoding: .utf8) == script)
        #expect(try Data(contentsOf: Storyboard.file(folder)) == bytes)
        window.orderOut(nil)
    }

    private func snapshot(_ name: String, _ view: some View, width: Double, height: Double, directory: String) async throws {
        let host = NSHostingView(rootView: view.frame(width: width, height: height).background(Theme.paper).environment(\.colorScheme, .dark))
        host.appearance = NSAppearance(named: .darkAqua)
        let window = NSWindow(contentRect: NSRect(x: -3000, y: -3000, width: width, height: height), styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        // Rendering needs one main-actor turn for SwiftUI's onAppear scene load.
        await Task.yield()
        host.layoutSubtreeIfNeeded()
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let data = try #require(rep.representation(using: .png, properties: [:]))
        try data.write(to: URL(fileURLWithPath: directory).appending(path: "\(name).png"))
        window.orderOut(nil)
    }

    @Test func renderSceneAndScriptFlow() async throws {
        guard let directory = ProcessInfo.processInfo.environment["CUTMARK_SNAPSHOT"] else { return }
        let root = FileManager.default.temporaryDirectory.appending(path: "scene-flow-\(UUID().uuidString)")
        let folder = root.appending(path: "Demo/2026-10-25-idea-to-recording")
        try FileManager.default.createDirectory(at: Storyboard.folder(folder), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let b = board()
        let script = b.shots.map(\.say).joined(separator: "\n\n")
        try script.write(to: folder.appending(path: "script.md"), atomically: true, encoding: .utf8)
        let raw: [String: Any] = ["nokey": true, "format": "16:9", "shots": b.shots.map { ["id": $0.id, "section": $0.section.rawValue, "kind": $0.kind, "say": $0.say, "do": $0.how] }]
        let bytes = try JSONSerialization.data(withJSONObject: raw)
        try bytes.write(to: Storyboard.file(folder))
        let app = AppModel()
        let oldGuide = app.guideMode, oldVoice = app.followVoice
        let intro = UserDefaults.standard.object(forKey: NotchView.introKey)
        defer {
            app.guideMode = oldGuide; app.followVoice = oldVoice
            if let intro { UserDefaults.standard.set(intro, forKey: NotchView.introKey) }
            else { UserDefaults.standard.removeObject(forKey: NotchView.introKey) }
        }
        app.library.setRoot(root); app.library.select(folder)
        let doc = try #require(app.library.current)
        doc.newVariant(name: "Shorter opening", text: script)
        doc.newVariant(name: "Story first", text: script)
        doc.activeDraft = "main"
        doc.focusedSceneID = "demo"
        try await snapshot("script-scenes-wide", ScriptPage(doc: doc).environment(app), width: 900, height: 780, directory: directory)
        try await snapshot("script-scenes-narrow", ScriptPage(doc: doc).environment(app), width: 430, height: 780, directory: directory)
        try await snapshot("storyboard-text-ready", StoryboardPane(doc: doc, board: b, images: [:]).environment(app), width: 880, height: 780, directory: directory)
        app.guideMode = .teleprompter
        for mode in PrompterScrollMode.allCases {
            app.prompterScrollMode = mode
            try await snapshot("prompter-\(mode.rawValue)", ScriptPane(doc: doc).environment(app), width: 430, height: 680, directory: directory)
            UserDefaults.standard.set(NotchView.intro.count, forKey: NotchView.introKey)
            let layout = NotchLayout.make(screen: CGRect(x: 0, y: 0, width: 1512, height: 982), visibleTop: 950,
                                          notch: CGSize(width: 185, height: 32), body: 190)
            try await snapshot("notch-mode-\(mode.rawValue)", NotchView(layout: layout, close: {}).environment(app), width: 596, height: 250, directory: directory)
        }
        #expect(try String(contentsOf: folder.appending(path: "script.md"), encoding: .utf8) == script)
        #expect(try Data(contentsOf: Storyboard.file(folder)) == bytes)
        #expect(doc.variants.count == 2)
    }
}
