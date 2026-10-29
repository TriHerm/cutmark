import AppKit
import SwiftUI
import Testing
@testable import Cutmark

@MainActor @Suite(.serialized)
struct QuickPlanTests {
    private func fixture() throws -> (URL, AppModel, SessionDoc) {
        let root = FileManager.default.temporaryDirectory.appending(path: "quick-plan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let app = AppModel()
        app.library.setRoot(root)
        let doc = try #require(app.library.createSession())
        return (root, app, doc)
    }

    private func take(_ doc: SessionDoc, number: Int = 1) throws {
        doc.meta.takes = [Take(number: number, kind: .camera, file: "take-01-camera.mov", startedAt: Date(), duration: 8),
                          Take(number: number, kind: .screen, file: "take-01-screen.mov", startedAt: Date(), duration: 8)]
        for t in doc.meta.takes { try Data("saved take".utf8).write(to: doc.fileURL(t)) }
        try Transcript.write([Word(word: "Una", start: 0, end: 0.5), Word(word: "idea.", start: 0.5, end: 1)],
                             source: "fixture", for: doc.fileURL(doc.meta.takes[0]))
        try Transcript.write([Word(word: "Screen audio", start: 0, end: 1)], source: "fixture", for: doc.fileURL(doc.meta.takes[1]))
        doc.save()
    }

    @Test func planHasOneHeaderTabAndLegacyRoutesStillWork() {
        #expect(SessionMode.tabs == [.write, .record, .edit, .export])
        #expect(SessionMode.write.title == "Plan")
        #expect(SessionMode.storyboard.tab == .write)
        #expect(SessionMode(rawValue: "write") == .write && SessionMode(rawValue: "storyboard") == .storyboard)
        #expect(DetailView.covers("write", previewing: false) && DetailView.covers("storyboard", previewing: false))
        let d = UserDefaults.standard
        let oldTab = d.object(forKey: "rightTab"), oldRequest = d.object(forKey: "visualPreviewRequest")
        defer {
            if let oldTab { d.set(oldTab, forKey: "rightTab") } else { d.removeObject(forKey: "rightTab") }
            if let oldRequest { d.set(oldRequest, forKey: "visualPreviewRequest") } else { d.removeObject(forKey: "visualPreviewRequest") }
        }
        let before = d.integer(forKey: "visualPreviewRequest")
        SessionMode.set(.storyboard); SessionMode.set(.storyboard)
        #expect(d.integer(forKey: "visualPreviewRequest") == before + 2, "the shortcut also reopens a dismissed preview")
    }

    @Test func quickTakeNeedsNoProviderAndPreservesThePreviousSession() throws {
        let (root, app, original) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        original.script = "Keep my existing script."; original.flushScript()
        original.activeDraft = original.newVariant(name: "Keep this version", text: "My alternative.")
        app.shot = StoryShot(id: "old", say: "An old scene.")
        let s = Setup.shared, agent = s.agent, signIn = s.signedIn
        defer { s.agent = agent; s.signedIn = signIn }
        s.agent = .missing; s.signedIn = .missing
        let mode = app.guideMode
        let fresh = try #require(app.prepareQuickTake())
        #expect(fresh.url != original.url && fresh.quickTake && fresh.activeText.isEmpty)
        #expect(app.phase == .idle && !app.scrolling && app.shot == nil && app.preview == nil)
        #expect(!app.usesTeleprompter && !app.hasRecordingGuide && app.guideMode == mode)
        #expect(!app.chats.open && !app.chats.onRecord)
        #expect(app.chats.chat(fresh.url).messages.isEmpty)
        #expect(try String(contentsOf: original.url.appending(path: "script.md"), encoding: .utf8) == "Keep my existing script.")
        #expect(SessionDoc(url: original.url).readVariants().first?.text == "My alternative.")
        app.phase = .countdown(3)
        #expect(app.prepareQuickTake() == nil && app.library.current === fresh)
        app.phase = .idle
    }

    @Test func transcriptDraftIsPersistentAndDoesNotOverwriteScriptsScenesOrTakes() throws {
        let (root, app, doc) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        doc.script = "Original script."; doc.flushScript()
        let old = doc.newVariant(name: "Earlier idea", text: "Existing alternative.")
        try take(doc)
        try FileManager.default.createDirectory(at: Storyboard.folder(doc.url), withIntermediateDirectories: true)
        let board = Data(#"{"shots":[{"id":"stable","say":"Original script.","sketch":"To camera."}],"sketches_deferred":true}"#.utf8)
        try board.write(to: Storyboard.file(doc.url))
        let meta = try Data(contentsOf: doc.url.appending(path: "session.json"))
        let files = try doc.meta.takes.map { try Data(contentsOf: doc.fileURL($0)) }
        let slug = try TakePlan.importTranscript(doc, number: 1)
        #expect(slug != old && doc.activeText == "Una idea.", "the camera carries the paired take's voice")
        #expect(doc.script == "Original script." && doc.variants.first(where: { $0.slug == old })?.text == "Existing alternative.")
        #expect(try Data(contentsOf: Storyboard.file(doc.url)) == board)
        #expect(try Data(contentsOf: doc.url.appending(path: "session.json")) == meta)
        #expect(try doc.meta.takes.map { try Data(contentsOf: doc.fileURL($0)) } == files)
        #expect(SessionDoc(url: doc.url).readVariants().first(where: { $0.slug == slug })?.text == "Una idea.")
        #expect(try TakePlan.importTranscript(doc, number: 1) == slug, "an unchanged import is idempotent")
        doc.quickTake = true
        try app.useTakeAsDraft(doc, number: 1)
        #expect(!doc.quickTake && UserDefaults.standard.string(forKey: "rightTab") == SessionMode.write.rawValue)
        let read = try #require(Storyboard.read(doc.url))
        #expect(read.sketchesDeferred == true && read.shots[0].hasOptionalSketchPlaceholder)
    }

    @Test func screenOnlyTranscriptsWorkAndFailedImportsLeaveTheDraftAlone() throws {
        let (root, _, doc) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try take(doc)
        doc.meta.takes.removeAll { $0.kind == .camera }
        #expect(try TakePlan.importTranscript(doc, number: 1) == doc.activeDraft)
        #expect(doc.activeText == "Screen audio")
        let selected = doc.activeDraft, count = doc.variants.count
        #expect(throws: TakePlan.Failure.self) { try TakePlan.importTranscript(doc, number: 99) }
        try Data("broken words".utf8).write(to: Transcript.file(for: doc.fileURL(doc.meta.takes[0])))
        #expect(throws: TakePlan.Failure.self) { try TakePlan.importTranscript(doc, number: 1) }
        #expect(doc.activeDraft == selected && doc.variants.count == count)
    }

    @Test func savingFailureNeverPublishesAnUnsavedPlanningDraft() throws {
        let (root, _, doc) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("file blocks directory".utf8).write(to: doc.variantsDir)
        #expect(throws: (any Error).self) {
            try TakePlan.saveDraft("An idea.", name: "Video plan", author: "user", note: "Draft", doc: doc)
        }
        #expect(doc.activeDraft == "main" && doc.variants.isEmpty)
        #expect(try Data(contentsOf: doc.variantsDir) == Data("file blocks directory".utf8))
    }

    private func renderedCard(_ host: NSView) throws -> Data {
        host.layoutSubtreeIfNeeded()
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        return try #require(rep.representation(using: .png, properties: [:]))
    }

    @Test func anExternalTranscriptRefreshesTheOpenHandoffCard() async throws {
        let (root, app, doc) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try take(doc)
        let file = try #require(TakePlan.voiceFile(doc, number: 1))
        try FileManager.default.removeItem(at: Transcript.file(for: file))
        let host = NSHostingView(rootView: TakePlanCard(doc: doc, number: 1).environment(app).frame(width: 430, height: 260))
        let window = NSWindow(contentRect: NSRect(x: -3000, y: -3000, width: 430, height: 260), styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host; host.layoutSubtreeIfNeeded()
        defer { window.orderOut(nil) }
        var before = try renderedCard(host), stable = 0
        var deadline = Date().addingTimeInterval(3)
        while stable < 3 && Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
            let next = try renderedCard(host)
            stable = next == before ? stable + 1 : 0
            before = next
        }
        #expect(stable == 3)
        try Transcript.write([Word(word: "The prepared transcript.", start: 0, end: 2)], source: "external fixture", for: file)
        NotificationCenter.default.post(name: .cutmarkFilesChanged, object: [Transcript.file(for: file).path])
        deadline = Date().addingTimeInterval(3)
        var after = try renderedCard(host)
        while after == before && Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
            after = try renderedCard(host)
        }
        #expect(after != before, "the mounted card must show the transcript handoff without reopening")
        if let directory = ProcessInfo.processInfo.environment["CUTMARK_SNAPSHOT"] {
            try before.write(to: URL(fileURLWithPath: directory).appending(path: "transcript-before-external-write.png"))
            try after.write(to: URL(fileURLWithPath: directory).appending(path: "transcript-after-external-write.png"))
        }
    }

    @Test func recordSceneLeavesQuickTakeAndUsesTheSelectedScene() throws {
        let (root, app, doc) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        doc.quickTake = true
        app.record(shot: StoryShot(id: "one", say: "Ready to speak."))
        #expect(!doc.quickTake && app.promptText == "Ready to speak." && app.phase == .idle)
        app.endShot()
        #expect(app.shot == nil && UserDefaults.standard.string(forKey: "rightTab") == SessionMode.write.rawValue)
    }

    @Test func theFirstQuickTakeKeepsTheTranscriptHandoffVisible() throws {
        let (root, app, doc) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try take(doc)
        let flow = FirstTake.shared, shown = flow.shown
        let d = UserDefaults.standard, done = d.object(forKey: FirstTake.doneKey)
        defer {
            flow.shown = shown
            if let done { d.set(done, forKey: FirstTake.doneKey) } else { d.removeObject(forKey: FirstTake.doneKey) }
        }
        doc.quickTake = true; flow.shown = false; d.set(false, forKey: FirstTake.doneKey)
        flow.afterTake(doc, number: 1, library: app.library)
        #expect(!flow.shown && d.bool(forKey: FirstTake.doneKey))
        let file = try #require(TakePlan.voiceFile(doc, number: 1))
        #expect(doc.quickTake && Transcript.text(for: file) == "Una idea.")
    }

    private func snapshot(_ name: String, _ view: some View, width: Double, height: Double, directory: String) async throws {
        let reveal = revealAtOnce
        revealAtOnce = true
        defer { revealAtOnce = reveal }
        let host = NSHostingView(rootView: view.frame(width: width, height: height).background(Theme.paper)
            .environment(\.colorScheme, .dark))
        host.appearance = NSAppearance(named: .darkAqua)
        let window = NSWindow(contentRect: NSRect(x: -3000, y: -3000, width: width, height: height), styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host; host.layoutSubtreeIfNeeded()
        await Task.yield(); await Task.yield()
        host.layoutSubtreeIfNeeded()
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        try #require(rep.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: directory).appending(path: "\(name).png"))
        window.orderOut(nil)
    }

    @Test func renderQuickTakeAndUnifiedPlan() async throws {
        guard let directory = ProcessInfo.processInfo.environment["CUTMARK_SNAPSHOT"] else { return }
        let (root, app, doc) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        SessionMode.set(.write)
        doc.quickTake = true
        try await snapshot("quick-take-ready", QuickTakePane(doc: doc).environment(app), width: 430, height: 680, directory: directory)
        try take(doc)
        try await snapshot("take-to-plan", TakePlanCard(doc: doc, number: 1).environment(app), width: 430, height: 260, directory: directory)
        try app.useTakeAsDraft(doc, number: 1)
        try FileManager.default.createDirectory(at: Storyboard.folder(doc.url), withIntermediateDirectories: true)
        try Data(#"{"shots":[{"id":"idea","say":"Una idea.","do":"Look at the camera and share the idea.","sketch":"To camera."}],"sketches_deferred":true}"#.utf8).write(to: Storyboard.file(doc.url))
        for width: Double in [430, 900] {
            try await snapshot("unified-plan-\(Int(width))", ScriptPage(doc: doc).environment(app), width: width, height: 780, directory: directory)
        }
        let board = try #require(Storyboard.read(doc.url))
        try await snapshot("deferred-visual-preview", StoryboardPane(doc: doc, board: board, images: [:]).environment(app), width: 820, height: 600, directory: directory)
        app.chats.docked = true; app.chats.open = true
        try await snapshot("plan-with-assistant", ChatSlot(hub: app.chats, doc: doc) {
            ScriptPage(doc: doc)
        }.environment(app), width: 1250, height: 780, directory: directory)
        try await snapshot("plan-header", SessionHeader(doc: doc).environment(app), width: 900, height: 65, directory: directory)
        let flow = Onboarding.shared, page = flow.page
        let s = Setup.shared, agent = s.agent, signedIn = s.signedIn
        defer { flow.page = page; s.agent = agent; s.signedIn = signedIn }
        flow.page = 2; s.agent = .missing; s.signedIn = .missing
        try await snapshot("first-capture-no-setup", OnboardingCard(flow: flow).environment(app), width: 780, height: 580, directory: directory)
    }
}
