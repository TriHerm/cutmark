import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Cutmark

/// The Plan board's game: week rings, the week streak with rest weeks, video steps, wins and the
/// streak chain on the chart (2026-10-10).
@Suite struct PlanGameTests {
    private func cal() -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return c
    }

    private func date(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }

    private func video(_ id: String, created: String? = nil, takes: [String] = [], out: [(String, Int?)] = [],
                       edit: String? = nil, ready: Bool = false, archived: Bool = false) -> WeekGame.Video {
        var v = WeekGame.Video(id: "P/" + id, url: URL(fileURLWithPath: "/lib/P/" + id), title: id)
        v.createdAt = created.map(date)
        v.takes = takes.map(date)
        v.out = out.map { ("LinkedIn", date($0.0), $0.1) }
        v.edit = edit.map(date)
        v.ready = ready
        v.readyNoDay = ready
        v.archived = archived
        return v
    }

    private let plan = PostingPlan(days: ["tue", "thu"], time: "08:02", platforms: ["linkedin"])

    @Test func ringsStreakAndRestWeek() {
        // Wed Oct 7, noon in LA. Weeks start Sunday: this week is Oct 4.
        let now = date("2026-10-07T19:00:00Z")
        let videos = [
            video("a", out: [("2026-09-15T15:00:00Z", nil)]), video("b", out: [("2026-09-17T15:00:00Z", nil)]),
            // Sep 20 week: nothing. A rest week bridges it.
            video("c", out: [("2026-09-29T15:00:00Z", nil)]), video("d", out: [("2026-10-01T15:00:00Z", nil)]),
            video("e", created: "2026-10-05T18:00:00Z", takes: ["2026-10-06T18:00:00Z"], out: [("2026-10-06T15:00:00Z", nil)]),
            video("f", created: "2026-10-06T18:00:00Z"),
        ]
        let g = WeekGame.game(videos, plan: plan, now: now, cal: cal())
        #expect(g.ideas.count == 2 && g.ideas.goal == 3)
        #expect(g.recorded.count == 1 && g.recorded.goal == 2)
        #expect(g.posts.count == 1 && !g.posts.done)
        // This week is still running: it does not break the streak.
        #expect(!g.weekCounted && g.streak == 2 && g.rested && g.restLeft)
        #expect(GameWords.streak(g) == "1 more post this week adds week 3")
        #expect(g.chain.values.filter { $0 == .counted }.count == 2 && g.chain.values.contains(.rest))

        // A second missed week in September: only one rest week a month.
        let two = [video("a", out: [("2026-09-08T15:00:00Z", nil)]), video("b", out: [("2026-09-10T15:00:00Z", nil)])]
            + videos.dropFirst(2)
        let h = WeekGame.game(Array(two), plan: plan, now: now, cal: cal())
        #expect(h.streak == 1)

        // Two posts this week: it counts at once.
        let full = videos + [video("g", out: [("2026-10-07T15:00:00Z", nil)])]
        let k = WeekGame.game(full, plan: plan, now: now, cal: cal())
        #expect(k.weekCounted && k.streak == 3 && GameWords.streak(k) == "This week counts already")
        #expect(GameWords.rings(k) == "Posting goal done this week. Nice.")
    }

    @Test func stepsFillTheHolesAndAlmostThereStaysKind() {
        let now = date("2026-10-07T19:00:00Z")
        let videos = [
            video("idea", created: "2026-10-06T18:00:00Z"),
            // Recorded without a script: Script counts as done, no hole.
            video("recorded", created: "2026-10-01T18:00:00Z", takes: ["2026-10-02T18:00:00Z"]),
            video("edited", created: "2026-09-30T18:00:00Z", takes: ["2026-10-01T18:00:00Z"], edit: "2026-10-05T18:00:00Z"),
            video("readyNoDay", created: "2026-09-30T18:00:00Z", ready: true),
            // Old and untouched: never named.
            video("old", created: "2026-08-01T18:00:00Z", takes: ["2026-08-02T18:00:00Z"]),
            video("hidden", created: "2026-10-01T18:00:00Z", takes: ["2026-10-02T18:00:00Z"], archived: true),
            video("out", created: "2026-10-01T18:00:00Z", out: [("2026-10-06T15:00:00Z", nil)]),
        ]
        let g = WeekGame.game(videos, plan: plan, now: now, cal: cal())
        #expect(g.steps["P/idea"] == 0 && g.steps["P/recorded"] == 2 && g.steps["P/edited"] == 3 && g.steps["P/out"] == 4)
        #expect(g.almost.map(\.title) == ["edited", "readyNoDay", "recorded"])
        #expect(g.almost.map(GameWords.next) == ["Next: post it", "Next: pick a day", "Next: the edit"])
    }

    @Test func winsOnlyGoodNewsAndMilestones() {
        let now = date("2026-10-07T19:00:00Z")
        let videos = [
            video("big", out: [("2026-10-03T15:00:00Z", 12_400)]),
            video("ok", out: [("2026-10-01T15:00:00Z", 900)]),
            video("old1", out: [("2026-05-01T15:00:00Z", 3_000)]),
            video("old2", out: [("2026-04-01T15:00:00Z", 1_000)]),
        ]
        let g = WeekGame.game(videos, plan: plan, now: now, cal: cal())
        #expect(g.wins.map(\.label) == ["Your best post ever"])  // "ok" is below typical: no card
        let reach = g.milestones.first { $0.id == "reach" }
        #expect(reach?.total == 17_300 && reach?.passed == 10_000 && reach?.next == 25_000)
        let videos4 = g.milestones.first { $0.id == "videos" }
        #expect(videos4?.passed == 1 && videos4?.next == 5)
    }

    /// The files: a script, takes, an edit and a ready post set the steps.
    @Test func scanReadsTheSessionFiles() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "plangame-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        func session(_ name: String, takes: Int = 0) throws -> URL {
            let s = root.appending(path: "Proj/\(name)")
            try FileManager.default.createDirectory(at: s, withIntermediateDirectories: true)
            let json: [String: Any] = ["title": name, "createdAt": "2026-10-05T10:00:00Z",
                                       "takes": (0..<takes).map { ["number": $0 + 1, "kind": "camera", "file": "t\($0).mov", "startedAt": "2026-10-06T18:00:00Z"] }]
            try JSONSerialization.data(withJSONObject: json).write(to: s.appending(path: "session.json"))
            return s
        }
        try "Hello".write(to: try session("scripted").appending(path: "script.md"), atomically: true, encoding: .utf8)
        let edited = try session("edited", takes: 1)
        try FileManager.default.createDirectory(at: edited.appending(path: "edits"), withIntermediateDirectories: true)
        try Data().write(to: edited.appending(path: "edits/cut-v1.mp4"))
        PostFile.write(PostFile.Content(text: "Hook.\n", meta: ["status": "ready"]), to: try session("ready"), .linkedin)
        let g = WeekGame.scan(root, plan: plan, now: date("2026-10-07T19:00:00Z"), cal: cal())
        #expect(g.steps["Proj/scripted"] == 1 && g.steps["Proj/edited"] == 3 && g.steps["Proj/ready"] == 3)
        #expect(g.ideas.count == 3 && g.recorded.count == 1)
        #expect(g.almost.first { $0.title == "ready" }?.readyNoDay == true)
    }

    /// The cards, rendered to look at. `CUTMARK_SNAPSHOT=/some/dir`.
    @MainActor @Test func snapshots() throws {
        guard let dir = ProcessInfo.processInfo.environment["CUTMARK_SNAPSHOT"] else { return }
        let url = URL(fileURLWithPath: "/lib/P/x")
        var g = WeekGame()
        g.ideas = .init(name: "Ideas", count: 2, goal: 3)
        g.recorded = .init(name: "Recorded", count: 2, goal: 2)
        g.posts = .init(name: "Posts", count: 1, goal: 2)
        g.streak = 4
        g.rested = false
        g.almost = [.init(id: "a", title: "Why I stopped using Notion", url: url, step: 3),
                    .init(id: "b", title: "Building Cutmark in public, week 3", url: url, step: 3, readyNoDay: true),
                    .init(id: "c", title: "The 20-minute video", url: url, step: 2)]
        g.wins = [.init(id: "w", title: "Claude shop", url: url, platform: "LinkedIn", reach: 12_400, label: "Your best post ever", at: Date()),
                  .init(id: "v", title: "Tulum", url: url, platform: "LinkedIn", reach: 6_100, label: "2.4× your typical post", at: Date())]
        g.milestones = [WeekGame.milestone("reach", "impressions", 142_000, WeekGame.reachMarks)!,
                        WeekGame.milestone("videos", "videos out", 23, WeekGame.videoMarks)!]
        // The chart: four weeks in the chain (one a rest week), this week open, a crown on the best week.
        let cal = Calendar.current
        let this = cal.dateInterval(of: .weekOfYear, for: Date())!.start
        let weeks = (-6...1).map { i in
            var w = ConsistencyStats.WeekCount(start: cal.date(byAdding: .weekOfYear, value: i, to: this)!)
            w.posted = i < 0 ? [1, 2, 2, 0, 3, 2][i + 6] : i == 0 ? 1 : 0
            w.scheduled = i == 0 ? 1 : 0
            w.planned = i == 1 ? 2 : 0
            return w
        }
        for (i, link) in [(-5, WeekGame.Link.counted), (-4, .counted), (-3, .rest), (-2, .counted), (-1, .counted)] {
            g.chain[weeks[i + 6].start] = link
        }
        g.wins[0] = .init(id: "w", title: "Claude shop", url: url, platform: "LinkedIn", reach: 12_400,
                          label: "Your best post ever", at: weeks[4].start.addingTimeInterval(86_400 * 2))
        var quiet = WeekGame()
        quiet.posts = .init(name: "Posts", count: 0, goal: 2)
        let stack = VStack(alignment: .leading, spacing: 14) {
            PlanWeeks(weeks: weeks, goal: 2, note: "7 takes this week", game: g).card(padding: 16)
            PlanWeeks(weeks: weeks, goal: 2, note: "No takes yet this week", game: quiet).card(padding: 16)
        }
        .padding(28)
        let views: [(String, CGSize, AnyView)] = [("plan-game", CGSize(width: 1000, height: 640), AnyView(stack))]
        for (name, size, view) in views {
            for (mode, dark) in [("dark", true), ("light", false)] {
                let host = NSHostingView(rootView: AnyView(view.frame(width: size.width, height: size.height, alignment: .top).background(Theme.paper)
                    .environment(\.colorScheme, dark ? .dark : .light)))
                host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                host.frame = NSRect(origin: .zero, size: size)
                let win = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: size.width, height: size.height),
                                   styleMask: .borderless, backing: .buffered, defer: false)
                win.contentView = host
                RunLoop.main.run(until: Date().addingTimeInterval(2))
                host.layoutSubtreeIfNeeded()
                let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: rep)
                try #require(rep.representation(using: .png, properties: [:]))
                    .write(to: URL(fileURLWithPath: dir).appending(path: "\(name)-\(mode).png"))
            }
        }
    }
}
