import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Takes

/// The opt-in usage counts.
@MainActor
struct UsageTests {
    @Test func theReportHoldsOnlyCountsAndNoText() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appending(path: "usage-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let a = root.appending(path: "Secret Project/My private video title")
        let b = root.appending(path: "Secret Project/Second video")
        try fm.createDirectory(at: a.appending(path: "edits"), withIntermediateDirectories: true)
        try fm.createDirectory(at: Storyboard.folder(b), withIntermediateDirectories: true)
        for f in ["cut-v1.mp4", "cut-v2.mov", "notes.txt"] { try Data().write(to: a.appending(path: "edits/\(f)")) }
        try Data("{}".utf8).write(to: Storyboard.file(b))

        let r = Usage.report(id: "3F2A1B4C-1111-2222-3333-444455556666", version: "v2026.10.10", os: "26.1",
                             root: root, projects: 1, sessions: [(a, 7, true), (b, 2, false)],
                             plugins: ["voices", "feedback"], phone: true)
        #expect(r.counts == Usage.Counts(projects: 1, sessions: 2, takes: 9, edits: 2, storyboards: 1, published: 1, phone: 1))
        #expect(r.plugins == ["feedback", "voices"])

        let json = String(decoding: try Usage.encode(r), as: UTF8.self)
        for word in ["Secret", "private", "title", "cut-v1", "notes"] { #expect(!json.contains(word)) }
        // The site keeps exactly these fields (gettakes-site functions/ping.js COUNTS).
        let object = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        #expect(Set(object.keys) == ["id", "v", "os", "counts", "plugins"])
        let counts = try #require(object["counts"] as? [String: Int])
        #expect(Set(counts.keys) == ["projects", "sessions", "takes", "edits", "storyboards", "posts_ready",
                                     "posts_scheduled", "posts_posted", "published", "phone"])
    }

    @Test func aPhoneSeenThisWeekCounts() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "phones-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let now = Date()
        #expect(!PhoneServer.usedRecently(file: file, now: now))
        let old = PairedPhone(name: "Phone", hash: "x", paired: now.addingTimeInterval(-30 * 86_400), seen: now.addingTimeInterval(-9 * 86_400))
        try JSONEncoder.iso.encode([old]).write(to: file)
        #expect(!PhoneServer.usedRecently(file: file, now: now))
        var fresh = old
        fresh.seen = now.addingTimeInterval(-2 * 86_400)
        try JSONEncoder.iso.encode([old, fresh]).write(to: file)
        #expect(PhoneServer.usedRecently(file: file, now: now))
    }

    @Test func theNeverPanelNamesTheChats() {
        #expect(UsageCopy.neverTitle.contains("chats"))
        #expect(UsageCopy.neverDetail.contains("chat history"))
    }

    /// The ask card and Settings › Usage, rendered to look at. `TAKES_SNAPSHOT=/some/dir`.
    @Test func snapshots() throws {
        guard let dir = ProcessInfo.processInfo.environment["TAKES_SNAPSHOT"] else { return }
        let app = AppModel()
        let views: [(String, CGSize, AnyView)] = [
            ("usage-ask", CGSize(width: 560, height: 480), AnyView(UsageAskCard(usage: .shared).padding(40))),
            ("usage-ask-details", CGSize(width: 640, height: 860), AnyView(UsageAskCard(usage: .shared, showDetails: true).padding(40))),
            ("usage-settings", CGSize(width: 580, height: 560), AnyView(UsagePage())),
        ]
        for (name, size, view) in views {
            for (mode, dark) in [("dark", true), ("light", false)] {
                let host = NSHostingView(rootView: AnyView(view.frame(width: size.width, height: size.height).background(Theme.canvas)
                    .environment(app).environment(\.colorScheme, dark ? .dark : .light)))
                host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                host.frame = NSRect(origin: .zero, size: size)
                let win = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: size.width, height: size.height),
                                   styleMask: .borderless, backing: .buffered, defer: false)
                win.contentView = host
                RunLoop.main.run(until: Date().addingTimeInterval(1.5))
                host.layoutSubtreeIfNeeded()
                let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: rep)
                try #require(rep.representation(using: .png, properties: [:]))
                    .write(to: URL(fileURLWithPath: dir).appending(path: "\(name)-\(mode).png"))
            }
        }
    }
}
