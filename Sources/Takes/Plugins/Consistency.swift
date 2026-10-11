import SwiftUI

/// Consistency (2026-10-09): a coach that helps you show up on the days you said you would.
/// You pick your posting days and a time once, in a few taps; Takes keeps them in
/// <root>/_library/plan.json, the same file the MCP reads (get_plan, set_plan). Each plan day in the
/// next two weeks is a slot. A ready, scheduled or posted post with a time on that day fills it.
///
/// The board shows the next open slot, the buffer (filled slots before the first open one), the
/// recording streak (weeks in a row with at least one take: the earliest step, and the one that
/// only depends on you) and how many slots you kept since you started. It praises, it never nags.
/// The chat hears the plan in every session and says which slot a new take can fill.
///
/// Off on the Plugins board: plan.json gets "off": true, so the chat stops talking about slots.
/// gtm/consistency.md (private) has the ideas still to build: the version budget, cheap formats,
/// the takes streak on the phone, the team board.
///
/// Plan (2026-10-10): the board is called Plan, and it plans videos too. A video card is a session
/// put on a day (plan.json "videos", in order), by the chat (plan_video) or by dragging the card to
/// another day. A card covers its slot as planned; a post with a time fills it (2026-10-10: the
/// buffer stayed 0 with seven videos planned, so cards count now). "Add a week" shows more
/// weeks (plan.json "weeks", 2 to 12). The plugin id stays "consistency", for the files and the phone.
enum Consistency {
    static let plugin = TakesPlugin(
        id: "consistency", title: "Plan", icon: "calendar", key: "c",
        help: "Plan your videos on a calendar. Pick the days you post, and Takes shows your next slot, your buffer and your streak (⇧⌘C)",
        badge: { _ in AnyView(EmptyView()) },
        board: { app in
            let root = app.library.root
            ClaudeChat.boardContexts["consistency"] = { context(root) }
            let library = app.library
            return AnyView(ConsistencyBoard(hub: app.chats, root: root, choices: { PlanChoice.all(library) }) { url in
                app.board = nil
                app.library.select(url)
            })
        },
        toggled: { app, on in PostingPlan.setOff(app.library.root, !on) })

    @MainActor static func context(_ root: URL) -> String {
        """
        The user is talking to you from the Plan board inside his Takes app: a calendar of the next weeks. \
        It shows his posting days (get_plan; change them with set_plan when he asks), a chart of videos \
        per week (posted, scheduled, planned, against his goal), the open posting days and the video \
        cards he planned. Each card says Posted or Scheduled from its post: when he says a video went \
        live, call set_post_status with status posted (and the url if he gives one); the card turns green. \
        Say "posting day", not "slot" or "buffer". Put a session on a day with plan_video \
        when he asks to plan videos (several in one go is fine; a day with no slot is fine too); he drags \
        the cards to change the order. Help him fill the next open slot with what he has: a ready post \
        without a time, a draft close to done, or a quick take in a cheap format. Ask before you schedule \
        anything. Be warm and short: praise what he did, never nag about a gap. He reads your replies in a \
        narrow panel: no tables, no headings.
        """
    }
}

// MARK: - The plan

struct PostingPlan: Codable, Equatable {
    var days: [String]
    /// "HH:MM", 24-hour, in this Mac's time zone.
    var time: String
    var platforms: [String]
    /// The day the plan started ("yyyy-MM-dd"): slots before it do not count.
    var since: String?
    /// The plugin is off: the chat leaves the plan alone.
    var off: Bool?
    /// How many weeks the board shows (2 to 12). Nil: two.
    var weeks: Int?
    /// The video cards, in order: a day's cards show in the order they have here.
    var videos: [PlannedVideo]?

    static let weekRange = 2...12
    var weekCount: Int { min(max(weeks ?? 2, Self.weekRange.lowerBound), Self.weekRange.upperBound) }

    /// The cards with `session` on `day`, before the card `before` (else last that day). No day:
    /// the card comes off the plan.
    nonisolated static func moved(_ videos: [PlannedVideo], _ session: String, to day: String?, before: String? = nil) -> [PlannedVideo] {
        var v = videos.filter { $0.session != session }
        guard let day else { return v }
        let card = PlannedVideo(session: session, day: day)
        if let before, let i = v.firstIndex(where: { $0.session == before && $0.day == day }) {
            v.insert(card, at: i)
        } else if let i = v.lastIndex(where: { $0.day == day }) {
            v.insert(card, at: i + 1)
        } else {
            v.append(card)
        }
        return v
    }

    static let weekdays = ["mon", "tue", "wed", "thu", "fri", "sat", "sun"]
    /// Two a week: enough to build the habit, little enough to keep.
    static let suggested: Set<String> = ["tue", "thu"]
    /// Odd minutes look like a person posted, not a scheduler.
    static let times: [(label: String, value: String)] = [("Morning", "08:02"), ("Lunch", "12:07"), ("Evening", "17:33")]

    nonisolated static func file(_ root: URL) -> URL { root.appending(path: "_library/plan.json") }

    nonisolated static func read(_ root: URL) -> PostingPlan? {
        guard let data = try? Data(contentsOf: file(root)),
              var p = try? JSONDecoder().decode(PostingPlan.self, from: data) else { return nil }
        p.days = weekdays.filter(p.days.contains)
        return p.days.isEmpty ? nil : p
    }

    nonisolated static func write(_ root: URL, _ plan: PostingPlan) {
        var plan = plan
        plan.days = weekdays.filter(plan.days.contains)
        if plan.since == nil { plan.since = day(Date()) }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? FileManager.default.createDirectory(at: file(root).deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? enc.encode(plan) { try? data.write(to: file(root), options: .atomic) }
    }

    nonisolated static func setOff(_ root: URL, _ off: Bool) {
        guard var p = read(root) else { return }
        p.off = off ? true : nil
        write(root, p)
    }

    nonisolated static func day(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }

    /// "mon" for a date, in this Mac's calendar.
    nonisolated static func weekday(_ d: Date, _ cal: Calendar = .current) -> String {
        // Calendar weekday: 1 is Sunday.
        weekdays[(cal.component(.weekday, from: d) + 5) % 7]
    }

    /// "8:02 AM".
    static func clock(_ hhmm: String) -> String {
        let parts = hhmm.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2 else { return hhmm }
        let h = parts[0] % 12 == 0 ? 12 : parts[0] % 12
        return String(format: "%d:%02d %@", h, parts[1], parts[0] < 12 ? "AM" : "PM")
    }

    static func validTime(_ s: String) -> Bool {
        s.range(of: #"^([01]\d|2[0-3]):[0-5]\d$"#, options: .regularExpression) != nil
    }
}

/// A session put on a day of the plan.
struct PlannedVideo: Codable, Equatable, Hashable {
    /// "Project/folder", from the library root.
    var session: String
    /// "yyyy-MM-dd".
    var day: String
}

// MARK: - What the board counts

struct ConsistencyStats: Equatable {
    struct Slot: Equatable, Identifiable {
        let date: Date
        /// Posts with a time on that day.
        var filled: [String] = []
        /// Their sessions ("Project/folder"), in the same order.
        var filledBy: [String] = []
        /// Video cards on that day: they cover the slot until a post fills it.
        var planned: [String] = []
        var id: Date { date }
        var open: Bool { filled.isEmpty && planned.isEmpty }
    }

    /// A video card: a planned session, with its title and a picture.
    struct Card: Equatable, Identifiable {
        /// "Project/folder", as plan.json has it.
        let id: String
        let title: String
        let url: URL
        /// The newest thumbnail, else the newest edit.
        let poster: URL?
        /// Planned for a day that passed: it shows on today.
        var late = false
        /// Its post: posted, or scheduled for a time.
        var status: Status?
    }

    enum Status: Equatable {
        case posted
        case scheduled(Date)
    }

    /// One calendar week of the chart: distinct videos posted, scheduled and planned.
    struct WeekCount: Equatable, Identifiable {
        let start: Date
        var posted = 0
        var scheduled = 0
        var planned = 0
        var id: Date { start }
        var total: Int { posted + scheduled + planned }
    }

    /// Every day of the plan's weeks, from today; `planned` marks the plan days.
    var days: [(date: Date, planned: Bool)] = []
    /// Videos per week: the last six weeks, this week and the plan's weeks ahead.
    var weeks: [WeekCount] = []
    /// Posting days a week: the chart's goal line.
    var goal = 0
    /// The video cards of each day, in order.
    var videos: [Date: [Card]] = [:]
    var slots: [Slot] = []
    /// Covered slots (a post or a planned video) before the first open one.
    var buffer = 0
    /// Of those, the ones a post fills.
    var bufferReady = 0
    var nextOpen: Slot? { slots.first(where: \.open) }
    var readyWithoutTime: [String] = []
    /// Weeks in a row with at least one take. This week counts once it has one; until then the
    /// streak from last week is still alive.
    var streak = 0
    var recordedThisWeek = false
    var takesThisWeek = 0
    /// Plan days since the plan started (before today) that had a post, and how many there were.
    var kept = 0
    var due = 0

    static func == (a: Self, b: Self) -> Bool {
        a.slots == b.slots && a.buffer == b.buffer && a.bufferReady == b.bufferReady && a.readyWithoutTime == b.readyWithoutTime && a.streak == b.streak
            && a.recordedThisWeek == b.recordedThisWeek && a.takesThisWeek == b.takesThisWeek && a.kept == b.kept
            && a.due == b.due && a.days.map(\.date) == b.days.map(\.date) && a.videos == b.videos
            && a.weeks == b.weeks && a.goal == b.goal
    }

    nonisolated static func scan(_ root: URL, plan: PostingPlan, now: Date = Date(), cal: Calendar = .current) -> ConsistencyStats {
        var s = ConsistencyStats()
        let today = cal.startOfDay(for: now)
        let platforms = Set(plan.platforms.isEmpty ? ["linkedin"] : plan.platforms)

        // Posts by day, and each session's post state (posted wins over scheduled). A scheduled
        // post whose time came is out: the app marks it posted a moment later.
        var byDay: [Date: [(title: String, session: String)]] = [:]
        var state: [String: (status: Status, at: Date)] = [:]
        var readyAt: [String: Date] = [:]
        for p in PostQueue.read(root) where platforms.contains(p.platform.rawValue) {
            let c = p.content
            guard c.status != .draft else { continue }
            guard let at = c.at else {
                if c.status == .ready { s.readyWithoutTime.append(p.title) }
                continue
            }
            let id = p.project + "/" + p.session.lastPathComponent
            byDay[cal.startOfDay(for: at), default: []].append((p.title, id))
            if c.status == .posted || (c.status == .scheduled && at <= now) {
                if let was = state[id], was.status == .posted, was.at <= at { continue }
                state[id] = (.posted, at)
            } else if c.status == .scheduled {
                if let was = state[id], was.status == .posted || was.at <= at { continue }
                state[id] = (.scheduled(at), at)
            } else {
                readyAt[id] = min(readyAt[id] ?? at, at)
            }
        }

        // The video cards. One whose day passed shows on today; one past the last week waits.
        // A video posted before today is done and leaves the board.
        let horizon = plan.weekCount * 7
        let end = cal.date(byAdding: .day, value: horizon, to: today) ?? today
        for v in plan.videos ?? [] {
            guard let day = Self.parseDay(v.day, cal), day < end, let card = Self.card(root, v.session) else { continue }
            var c = card
            c.status = state[v.session]?.status
            if c.status == .posted, let at = state[v.session]?.at, cal.startOfDay(for: at) < today { continue }
            c.late = day < today && c.status == nil
            s.videos[max(day, today), default: []].append(c)
        }

        // Videos per week, one count per video.
        s.goal = plan.days.count
        let week = { (d: Date) in cal.dateInterval(of: .weekOfYear, for: d)?.start ?? cal.startOfDay(for: d) }
        let first = cal.date(byAdding: .weekOfYear, value: -6, to: week(today)) ?? week(today)
        let last = week(cal.date(byAdding: .day, value: horizon - 1, to: today) ?? today)
        var wk = first
        while wk <= last {
            s.weeks.append(WeekCount(start: wk))
            guard let next = cal.date(byAdding: .weekOfYear, value: 1, to: wk) else { break }
            wk = next
        }
        let index = Dictionary(uniqueKeysWithValues: s.weeks.enumerated().map { ($1.start, $0) })
        var counted = Set<String>()
        for (id, st) in state {
            guard let i = index[week(st.at)] else { continue }
            if st.status == .posted { s.weeks[i].posted += 1 } else { s.weeks[i].scheduled += 1 }
            counted.insert(id)
        }
        for (id, at) in readyAt where !counted.contains(id) {
            guard let i = index[week(at)] else { continue }
            s.weeks[i].planned += 1
            counted.insert(id)
        }
        for (day, cards) in s.videos {
            guard let i = index[week(day)] else { continue }
            s.weeks[i].planned += cards.filter { !counted.contains($0.id) }.count
        }

        for i in 0..<horizon {
            guard let d = cal.date(byAdding: .day, value: i, to: today) else { continue }
            let planned = plan.days.contains(PostingPlan.weekday(d, cal))
            s.days.append((d, planned))
            if planned {
                let posts = byDay[d] ?? []
                s.slots.append(Slot(date: d, filled: posts.map(\.title), filledBy: posts.map(\.session),
                                    planned: (s.videos[d] ?? []).map(\.title)))
            }
        }
        s.buffer = s.slots.firstIndex(where: \.open) ?? s.slots.count
        s.bufferReady = s.slots.prefix(s.buffer).filter { !$0.filled.isEmpty }.count

        // Slots kept since the plan started.
        if let since = plan.since.flatMap({ Self.parseDay($0, cal) }), since < today {
            var d = cal.startOfDay(for: since)
            while d < today {
                if plan.days.contains(PostingPlan.weekday(d, cal)) {
                    s.due += 1
                    if byDay[d] != nil { s.kept += 1 }
                }
                guard let next = cal.date(byAdding: .day, value: 1, to: d) else { break }
                d = next
            }
        }

        // The recording streak, from every take's start.
        var weeks = Set<Date>()
        let thisWeek = cal.dateInterval(of: .weekOfYear, for: now)?.start ?? today
        for start in Self.takeStarts(root) {
            guard let w = cal.dateInterval(of: .weekOfYear, for: start)?.start else { continue }
            weeks.insert(w)
            if w == thisWeek { s.takesThisWeek += 1 }
        }
        s.recordedThisWeek = weeks.contains(thisWeek)
        var w = s.recordedThisWeek ? thisWeek : cal.date(byAdding: .weekOfYear, value: -1, to: thisWeek) ?? thisWeek
        while weeks.contains(w) {
            s.streak += 1
            guard let prev = cal.date(byAdding: .weekOfYear, value: -1, to: w) else { break }
            w = prev
        }
        return s
    }

    nonisolated static func parseDay(_ s: String, _ cal: Calendar = .current) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = cal.timeZone
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: s).map { cal.startOfDay(for: $0) }
    }

    /// A planned session's card, or nil when the session is gone.
    nonisolated static func card(_ root: URL, _ session: String) -> Card? {
        let url = root.appending(path: session)
        guard let data = try? Data(contentsOf: url.appending(path: "session.json")) else { return nil }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let title = (json?["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? url.lastPathComponent
        return Card(id: session, title: title, url: url,
                    poster: newest(url.appending(path: "thumbnails"), ["png", "jpg", "jpeg"])
                        ?? newest(url.appending(path: "edits"), ["mp4", "mov"]))
    }

    nonisolated private static func newest(_ dir: URL, _ kinds: [String]) -> URL? {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files.filter { kinds.contains($0.pathExtension.lowercased()) }
            .max { a, b in
                let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return da < db
            }
    }

    /// When each take started, from every session.json.
    nonisolated static func takeStarts(_ root: URL) -> [Date] {
        FeedbackStats.sessions(root).flatMap { session -> [Date] in
            guard let data = try? Data(contentsOf: session.appending(path: "session.json")),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let takes = json["takes"] as? [[String: Any]] else { return [] }
            return takes.compactMap { ($0["startedAt"] as? String).flatMap(FeedbackStats.dateOf) }
        }
    }
}

// MARK: - Words

/// What the board says. Warm and short, never a guilt trip (gtm/consistency.md).
enum CoachWords {
    static func forCount(_ n: Int) -> String {
        switch n {
        case 0: return "Pick at least one day."
        case 1: return "A calm start. One good post a week adds up."
        case 2: return "The sweet spot. Easy to keep, enough to grow."
        case 3: return "Strong. A small buffer will carry you through busy weeks."
        default: return "Ambitious! Cheap formats will save you on busy days."
        }
    }

    static func perMonth(_ n: Int) -> String {
        "That's \(n) post\(n == 1 ? "" : "s") a week, about \(Int((Double(n) * 4.3).rounded())) a month."
    }

    /// The board's opening line.
    static func headline(_ s: ConsistencyStats, now: Date = Date(), cal: Calendar = .current) -> String {
        if s.slots.isEmpty { return "Your plan is set." }
        guard let open = s.nextOpen else { return "Every posting day ahead has a video." }
        if cal.isDateInToday(open.date) { return "Today is a posting day, and it has no video yet." }
        if cal.isDateInTomorrow(open.date) { return "Tomorrow is a posting day, and it has no video yet." }
        if s.buffer >= 2 { return "Your next \(s.buffer) posting days have a video. Next free one: \(day(open.date))." }
        return "Next posting day without a video: \(day(open.date))."
    }

    static func bufferNote(_ s: ConsistencyStats) -> String {
        if s.buffer == 0 { return "slots covered in a row" }
        let planned = s.buffer - s.bufferReady
        if planned == 0 { return "\(s.buffer == 1 ? "post" : "posts") ready in a row" }
        if s.bufferReady == 0 { return "planned in a row, no post yet" }
        return "\(s.bufferReady) ready, \(planned) planned"
    }

    /// The line under the chart.
    static func recording(_ s: ConsistencyStats) -> String {
        let takes = s.takesThisWeek == 0 ? "No takes yet this week" : "\(s.takesThisWeek) take\(s.takesThisWeek == 1 ? "" : "s") this week"
        if s.streak < 2 { return takes + "." }
        return takes + ". You recorded \(s.streak) weeks in a row."
    }

    static func streakNote(_ s: ConsistencyStats) -> String {
        if s.streak == 0 { return "Record one take this week to start" }
        if !s.recordedThisWeek { return "One take this week keeps it going" }
        return "\(s.takesThisWeek) take\(s.takesThisWeek == 1 ? "" : "s") this week"
    }

    static func day(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "EEE, MMM d"
        return f.string(from: d)
    }
}

// MARK: - Board

@MainActor @Observable
final class ConsistencyStore {
    var plan: PostingPlan?
    var stats = ConsistencyStats()
    var loaded = false
    private var busy = false
    private var again = false

    func refresh(_ root: URL) {
        guard !busy else { again = true; return }
        busy = true
        Task.detached(priority: .utility) {
            let plan = PostingPlan.read(root)
            let stats = plan.map { ConsistencyStats.scan(root, plan: $0) } ?? ConsistencyStats()
            await MainActor.run {
                if self.plan != plan { self.plan = plan }
                if self.stats != stats { self.stats = stats }
                self.loaded = true
                self.busy = false
                if self.again { self.again = false; self.refresh(root) }
            }
        }
    }

    func save(_ root: URL, _ plan: PostingPlan) {
        var plan = plan
        plan.since = self.plan?.since
        plan.weeks = self.plan?.weeks
        plan.videos = self.plan?.videos
        plan.off = nil
        self.plan = plan
        let p = plan
        change(root) { $0 = PostingPlan(days: p.days, time: p.time, platforms: p.platforms,
                                        since: $0.since, weeks: $0.weeks, videos: $0.videos) }
    }

    /// Puts a card on a day (before another card, else last). The board moves it at once; the file
    /// follows. A card from outside the plan must be a session folder.
    func place(_ root: URL, _ id: String, on day: Date, before: String? = nil) {
        guard id != before else { return }
        var s = stats
        var card = s.videos.values.joined().first { $0.id == id }
        if card == nil { card = ConsistencyStats.card(root, id) }
        guard var card else { return }
        card.late = false
        for k in s.videos.keys { s.videos[k]?.removeAll { $0.id == id } }
        var list = s.videos[day] ?? []
        list.insert(card, at: before.flatMap { b in list.firstIndex { $0.id == b } } ?? list.count)
        s.videos[day] = list
        withAnimation(Theme.spring) { stats = s }
        let to = PostingPlan.day(day)
        change(root) { $0.videos = PostingPlan.moved($0.videos ?? [], id, to: to, before: before) }
    }

    func remove(_ root: URL, _ id: String) {
        var s = stats
        for k in s.videos.keys { s.videos[k]?.removeAll { $0.id == id } }
        withAnimation(Theme.spring) { stats = s }
        change(root) { $0.videos = PostingPlan.moved($0.videos ?? [], id, to: nil) }
    }

    func setWeeks(_ root: URL, _ n: Int) {
        let n = min(max(n, PostingPlan.weekRange.lowerBound), PostingPlan.weekRange.upperBound)
        plan?.weeks = n
        change(root) { $0.weeks = n }
    }

    /// Changes the plan as the file has it now, so a card the chat just added stays.
    private func change(_ root: URL, _ edit: @escaping @Sendable (inout PostingPlan) -> Void) {
        guard let mine = plan else { return }
        Task.detached(priority: .userInitiated) {
            var p = PostingPlan.read(root) ?? mine
            edit(&p)
            p.off = nil
            PostingPlan.write(root, p)
            await MainActor.run { self.refresh(root) }
        }
    }
}

struct ConsistencyBoard: View {
    var hub: ChatHub
    let root: URL
    /// The sessions the user can put on a day himself (a day's +).
    var choices: () -> [PlanChoice] = { [] }
    /// Opens a session (a card's click).
    var open: (URL) -> Void = { _ in }
    @State private var store = ConsistencyStore()

    var body: some View {
        let target = ChatTarget(chat: hub.boardChat("consistency"), title: "Plan", session: nil)
        ChatSlot(hub: hub, target: target) {
            ConsistencyPage(store: store, root: root, choices: choices, open: open)
        }
        .overlay(alignment: .bottomTrailing) {
            BoardChatCorner(hub: hub, target: target).padding(18)
        }
        .onAppear { store.refresh(root) }
        .onReceive(NotificationCenter.default.publisher(for: .takesFilesChanged)) { _ in store.refresh(root) }
    }
}

struct ConsistencyPage: View {
    let store: ConsistencyStore
    let root: URL
    var choices: () -> [PlanChoice] = { [] }
    var open: (URL) -> Void = { _ in }
    @State private var editing = false
    @State private var celebrate = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Rule()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if store.loaded {
                        if store.plan == nil || editing {
                            CommitCard(start: store.plan, first: store.plan == nil) { plan in
                                let first = store.plan == nil
                                store.save(root, plan)
                                withAnimation(.page) { editing = false }
                                if first { celebrate = true }
                            } cancel: {
                                if store.plan != nil { withAnimation(.page) { editing = false } }
                            }
                            .arrive(0)
                        } else if let plan = store.plan {
                            Text(CoachWords.headline(store.stats))
                                .font(Theme.display(26)).foregroundStyle(Theme.ink)
                                .swapIn(CoachWords.headline(store.stats))
                                .arrive(0)
                            PlanWeeks(weeks: store.stats.weeks, goal: store.stats.goal,
                                      note: CoachWords.recording(store.stats))
                                .card(padding: 16).arrive(1)
                            SlotStrip(stats: store.stats, weeks: plan.weekCount, choices: choices, open: open,
                                      place: { store.place(root, $0, on: $1, before: $2) },
                                      remove: { store.remove(root, $0) },
                                      setWeeks: { store.setWeeks(root, $0) })
                                .card(padding: 16).arrive(5)
                            if !store.stats.readyWithoutTime.isEmpty { ready.arrive(6) }
                        }
                    }
                }
                .padding(.horizontal, 28).padding(.vertical, 22)
                .frame(maxWidth: 1100, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
        }
        .background(Theme.paper)
        .overlay {
            if celebrate {
                Confetti().allowsHitTesting(false)
                    .task { try? await Task.sleep(for: .seconds(3.5)); celebrate = false }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Plan").font(Theme.sans(16, .bold)).foregroundStyle(Theme.ink)
                Text(subtitle).font(Theme.sans(11.5)).foregroundStyle(Theme.faint)
            }
            Spacer(minLength: 12)
            if store.plan != nil && !editing {
                Button("Change days") { withAnimation(.page) { editing = true } }.buttonStyle(BracketButtonStyle())
            }
        }
        .padding(.horizontal, 28).frame(height: 58)
    }

    private var subtitle: String {
        guard let p = store.plan else { return "Show up on the days you choose" }
        let names = p.days.map { $0.prefix(1).uppercased() + $0.dropFirst() }
        return names.joined(separator: ", ") + " at " + PostingPlan.clock(p.time)
    }

    private var ready: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Ready, waiting for a slot").font(Theme.sans(13, .semibold)).foregroundStyle(Theme.ink)
            ForEach(store.stats.readyWithoutTime, id: \.self) { title in
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 12)).foregroundStyle(Theme.live)
                    Text(title).font(Theme.sans(13)).foregroundStyle(Theme.ink).lineLimit(1)
                }
            }
            Text("Ask Takes in the chat to put one in your next open slot.")
                .font(Theme.sans(11.5)).foregroundStyle(Theme.faint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: 16)
    }
}

// MARK: - The commitment

/// Your days and time, in a few taps: day chips (Tue and Thu picked to start), three times, and the
/// platforms. Each change gets a warm line back.
struct CommitCard: View {
    let first: Bool
    let commit: (PostingPlan) -> Void
    let cancel: () -> Void
    @State private var days: Set<String>
    @State private var time: String
    @State private var custom: String
    @State private var platforms: Set<String>

    init(start: PostingPlan?, first: Bool, commit: @escaping (PostingPlan) -> Void, cancel: @escaping () -> Void) {
        self.first = first
        self.commit = commit
        self.cancel = cancel
        let t = start?.time ?? PostingPlan.times[0].value
        _days = State(initialValue: Set(start?.days ?? Array(PostingPlan.suggested)))
        _time = State(initialValue: t)
        _custom = State(initialValue: PostingPlan.times.contains { $0.value == t } ? "" : t)
        _platforms = State(initialValue: Set(start?.platforms ?? ["linkedin"]))
    }

    private var ok: Bool { !days.isEmpty && !platforms.isEmpty && PostingPlan.validTime(time) }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 6) {
                Text(first ? "When do you want to show up?" : "Change your days")
                    .font(Theme.display(28)).foregroundStyle(Theme.ink)
                Text("Pick the days you'll post. Two a week is a great start, and you can change it any time.")
                    .font(Theme.sans(13)).foregroundStyle(Theme.muted)
            }

            VStack(alignment: .leading, spacing: 10) {
                SectionLabel(text: "Days")
                HStack(spacing: 8) {
                    ForEach(PostingPlan.weekdays, id: \.self) { d in
                        DayChip(day: d, on: days.contains(d), suggested: PostingPlan.suggested.contains(d)) {
                            withAnimation(Theme.spring) { if days.contains(d) { days.remove(d) } else { days.insert(d) } }
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(CoachWords.forCount(days.count)).font(Theme.sans(13, .semibold))
                        .foregroundStyle(days.isEmpty ? Theme.muted : Theme.live)
                    if !days.isEmpty {
                        Text(CoachWords.perMonth(days.count)).font(Theme.sans(12)).foregroundStyle(Theme.faint)
                    }
                }
                .swapIn(days.count)
            }

            VStack(alignment: .leading, spacing: 10) {
                SectionLabel(text: "Time")
                HStack(spacing: 8) {
                    ForEach(PostingPlan.times, id: \.value) { t in
                        OptionChip(title: t.label, detail: PostingPlan.clock(t.value), on: time == t.value && custom.isEmpty) {
                            withAnimation(Theme.motion) { time = t.value; custom = "" }
                        }
                    }
                    TextField("Other, 09:41", text: $custom)
                        .textFieldStyle(.plain).font(Theme.sans(13)).monospacedDigit()
                        .frame(width: 96).padding(.horizontal, 12).frame(height: 40)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.hover))
                        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(!custom.isEmpty ? (PostingPlan.validTime(custom) ? Theme.accent : Theme.warn) : .clear, lineWidth: 1.5))
                        .onChange(of: custom) { _, v in if PostingPlan.validTime(v) { time = v } else if v.isEmpty { time = PostingPlan.times[0].value } }
                        .help("Any time, 24-hour: 09:41")
                }
                Text("In this Mac's time zone (\(TimeZone.current.abbreviation() ?? TimeZone.current.identifier)). Odd minutes look like a person posted.")
                    .font(Theme.sans(11.5)).foregroundStyle(Theme.faint)
            }

            VStack(alignment: .leading, spacing: 10) {
                SectionLabel(text: "Where")
                HStack(spacing: 8) {
                    ForEach([PostPlatform.linkedin, .x, .youtube, .vertical], id: \.self) { p in
                        OptionChip(title: p.name, detail: nil, on: platforms.contains(p.rawValue)) {
                            withAnimation(Theme.motion) {
                                if platforms.contains(p.rawValue) { platforms.remove(p.rawValue) } else { platforms.insert(p.rawValue) }
                            }
                        }
                    }
                }
                Text("A post on any of these fills the day's slot.").font(Theme.sans(11.5)).foregroundStyle(Theme.faint)
            }

            HStack(spacing: 10) {
                Button(first ? "I'm in" : "Save") {
                    commit(PostingPlan(days: Array(days), time: time, platforms: Array(platforms)))
                }
                .buttonStyle(AccentButtonStyle(kind: .accent)).disabled(!ok).keyboardShortcut(.defaultAction)
                if !first { Button("Cancel", action: cancel).buttonStyle(AccentButtonStyle(kind: .quiet)) }
                Spacer()
            }
        }
        .padding(26)
        .frame(maxWidth: 640, alignment: .leading)
        .card(padding: 0)
        .frame(maxWidth: .infinity)
        .padding(.top, 18)
    }
}

/// A round weekday toggle: "Tue", with a small dot under the suggested ones.
struct DayChip: View {
    let day: String
    let on: Bool
    let suggested: Bool
    let tap: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: tap) {
            VStack(spacing: 4) {
                Text(day.prefix(1).uppercased() + day.dropFirst())
                    .font(Theme.sans(13, .semibold))
                    .foregroundStyle(on ? Color.white : Theme.ink)
                    .frame(width: 56, height: 56)
                    .background(Circle().fill(on ? Theme.accent : hover ? Theme.hover : Theme.canvas))
                    .overlay(Circle().strokeBorder(on ? .clear : Theme.border))
                    .shadow(color: on ? Theme.accent.opacity(0.35) : .clear, radius: 8, y: 3)
                    .scaleEffect(on ? 1.04 : 1)
                Text(suggested ? "suggested" : " ").font(Theme.sans(9.5)).foregroundStyle(Theme.faint)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PressScale())
        .onHover { hover = $0 }
        .animation(Theme.motion, value: hover)
        .help(on ? "Posting day. Click to take it off." : "Click to post on this day.")
    }
}

/// A rounded choice: a title and an optional small detail ("Morning · 8:02 AM").
struct OptionChip: View {
    let title: String
    let detail: String?
    let on: Bool
    let tap: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: tap) {
            HStack(spacing: 6) {
                if on { Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)) }
                Text(title).font(Theme.sans(13, .semibold))
                if let detail { Text(detail).font(Theme.sans(12)).opacity(0.75) }
            }
            .foregroundStyle(on ? Theme.accentInk : Theme.ink)
            .padding(.horizontal, 14).frame(height: 40)
            .background(RoundedRectangle(cornerRadius: 12).fill(on ? Theme.accentSoft : hover ? Theme.hover : Theme.canvas))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(on ? Theme.accent : Theme.border, lineWidth: on ? 1.5 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressScale())
        .onHover { hover = $0 }
        .animation(Theme.motion, value: hover)
    }
}

// MARK: - The weeks

/// The plan's weeks, a row each: plan days are slots, filled (mint, with the post) or open
/// (dashed). Video cards sit on their days; drag one to another day, or onto a card to go before it.
struct SlotStrip: View {
    let stats: ConsistencyStats
    var weeks = 2
    var choices: () -> [PlanChoice] = { [] }
    var open: (URL) -> Void = { _ in }
    var place: (String, Date, String?) -> Void = { _, _, _ in }
    var remove: (String) -> Void = { _ in }
    var setWeeks: (Int) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(weeks == 2 ? "Next two weeks" : "Next \(weeks) weeks").font(Theme.sans(13, .semibold)).foregroundStyle(Theme.ink)
                Spacer()
                Text(summary).font(Theme.sans(11.5)).foregroundStyle(Theme.faint)
            }
            ForEach(0..<weeks, id: \.self) { week in
                HStack(alignment: .top, spacing: 8) {
                    ForEach(Array(stats.days.dropFirst(week * 7).prefix(7).enumerated()), id: \.offset) { _, d in
                        DayCell(date: d.date, planned: d.planned, slot: stats.slots.first { $0.date == d.date },
                                cards: stats.videos[d.date] ?? [], choices: choices, open: open, place: place, remove: remove)
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
            HStack(spacing: 6) {
                if weeks < PostingPlan.weekRange.upperBound {
                    Button { withAnimation(Theme.spring) { setWeeks(weeks + 1) } } label: {
                        Label("Add a week", systemImage: "plus")
                    }
                    .buttonStyle(BracketButtonStyle())
                    .help("Plan further ahead: show one more week")
                }
                if weeks > PostingPlan.weekRange.lowerBound {
                    Button { withAnimation(Theme.spring) { setWeeks(weeks - 1) } } label: {
                        Label("Show less", systemImage: "minus")
                    }
                    .buttonStyle(BracketButtonStyle())
                    .help("Hide the last week. Its cards stay planned.")
                }
                Spacer()
                if stats.videos.isEmpty {
                    Text("Point at a day and click + to add a video, or ask Takes in the chat.").font(Theme.sans(11.5)).foregroundStyle(Theme.faint)
                }
            }
        }
    }

    private var summary: String {
        let n = stats.videos.values.reduce(0) { $0 + $1.count }
        let slots = "\(stats.slots.filter { !$0.open }.count) of \(stats.slots.count) posting days have a video"
        return n == 0 ? slots : "\(n) video\(n == 1 ? "" : "s") planned · " + slots
    }
}

/// One day: its name, its video cards and its slot. Takes a card dropped on it; its + adds a session.
struct DayCell: View {
    let date: Date
    let planned: Bool
    let slot: ConsistencyStats.Slot?
    let cards: [ConsistencyStats.Card]
    let choices: () -> [PlanChoice]
    let open: (URL) -> Void
    let place: (String, Date, String?) -> Void
    let remove: (String) -> Void
    @State private var target = false
    @State private var hover = false
    @State private var picking = false

    var body: some View {
        let today = Calendar.current.isDateInToday(date)
        let f = DateFormatter()
        f.dateFormat = "EEE d"
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text(today ? "Today" : f.string(from: date))
                    .font(Theme.sans(11, today ? .bold : .medium))
                    .foregroundStyle(planned ? Theme.ink : Theme.faint)
                Spacer(minLength: 0)
                Button { picking = true } label: {
                    Image(systemName: "plus").font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Theme.accentInk)
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(Theme.accentSoft))
                }
                .buttonStyle(PressScale())
                .opacity(hover || picking ? 1 : 0)
                .help("Add a video to this day")
                .popover(isPresented: $picking, arrowEdge: .bottom) {
                    PlanPicker(choices: choices(), planned: Set(cards.map(\.id))) { id in
                        picking = false
                        place(id, date, nil)
                    }
                }
            }
            ForEach(cards) { card in
                PlanCard(card: card, open: open, remove: remove) { id in place(id, date, card.id) }
            }
            if let slot {
                let shown = Set(cards.map(\.id))
                let others = slot.filled.indices.filter { $0 >= slot.filledBy.count || !shown.contains(slot.filledBy[$0]) }.map { slot.filled[$0] }
                if !others.isEmpty {
                    Text(others.joined(separator: ", ")).font(Theme.sans(11.5, .medium)).foregroundStyle(Theme.live)
                        .lineLimit(2).multilineTextAlignment(.leading)
                        .padding(8)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .topLeading)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.liveSoft))
                        .help(others.joined(separator: "\n"))
                } else if slot.filled.isEmpty && cards.isEmpty {
                    Text("Open").font(Theme.sans(11.5, .medium)).foregroundStyle(Theme.muted)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.border, style: StrokeStyle(lineWidth: 1.2, dash: [4, 3])))
                }
            } else if cards.isEmpty {
                Color.clear.frame(height: 44)
            }
        }
        .padding(4)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 12).fill(target ? Theme.accentSoft : .clear))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(target ? Theme.accent : .clear, lineWidth: 1.5))
        .contentShape(Rectangle())
        .onHover { on in withAnimation(Theme.motion) { hover = on } }
        .dropDestination(for: String.self) { ids, _ in
            guard let id = ids.first else { return false }
            place(id, date, nil)
            return true
        } isTargeted: { on in withAnimation(Theme.motion) { target = on } }
    }
}

/// A planned video: its picture and title. Click opens the session; drag it to another day.
struct PlanCard: View {
    let card: ConsistencyStats.Card
    let open: (URL) -> Void
    let remove: (String) -> Void
    /// A card dropped on this one goes before it.
    let before: (String) -> Void
    @State private var image: NSImage?
    @State private var hover = false
    @State private var target = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ZStack {
                RoundedRectangle(cornerRadius: 7).fill(Theme.hover)
                if let image {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: "film").font(.system(size: 14)).foregroundStyle(Theme.faint)
                }
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 7))
            Text(card.title).font(Theme.sans(11.5, .semibold)).foregroundStyle(Theme.ink)
                .lineLimit(2).multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            switch card.status {
            case .posted:
                Label("Posted", systemImage: "checkmark.circle.fill").font(Theme.sans(10.5, .semibold)).foregroundStyle(Theme.live)
            case .scheduled(let at):
                Label("Scheduled \(at.formatted(date: .omitted, time: .shortened))", systemImage: "clock")
                    .font(Theme.sans(10.5, .medium)).foregroundStyle(Theme.accentInk)
            case nil:
                if card.late { Text("planned earlier").font(Theme.sans(10)).foregroundStyle(Theme.faint) }
            }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 10).fill(hover ? Theme.hover : card.status == .posted ? Theme.liveSoft : Theme.canvas))
        .overlay(alignment: .top) {
            if target { Capsule().fill(Theme.accent).frame(height: 3).offset(y: -5) }
        }
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.border))
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .onHover { hover = $0 }
        .animation(Theme.motion, value: hover)
        .onTapGesture { open(card.url) }
        .draggable(card.id) {
            Text(card.title).font(Theme.sans(12, .semibold)).padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.canvas))
        }
        .dropDestination(for: String.self) { ids, _ in
            guard let id = ids.first else { return false }
            before(id)
            return true
        } isTargeted: { on in withAnimation(Theme.motion) { target = on } }
        .contextMenu {
            Button("Open") { open(card.url) }
            Button("Take off the plan") { remove(card.id) }
        }
        .help("\(card.title). Click to open, drag to another day.")
        .task(id: card.poster) {
            guard let p = card.poster else { image = nil; return }
            image = StoryShot.cachedPoster(p)
            if image == nil { image = await StoryShot.poster(p) }
        }
    }
}

/// A session the user can put on the plan: "Project/folder", its title and project.
struct PlanChoice: Identifiable, Hashable {
    let id: String
    let title: String
    let project: String
    let createdAt: Date
    let done: Bool

    /// Every session, open ones first, newest first.
    @MainActor static func all(_ library: Library) -> [PlanChoice] {
        library.grouped.flatMap { project, sessions in
            sessions.map { s in
                PlanChoice(id: project.lastPathComponent + "/" + s.url.lastPathComponent, title: s.title,
                           project: project.lastPathComponent, createdAt: s.createdAt, done: s.done)
            }
        }
        .sorted { a, b in a.done != b.done ? !a.done : a.createdAt > b.createdAt }
    }

    static func matching(_ list: [PlanChoice], _ query: String) -> [PlanChoice] {
        let words = query.lowercased().split(separator: " ")
        guard !words.isEmpty else { return list }
        return list.filter { c in
            let text = (c.title + " " + c.project).lowercased()
            return words.allSatisfy { text.contains($0) }
        }
    }
}

/// A day's +: search the sessions, click one to put it on the day.
struct PlanPicker: View {
    let choices: [PlanChoice]
    /// Already on this day: shown with a check.
    let planned: Set<String>
    let pick: (String) -> Void
    @State private var query = ""
    @FocusState private var focused: Bool

    var body: some View {
        let list = PlanChoice.matching(choices, query)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Theme.faint)
                TextField("Find a video", text: $query).textFieldStyle(.plain).font(Theme.sans(12.5))
                    .focused($focused)
                    .onSubmit { if let c = list.first { pick(c.id) } }
            }
            .padding(.horizontal, 10).frame(height: 28)
            .background(Theme.paper, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.border, lineWidth: 0.5))
            if list.isEmpty {
                Text(choices.isEmpty ? "No sessions yet." : "No video matches.")
                    .font(Theme.sans(12)).foregroundStyle(Theme.faint).padding(8)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(list.prefix(200)) { c in
                            PlanPickerRow(choice: c, planned: planned.contains(c.id)) { pick(c.id) }
                        }
                    }
                }
                .frame(maxHeight: 320)
            }
        }
        .padding(12)
        .frame(width: 300)
        .onAppear { focused = true }
    }
}

private struct PlanPickerRow: View {
    let choice: PlanChoice
    let planned: Bool
    let tap: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: tap) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(choice.title).font(Theme.sans(12.5, .medium)).foregroundStyle(Theme.ink).lineLimit(1)
                    Text(choice.project + (choice.done ? " · done" : ""))
                        .font(Theme.sans(10.5)).foregroundStyle(Theme.faint).lineLimit(1)
                }
                Spacer(minLength: 0)
                if planned { Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.accent) }
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(hover ? Theme.hover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}
