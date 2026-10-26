import AppKit
import Observation
import SwiftUI
import Testing
@testable import Cutmark

/// Exercise mounted SwiftUI state: Library replaces the selected SessionDoc directly, without
/// first removing the detail pane. The old session's enabled actions must disappear immediately.
@MainActor @Suite(.serialized)
struct SessionJourneySwitchTests {
    @Observable final class Selection {
        var doc: SessionDoc
        init(_ doc: SessionDoc) { self.doc = doc }
    }

    final class Probe { var renderedSession: URL? }

    private struct Marker: NSViewRepresentable {
        let session: URL
        let probe: Probe
        func makeNSView(context: Context) -> NSView {
            probe.renderedSession = session
            return NSView()
        }
        func updateNSView(_ nsView: NSView, context: Context) { probe.renderedSession = session }
    }

    private struct Parent: View {
        let selection: Selection
        let probe: Probe
        var body: some View {
            VStack(alignment: .leading, spacing: 6) {
                Text(selection.doc.meta.title).font(.system(size: 20, weight: .bold)).padding(.leading, 18)
                SessionJourneyBar(doc: selection.doc)
                Marker(session: selection.doc.url, probe: probe).frame(width: 0, height: 0)
            }
            .foregroundStyle(Theme.ink).background(Theme.paper)
        }
    }

    @Test func switchingSessionsImmediatelyRemovesThePreviousEditingAction() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "journey-switch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = AppModel(); app.library.setRoot(root)
        let first = try #require(app.library.createSession())
        first.meta.title = "Session A"
        let take = Take(number: 1, kind: .camera, file: "take-01-camera.mov",
                        startedAt: Date().addingTimeInterval(-60), duration: 8)
        first.meta.takes = [take]
        try Data("saved original".utf8).write(to: first.fileURL(take))
        var draft = try #require(EditTimelineDraft.fromTake(take, duration: 8, fps: 30))
        let edited = draft.apply(.init(op: "trim", index: 0, out: 6)); #expect(edited)
        try draft.save(video: first.fileURL(take), session: first.url)
        first.save()
        let second = try #require(app.library.createSession())
        second.meta.title = "Session B"; second.save()

        let oldTab = UserDefaults.standard.object(forKey: "rightTab")
        let oldReveal = revealAtOnce, oldTextSize = TextSize.shared.step
        UserDefaults.standard.set(SessionMode.record.rawValue, forKey: "rightTab")
        revealAtOnce = true; TextSize.shared.step = 0
        defer {
            revealAtOnce = oldReveal; TextSize.shared.step = oldTextSize
            if let oldTab { UserDefaults.standard.set(oldTab, forKey: "rightTab") }
            else { UserDefaults.standard.removeObject(forKey: "rightTab") }
        }

        let selection = Selection(first), probe = Probe()
        let (window, host) = mount(selection, probe: probe, app: app)
        let emptySelection = Selection(second), emptyProbe = Probe()
        let (emptyWindow, emptyHost) = mount(emptySelection, probe: emptyProbe, app: app)
        defer {
            window.orderOut(nil); window.contentView = nil
            emptyWindow.orderOut(nil); emptyWindow.contentView = nil
        }
        // This middle/right region contains the primary action, excluding the session title on
        // the left and the fixed Recording setup control at the far right. Empty B has no action
        // both before and after loading; compare like-sized views with the same explicit appearance.
        let emptyAction = try actionPixels(emptyHost)
        let deadline = Date().addingTimeInterval(8)
        var populatedAction = emptyAction
        while Date() < deadline {
            populatedAction = try actionPixels(host)
            if probe.renderedSession == first.url && populatedAction != emptyAction { break }
            try await Task.sleep(for: .milliseconds(30))
        }
        try #require(probe.renderedSession == first.url && populatedAction != emptyAction,
                     "The fixture must first show A's loaded editing action")

        selection.doc = second
        // No await here: synchronously flush the selected parent while B's disk result cannot
        // re-enter the main actor and hide the stale A state. The non-observable marker confirms
        // that SwiftUI has rendered B; it does not trigger another render or expose product state.
        try renderSelectedParent(host, probe: probe, session: second.url)
        let switchedAction = try actionPixels(host)
        #expect(switchedAction == emptyAction, "Session B must not retain session A's enabled editing action")
        #expect(switchedAction != populatedAction)

        // Allow B's own load to finish and verify the action-free presentation stays stable.
        await Task.yield()
        #expect(try actionPixels(host) == actionPixels(emptyHost))
        #expect(try String(contentsOf: first.fileURL(take), encoding: .utf8) == "saved original")
    }

    private func mount(_ selection: Selection, probe: Probe, app: AppModel) -> (NSWindow, NSHostingView<AnyView>) {
        let host = NSHostingView(rootView: AnyView(Parent(selection: selection, probe: probe).environment(app)
            .environment(\.colorScheme, .light).frame(width: 1000, height: 110)))
        host.appearance = NSAppearance(named: .aqua)
        host.frame = NSRect(x: 0, y: 0, width: 1000, height: 110)
        let window = NSWindow(contentRect: NSRect(x: -5000, y: -5000, width: 1000, height: 110),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = host; window.orderFrontRegardless()
        return (window, host)
    }

    private func renderSelectedParent(_ host: NSView, probe: Probe, session: URL) throws {
        let deadline = Date().addingTimeInterval(2)
        repeat {
            host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
            if probe.renderedSession == session { return }
            RunLoop.main.run(until: Date().addingTimeInterval(0.005))
        } while Date() < deadline
        try #require(probe.renderedSession == session, "The mounted parent did not render the selected session")
    }

    private func actionPixels(_ host: NSView) throws -> Data {
        host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
        let region = NSRect(x: host.bounds.width * 0.4, y: 0,
                            width: host.bounds.width * 0.4, height: host.bounds.height)
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: region))
        host.cacheDisplay(in: region, to: bitmap)
        return try #require(bitmap.representation(using: .png, properties: [:]))
    }
}
