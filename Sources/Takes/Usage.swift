import AppKit
import SwiftUI

/// Anonymous usage counts (2026-10-10), off until the user says yes. A Takes from a release asks
/// once, 20 minutes after its first launch with this code (never over the welcome or a recording);
/// Settings › Usage turns it on or off later. When on, it sends one report a day to
/// gettakes.app/ping: a random ID made only for this, the versions and counts of the library.
/// The report has no field for text: chats with the agent, scripts, titles, file names, post text
/// and keys can never go in it. The site keeps only these fields (gettakes-site functions/ping.js).
@MainActor @Observable
final class Usage {
    static let shared = Usage()
    static let answerKey = "usageAnswer"   // "yes", "no", or nothing: not asked yet
    static let idKey = "usageID"
    static let firstKey = "usageFirstSeen"
    static let sentKey = "usageSent"       // the UTC day of the last report, YYYY-MM-DD
    static let reportKey = "usageLastReport"
    static var endpoint = URL(string: "https://gettakes.app/ping")!
    static let askAfter: TimeInterval = 20 * 60

    /// The ask card is on screen.
    var asking = false
    private(set) var on = UserDefaults.standard.string(forKey: answerKey) == "yes"
    @ObservationIgnored private weak var library: Library?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var sending = false

    /// Only a Takes from a release sends. A build from source never does.
    static var release: String? { Bundle.main.infoDictionary?["ReleaseTag"] as? String }

    struct Counts: Codable, Equatable {
        var projects = 0, sessions = 0, takes = 0, edits = 0, storyboards = 0
        var posts_ready = 0, posts_scheduled = 0, posts_posted = 0, published = 0
        /// 1 when an iPhone used Takes on this Mac in the last 7 days.
        var phone = 0
    }

    /// Everything one report holds. Numbers, versions and plugin ids: nothing a person wrote.
    struct Report: Codable, Equatable {
        var id: String
        var v: String
        var os: String
        var counts: Counts
        var plugins: [String]
    }

    func start(_ library: Library) {
        self.library = library
        guard timer == nil, Self.release != nil else { return }
        let d = UserDefaults.standard
        if d.object(forKey: Self.firstKey) == nil { d.set(Date(), forKey: Self.firstKey) }
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { _ in
            MainActor.assumeIsolated { Usage.shared.tick() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 120) { Usage.shared.tick() }
    }

    func tick() {
        let d = UserDefaults.standard
        if d.string(forKey: Self.answerKey) == nil, !asking, Self.release != nil,
           let first = d.object(forKey: Self.firstKey) as? Date, -first.timeIntervalSinceNow > Self.askAfter,
           d.bool(forKey: Onboarding.doneKey), !Onboarding.shared.shown, !FirstTake.shared.shown,
           library?.isRecording != true {
            withAnimation(Theme.spring) { asking = true }
        }
        sendIfDue()
    }

    func answer(_ yes: Bool) {
        UserDefaults.standard.set(yes ? "yes" : "no", forKey: Self.answerKey)
        withAnimation(Theme.spring) { on = yes; asking = false }
        if yes { sendIfDue() }
    }

    static var id: String {
        let d = UserDefaults.standard
        if let id = d.string(forKey: idKey) { return id }
        let id = UUID().uuidString
        d.set(id, forKey: idKey)
        return id
    }

    nonisolated static func today(_ now: Date = Date()) -> String { String(ISO8601DateFormatter().string(from: now).prefix(10)) }

    /// The last report sent, as it went out.
    static var lastSent: (day: String, json: String)? {
        let d = UserDefaults.standard
        guard let day = d.string(forKey: sentKey), let json = d.string(forKey: reportKey) else { return nil }
        return (day, json)
    }

    private func sendIfDue() {
        guard on, !sending, Self.release != nil, let library,
              UserDefaults.standard.string(forKey: Self.sentKey) != Self.today() else { return }
        sending = true
        let job = reportJob(library)
        Task {
            defer { sending = false }
            let report = await Task.detached(priority: .utility) { job() }.value
            guard let body = try? Self.encode(report) else { return }
            var req = URLRequest(url: Self.endpoint)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = body
            guard let (_, resp) = try? await URLSession.shared.data(for: req),
                  (resp as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) == true else { return }
            UserDefaults.standard.set(Self.today(), forKey: Self.sentKey)
            UserDefaults.standard.set(String(decoding: body, as: UTF8.self), forKey: Self.reportKey)
        }
    }

    static func encode(_ r: Report) throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try e.encode(r)
    }

    /// Today's report for this library. The "See the exact report" button shows the same value.
    func report(_ library: Library) -> Report {
        reportJob(library)()
    }

    /// The report's inputs from the library, read on main; the returned job reads the disk (every
    /// edits folder and post), so a view runs it off main.
    func reportJob(_ library: Library) -> @Sendable () -> Report {
        let sessions = library.projects.flatMap { library.grouped[$0.url] ?? [] }.map { ($0.url, $0.takeCount, $0.published) }
        let v = ProcessInfo.processInfo.operatingSystemVersion
        let id = Self.id, version = Self.release ?? "source", root = library.root, projects = library.projects.count
        let plugins = Plugins.all.map(\.id), phone = PhoneServer.usedRecently()
        return {
            Self.report(id: id, version: version, os: "\(v.majorVersion).\(v.minorVersion)", root: root, projects: projects,
                        sessions: sessions, plugins: plugins, phone: phone)
        }
    }

    nonisolated static func report(id: String, version: String, os: String, root: URL, projects: Int,
                                   sessions: [(url: URL, takes: Int, published: Bool)],
                                   plugins: [String], phone: Bool) -> Report {
        let fm = FileManager.default
        var c = Counts(projects: projects, sessions: sessions.count)
        for s in sessions {
            c.takes += s.takes
            if s.published { c.published += 1 }
            let edits = (try? fm.contentsOfDirectory(atPath: s.url.appending(path: "edits").path)) ?? []
            c.edits += edits.filter { ["mp4", "mov", "m4v"].contains(($0 as NSString).pathExtension.lowercased()) }.count
            if fm.fileExists(atPath: Storyboard.file(s.url).path) { c.storyboards += 1 }
        }
        for p in PostQueue.read(root) {
            switch p.content.status {
            case .ready: c.posts_ready += 1
            case .scheduled: c.posts_scheduled += 1
            case .posted: c.posts_posted += 1
            case .draft: break
            }
        }
        c.phone = phone ? 1 : 0
        return Report(id: id, v: version, os: os, counts: c, plugins: plugins.sorted())
    }
}

// MARK: - The ask

/// What the report never holds, first and largest: the chats with the agent.
enum UsageCopy {
    static let neverTitle = "Your chats with Takes are never sent."
    static let neverDetail = "No chat history, prompts or replies. No scripts, video titles, file names, post text or keys. They stay on your Mac."
    static let sent: [(icon: String, text: String)] = [
        ("number", "How many takes, edits and storyboards"),
        ("paperplane", "How many posts are ready, scheduled or posted"),
        ("puzzlepiece.extension", "Which plugins are on"),
        ("iphone", "If you use Takes on an iPhone"),
        ("app.badge", "The Takes and macOS versions"),
        ("dice", "A random ID made only for this"),
    ]
}

/// The green panel: a shield and the promise, in the ask and in Settings.
struct UsageNeverPanel: View {
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                Circle().fill(Theme.live.opacity(0.14)).frame(width: 48, height: 48)
                Image(systemName: "checkmark.shield.fill")
                    .font(.system(size: 22, weight: .semibold)).foregroundStyle(Theme.live)
            }
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(UsageCopy.neverTitle).font(Theme.sans(15, .semibold)).foregroundStyle(Theme.ink)
                Text(UsageCopy.neverDetail).font(Theme.sans(12.5)).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.live.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.live.opacity(0.35)))
    }
}

/// What a report holds, as a quiet list of checks.
struct UsageSentList: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("WHAT IS SENT, ONCE A DAY").font(Theme.sans(10.5, .semibold)).tracking(0.6).foregroundStyle(Theme.faint)
            LazyVGrid(columns: [GridItem(.flexible(), alignment: .topLeading), GridItem(.flexible(), alignment: .topLeading)],
                      alignment: .leading, spacing: 8) {
                ForEach(UsageCopy.sent, id: \.text) { item in
                    HStack(alignment: .top, spacing: 7) {
                        Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.live)
                            .frame(width: 14).padding(.top, 2)
                        Text(item.text).font(Theme.sans(12.5)).foregroundStyle(Theme.ink)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }
}

/// The exact report, as it would go out now.
/// Today's report, worked out off main once it shows. It read every post file in body, on each
/// redraw (2026-10-11).
struct UsageReportLive: View {
    let library: Library
    @State private var json = ""

    var body: some View {
        UsageReportText(json: json)
            .task {
                let job = Usage.shared.reportJob(library)
                let r = await Task.detached(priority: .userInitiated) { job() }.value
                json = (try? Usage.encode(r)).map { String(decoding: $0, as: UTF8.self) } ?? ""
            }
    }
}

struct UsageReportText: View {
    let json: String

    var body: some View {
        ScrollView {
            Text(json).font(Theme.mono(11)).foregroundStyle(Theme.muted).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading).padding(12)
        }
        .frame(maxHeight: 170)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.hover))
    }
}

/// The dim layer and the card, over the whole window (like OnboardingLayer).
struct UsageAskLayer: View {
    var usage = Usage.shared

    var body: some View {
        ZStack {
            if usage.asking {
                Theme.canvas.opacity(0.9).ignoresSafeArea()
                    .contentShape(Rectangle()).onTapGesture {}
                    .transition(.opacity)
                UsageAskCard(usage: usage)
                    .transition(.scale(scale: 0.96).combined(with: .opacity))
            }
        }
        .animation(Theme.spring, value: usage.asking)
    }
}

/// Short and friendly: a wave, one line, the chats promise, two buttons.
/// The full list and the exact report wait behind "What's shared?".
struct UsageAskCard: View {
    @Environment(AppModel.self) var app
    var usage: Usage
    @State var showDetails = false
    @State private var showReport = false

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 16) {
                ZStack {
                    Circle().fill(Theme.accent.opacity(0.14)).frame(width: 64, height: 64)
                    Image(systemName: "hand.wave.fill")
                        .font(.system(size: 28, weight: .semibold)).foregroundStyle(Theme.accent)
                        .rotationEffect(.degrees(-12))
                }
                .accessibilityHidden(true)
                VStack(spacing: 6) {
                    Text("Help make Takes better?").font(Theme.display(22)).foregroundStyle(Theme.ink)
                    Text("Share a few anonymous counts once a day. You can turn it off any time.")
                        .font(Theme.sans(13.5)).foregroundStyle(Theme.muted)
                        .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                }
                if !showDetails {
                    HStack(spacing: 7) {
                        Image(systemName: "checkmark.shield.fill").font(.system(size: 13, weight: .semibold))
                        Text("Your chats never leave your Mac").font(Theme.sans(12.5, .semibold))
                    }
                    .foregroundStyle(Theme.live)
                    .padding(.horizontal, 12).frame(height: 30)
                    .background(Capsule().fill(Theme.live.opacity(0.12)))
                    .transition(.opacity)
                } else {
                    VStack(alignment: .leading, spacing: 16) {
                        UsageNeverPanel()
                        UsageSentList()
                        Button {
                            withAnimation(Theme.motion) { showReport.toggle() }
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold))
                                    .rotationEffect(.degrees(showReport ? 90 : 0))
                                Text(showReport ? "Hide the report" : "See the exact report")
                            }
                        }
                        .buttonStyle(BracketButtonStyle())
                        if showReport {
                            UsageReportLive(library: app.library)
                                .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                    }
                    .padding(.top, 4)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .padding(.horizontal, 32).padding(.top, 32).padding(.bottom, 24)

            VStack(spacing: 12) {
                HStack(spacing: 10) {
                    Button("No thanks") { usage.answer(false) }
                        .buttonStyle(AccentButtonStyle(kind: .quiet))
                    Button("Share counts") { usage.answer(true) }
                        .buttonStyle(AccentButtonStyle(kind: .accent))
                }
                Button {
                    withAnimation(Theme.motion) { showDetails.toggle() }
                } label: {
                    Text(showDetails ? "Show less" : "What's shared?")
                        .font(Theme.sans(12)).foregroundStyle(Theme.faint).underline()
                }
                .buttonStyle(.plain)
            }
            .padding(.bottom, 24)
        }
        .frame(width: showDetails ? 520 : 420)
        .background(Theme.paper)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(Theme.border))
        .shadow(color: .black.opacity(0.3), radius: 40, y: 18)
        .onExitCommand { usage.answer(false) }
    }
}

// MARK: - Settings › Usage

struct UsagePage: View {
    @Environment(AppModel.self) var app
    var usage = Usage.shared
    @State private var showReport = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Usage counts").font(Theme.display(17)).foregroundStyle(Theme.ink)
                    Text(Usage.release == nil
                         ? "This Takes is built from source, so it never sends anything."
                         : "Anonymous counts, once a day, to gettakes.app. Off unless you turn it on.")
                        .font(Theme.sans(12)).foregroundStyle(Theme.muted)
                }
                Spacer()
                if Usage.release != nil {
                    RuleSwitch(on: usage.on) { usage.answer(!usage.on) }
                        .help(usage.on ? "Stop sending counts" : "Send counts once a day")
                }
            }
            .padding(20)
            Rule()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    UsageNeverPanel()
                    UsageSentList()
                    VStack(alignment: .leading, spacing: 8) {
                        Button {
                            withAnimation(Theme.motion) { showReport.toggle() }
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold))
                                    .rotationEffect(.degrees(showReport ? 90 : 0))
                                Text(showReport ? "Hide the report" : "See the exact report")
                            }
                        }
                        .buttonStyle(BracketButtonStyle())
                        if showReport {
                            if let last = Usage.lastSent {
                                Text("Last sent on \(last.day) (UTC):").font(Theme.sans(11.5)).foregroundStyle(Theme.faint)
                                UsageReportText(json: last.json)
                            } else {
                                Text("Nothing sent yet. Today's report would be:").font(Theme.sans(11.5)).foregroundStyle(Theme.faint)
                                UsageReportLive(library: app.library)
                            }
                        }
                    }
                    Link("Privacy at gettakes.app/privacy", destination: URL(string: "https://gettakes.app/privacy")!)
                        .font(Theme.sans(12)).foregroundStyle(Theme.accentInk)
                }
                .padding(20)
            }
        }
    }
}
