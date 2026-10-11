import AppKit
import SwiftUI

// Long jobs (2026-10-10). A render, Demucs, Whisper or matting ran as a background Bash job in the
// chat, and it died when the chat's process ended (a steer, a Stop, a compaction, a quit). The takes
// MCP's run_job now starts it in a runner outside the chat's process tree. This file shows those
// jobs in the session's Jobs row and tells the chat when one ends, so it goes on by itself.
//
// Same files and the same lost rule as the jobs section of mcp/takes_mcp.py:
//   <session>/.jobs/<id>.json      the job (the MCP and its runner write it; the app never does)
//   <session>/.jobs/<id>.lock      exists only while its runner holds it (flock)
//   <session>/.jobs/<id>.told      the chat knows the job ended (O_EXCL: one side tells)
//   <session>/.jobs/<id>.stop      who asked to stop: "you" (this app) or "takes" (stop_job)
//   <session>/.jobs/<id>.partial/  what a failed or stopped job wrote, out of the session
// Higgsfield and Replicate clips (<session>/generated/.jobs) show in the same row, without Stop.

extension Notification.Name {
    /// `object`: the session folder (URL) whose jobs changed. FileWatch sends it, never
    /// `takesFilesChanged`: a job writes its file every 2 s, and the panes must not read the disk again.
    static let takesJobsChanged = Notification.Name("de.marvinaziz.takes.jobsChanged")
    /// `object`: the session folder (URL) whose chat ended a run and has nothing waiting.
    static let takesChatIdle = Notification.Name("de.marvinaziz.takes.chatIdle")
}

enum JobStatus: String {
    case starting, running, done, failed, stopped, lost
    var live: Bool { self == .starting || self == .running }
}

struct Job: Identifiable, Hashable {
    var id: String
    var label: String
    var outputs: [String]
    var fromChat: Bool
    var status: JobStatus
    var started: Date?
    var ended: Date?
    var pid: Int32?
    var progress: Double?
    var eta: Double?
    var error: String?
    var stoppedBy: String?
    /// A Higgsfield or Replicate clip. The folder decides it, never the file's own "kind".
    var isGenerate: Bool
    /// The store: <session>/.jobs or <session>/generated/.jobs.
    var folder: URL
    /// What the job does now, in a few words ("Mixing the sound"), when its command says (TAKES_STAGE).
    var stage: String? = nil

    /// The session folder the job file is in now.
    var session: URL { (isGenerate ? folder.deletingLastPathComponent().deletingLastPathComponent() : folder.deletingLastPathComponent()).standardizedFileURL }
    /// Unique across runs: legacy ids such as shot-3-v2 come back after a delete.
    var key: String { "\(session.lastPathComponent)/\(id)@\(Int(started?.timeIntervalSince1970 ?? 0))" }
    func file(_ ext: String) -> URL { folder.appending(path: id + ext) }
    var stoppable: Bool { !isGenerate }

    /// The row's icon, from the first output's kind.
    var icon: String {
        if isGenerate { return "sparkles" }
        guard let first = outputs.first else { return "gearshape" }
        switch (first as NSString).pathExtension.lowercased() {
        case "mp4", "mov", "m4v", "webm": return "film"
        case "wav", "mp3", "m4a", "aac", "flac", "aiff": return "waveform"
        case "srt", "vtt", "txt", "json": return "text.quote"
        case "png", "jpg", "jpeg", "gif", "webp", "heic", "svg": return "photo"
        default: return "doc"
        }
    }

    nonisolated(unsafe) private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// Tolerant: unknown keys are ignored, a legacy "error" status reads as failed, a missing label
    /// reads as the file name. Nil for a file that does not parse (the board skips it).
    static func decode(_ data: Data, folder: URL, generate: Bool) -> Job? {
        guard let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = d["id"] as? String, !id.isEmpty else { return nil }
        let raw = d["status"] as? String ?? ""
        let status = raw == "error" ? .failed : JobStatus(rawValue: raw) ?? .failed
        var outputs = (d["outputs"] as? [String]) ?? []
        if generate, let f = d["file"] as? String { outputs = [f] }
        let fallback = generate ? ((outputs.first ?? id) as NSString).lastPathComponent : id
        let label = (d["label"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? (generate ? (fallback as NSString).deletingPathExtension : fallback)
        func date(_ k: String) -> Date? { (d[k] as? String).flatMap { iso.date(from: $0) } }
        func number(_ k: String) -> Double? { (d[k] as? NSNumber)?.doubleValue }
        return Job(id: id, label: label, outputs: outputs, fromChat: d["from_chat"] as? Bool ?? false, status: status,
                   started: date("started"), ended: date("ended"), pid: number("pid").map { Int32($0) },
                   progress: number("progress"), eta: number("eta_s"), error: d["error"] as? String,
                   stoppedBy: d["stopped_by"] as? String, isGenerate: generate, folder: folder,
                   stage: (d["stage"] as? String).flatMap { $0.isEmpty ? nil : $0 })
    }
}

@MainActor
@Observable
final class JobBoard {
    /// Every session with jobs, by its folder.
    private(set) var bySession: [URL: [Job]] = [:]
    /// Done rows the user saw and rows he closed, by job key. Kept (the newest 200) through a quit.
    private(set) var seenKeys: Set<String>
    private(set) var dismissedKeys: Set<String>

    /// The chat to tell about a job: the session's chat if it is open or has a log, else nil.
    @ObservationIgnored var chatFor: @MainActor (URL) -> ClaudeChat? = { _ in nil }
    @ObservationIgnored private let defaults: UserDefaults
    /// Ended jobs that wait for the user's next message instead of waking the chat by themselves.
    @ObservationIgnored private var held: [URL: Set<String>] = [:]
    /// Failed jobs whose note went to the chat by itself ("Takes is on it.").
    private(set) var woken: Set<String> = []
    /// Failed jobs held over the cap ("did not finish again").
    private(set) var capped: Set<String> = []
    /// Ends whose files were announced (takesFilesChanged), so Assets shows a new file once.
    @ObservationIgnored private var announced: Set<String> = []
    @ObservationIgnored private var doneWakes: [URL: [Date]] = [:]
    @ObservationIgnored private var failedRow: [URL: Int] = [:]
    @ObservationIgnored private var timer: Timer?

    /// Wake caps per session: done notes per hour, failed notes in a row without a message from the user.
    static let doneCap = 5
    static let failedCap = 2

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        seenKeys = Set(defaults.stringArray(forKey: "jobs.seen") ?? [])
        dismissedKeys = Set(defaults.stringArray(forKey: "jobs.dismissed") ?? [])
    }

    // MARK: Reading

    /// Every job of a session, both stores, oldest first, with the lost rule applied.
    nonisolated static func load(_ session: URL, now: Date = Date()) -> [Job] {
        let fm = FileManager.default
        var out: [Job] = []
        for (folder, generate) in [(session.appending(path: ".jobs"), false), (session.appending(path: "generated/.jobs"), true)] {
            let files = (try? fm.contentsOfDirectory(atPath: folder.path)) ?? []
            for f in files where f.hasSuffix(".json") {
                let url = folder.appending(path: f)
                guard let data = try? Data(contentsOf: url), var job = Job.decode(data, folder: folder, generate: generate) else { continue }
                if lost(job, now: now) {
                    // Read again: a runner that ended between the read and the lock check wrote its end first.
                    if let again = (try? Data(contentsOf: url)).flatMap({ Job.decode($0, folder: folder, generate: generate) }) { job = again }
                    if lost(job, now: now) { job.status = .lost }
                }
                out.append(job)
            }
        }
        return out.sorted { ($0.started ?? .distantPast) < ($1.started ?? .distantPast) }
    }

    /// The runner is gone though the file says it runs. Same rule as job_lost in takes_mcp.py.
    nonisolated static func lost(_ job: Job, now: Date = Date()) -> Bool {
        guard job.status.live else { return false }
        let lock = job.file(".lock")
        if lockHeld(lock) { return false }
        let age = job.started.map { now.timeIntervalSince($0) }
        if job.isGenerate {
            // A free lock file: its runner died. No lock file: a job from before 2026-10-10.
            return FileManager.default.fileExists(atPath: lock.path) || (age ?? 0) > 90 * 60
        }
        return job.status == .running || age == nil || age! > 30
    }

    /// O_CLOEXEC: a chat or ffmpeg the app starts in the same moment must not get a copy of the
    /// fd. A copy keeps the lock it takes, and the job's runner could never lock it (2026-10-11).
    nonisolated static func lockHeld(_ url: URL) -> Bool {
        let fd = open(url.path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        return flock(fd, LOCK_SH | LOCK_NB) != 0
    }

    /// Makes the .told file. True when this call made it: then this side tells the chat.
    nonisolated static func claimTold(_ url: URL) -> Bool {
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL, 0o644)
        guard fd >= 0 else { return false }
        close(fd)
        return true
    }

    /// At launch: every session with jobs. Jobs that ended while Takes was closed wait for the user's
    /// next message; nothing wakes a chat here.
    func scan(root: URL) {
        let fm = FileManager.default
        var found: [URL: [Job]] = [:]
        let projects = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
        for p in projects {
            for s in (try? fm.contentsOfDirectory(at: p, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
            where fm.fileExists(atPath: s.appending(path: ".jobs").path) || fm.fileExists(atPath: s.appending(path: "generated/.jobs").path) {
                let jobs = Self.load(s)
                if !jobs.isEmpty { found[s.standardizedFileURL] = jobs }
            }
        }
        bySession = found
        for (s, jobs) in found {
            for j in jobs where !j.status.live { announced.insert(j.key) }
            held[s, default: []].formUnion(jobs.filter(Self.toTell).map(\.key))
        }
        tick()
    }

    /// A job file of this session changed.
    func reload(_ session: URL) {
        let s = session.standardizedFileURL
        let jobs = Self.load(s)
        bySession[s] = jobs.isEmpty ? nil : jobs
        // An end shows its files on Assets at once: the job folder itself sends no file change.
        var folders: Set<String> = []
        for j in jobs where !j.status.live && !announced.contains(j.key) {
            announced.insert(j.key)
            for o in j.outputs { folders.insert(s.appending(path: o).deletingLastPathComponent().path) }
        }
        if !folders.isEmpty { NotificationCenter.default.post(name: .takesFilesChanged, object: Array(folders)) }
        tell(s)
        tick()
    }

    /// While a job runs, look again every 5 s: a runner that died writes nothing, and a job that
    /// is "starting" too long reads lost only by the clock.
    private func tick() {
        let live = bySession.contains { $0.value.contains { $0.status.live } }
        if live, timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    for (s, jobs) in self.bySession where jobs.contains(where: { $0.status.live }) { self.reload(s) }
                }
            }
            timer?.tolerance = 1
        } else if !live {
            timer?.invalidate()
            timer = nil
        }
    }

    // MARK: Telling the chat

    /// An end the chat should hear about: it started the job, it ended in the last day, and not by
    /// The user's Stop. A lost job is never told by itself.
    nonisolated static func toTell(_ j: Job) -> Bool {
        (j.status == .done || j.status == .failed) && j.fromChat && j.stoppedBy != "you"
            && (j.ended.map { -$0.timeIntervalSinceNow < 86400 } ?? false)
    }

    /// Sends the session's new ends to its chat when it is idle; else holds them.
    func tell(_ session: URL) {
        let s = session.standardizedFileURL
        let jobs = (bySession[s] ?? []).filter {
            Self.toTell($0) && !(held[s]?.contains($0.key) ?? false) && !FileManager.default.fileExists(atPath: $0.file(".told").path)
        }
        guard !jobs.isEmpty else { return }
        guard let chat = chatFor(s) else { hold(jobs, s); return }
        if chat.running || !chat.queued.isEmpty { return }  // .takesChatIdle comes when it is done
        // The user stopped the chat, or it waits to go on after a lost connection: his next message takes them.
        if chat.stoppedByYou || chat.reconnecting { hold(jobs, s); return }
        var send: [Job] = []
        for j in jobs {
            if j.status == .done {
                let recent = (doneWakes[s] ?? []).filter { -$0.timeIntervalSinceNow < 3600 }
                if recent.count >= Self.doneCap { doneWakes[s] = recent; hold([j], s); continue }
                doneWakes[s] = recent + [Date()]
            } else {
                if failedRow[s, default: 0] >= Self.failedCap { capped.insert(j.key); hold([j], s); continue }
                failedRow[s, default: 0] += 1
            }
            if Self.claimTold(j.file(".told")) { send.append(j) }
        }
        guard !send.isEmpty else { return }
        woken.formUnion(send.filter { $0.status == .failed }.map(\.key))
        chat.send(Self.note(for: send), title: Self.title(s), onStage: nil, notes: send.map(Self.tick))
    }

    private func hold(_ jobs: [Job], _ s: URL) { held[s, default: []].formUnion(jobs.map(\.key)) }

    /// The chat of this session went idle.
    func chatIdle(_ session: URL) { tell(session) }

    /// The user sends a message: the held notes go in front of it, and the caps start over.
    /// Nil when nothing waits.
    func takeHeld(_ session: URL) -> (text: String, lines: [ChatMessage])? {
        let s = session.standardizedFileURL
        doneWakes[s] = nil
        failedRow[s] = nil
        capped.subtract((bySession[s] ?? []).map(\.key))
        guard let keys = held[s], !keys.isEmpty else { return nil }
        held[s] = nil
        let jobs = (bySession[s] ?? []).filter { keys.contains($0.key) && Self.toTell($0) && Self.claimTold($0.file(".told")) }
        guard !jobs.isEmpty else { return nil }
        woken.formUnion(jobs.filter { $0.status == .failed }.map(\.key))  // the chat has it now
        return (Self.note(for: jobs), jobs.map(Self.tick))
    }

    /// "Ask Takes" and "Run again": the job's note goes out as the user's own message.
    func ask(_ job: Job) {
        let s = job.session
        held[s]?.remove(job.key)
        _ = Self.claimTold(job.file(".told"))
        if job.status == .failed { woken.insert(job.key) }
        guard let chat = chatFor(s) else { return }
        chat.send(Self.note(for: [job]), title: Self.title(s), onStage: nil)
    }

    nonisolated static func title(_ s: URL) -> String { Store.readMeta(s)?.title ?? s.lastPathComponent }

    /// The text the chat gets (one line per job).
    nonisolated static func note(for jobs: [Job]) -> String {
        jobs.map { j in
            let took = j.started.map { duration((j.ended ?? Date()).timeIntervalSince($0)) }
            // render_edit's renders: the next step is publish_edit, or render_edit again (2026-10-11).
            let render = j.outputs.first?.hasPrefix("_edit/renders/") == true
            switch j.status {
            case .done where render:
                return "[Takes] Job \(j.id) ended: \(j.label) is rendered and checked\(took.map { " after \($0)" } ?? ""). "
                    + "get_job id=\(j.id) has the checks. Look at 3 to 5 frames, then publish_edit render=\(j.id)."
            case .lost where render:
                return "[Takes] Job \(j.id) stopped: \(j.label) did not finish, because the Mac restarted or the job quit. "
                    + "Call render_edit again with the same base and changes."
            case .done:
                let wrote = j.outputs.isEmpty ? "" : " It wrote \(j.outputs.joined(separator: ", "))."
                return "[Takes] Job \(j.id) ended: \(j.label) is done\(took.map { " after \($0)" } ?? "").\(wrote) "
                    + "Go on with the next step you planned. If nothing is left, tell the user in one line."
            case .lost:
                return "[Takes] Job \(j.id) stopped: \(j.label) did not finish, because the Mac restarted or the job quit. "
                    + "get_job id=\(j.id) gives its command: run it again with run_job and new outputs from next_path."
            default:
                let why = j.error.map { ": \($0)" } ?? ""
                return "[Takes] Job \(j.id) failed\(took.map { " after \($0)" } ?? "")\(why). get_job id=\(j.id) has the log. "
                    + "Fix it and run it again, or tell the user in one line what went wrong."
            }
        }.joined(separator: "\n")
    }

    /// The panel's line for a told job: a tick line of its own, never folded into "N steps".
    nonisolated static func tick(_ j: Job) -> ChatMessage {
        let text = switch j.status {
        case .done: "\(j.label) is done"
        case .lost, .stopped: "\(j.label) stopped"
        default: "\(j.label) did not finish"
        }
        return ChatMessage(role: .tool, text: text, toolID: ChatMessage.jobNote)
    }

    /// "45 s", "3 min 32 s".
    nonisolated static func duration(_ s: Double) -> String {
        let n = max(0, Int(s.rounded()))
        return n < 60 ? "\(n) s" : n % 60 == 0 ? "\(n / 60) min" : "\(n / 60) min \(n % 60) s"
    }

    // MARK: The row

    /// The rows the session shows now.
    func visible(_ session: URL, now: Date = Date()) -> [Job] {
        (bySession[session.standardizedFileURL] ?? []).filter { j in
            if dismissedKeys.contains(j.key) { return false }
            let end = j.ended ?? j.started ?? now
            switch j.status {
            case .starting, .running: return true
            case .done: return !seenKeys.contains(j.key) && now.timeIntervalSince(end) < 86400
            case .failed, .lost: return now.timeIntervalSince(end) < 86400
            case .stopped: return now.timeIntervalSince(end) < 5
            }
        }
    }

    /// The chat's row (2026-10-11: a row for every end was noise beside the chat's own words).
    /// It shows what runs, and an end the chat never hears about: a lost job, or one the chat did
    /// not start. A done or failed job of the chat's own goes there as a message instead.
    func row(_ session: URL, now: Date = Date()) -> [Job] {
        visible(session, now: now).filter { j in
            j.status.live || ((j.status == .failed || j.status == .lost) && !Self.toTell(j))
        }
    }

    /// A job runs in this session (the sidebar's ring).
    func running(_ session: URL) -> Bool { (bySession[session.standardizedFileURL] ?? []).contains { $0.status.live } }

    /// What the closed chat's pill shows: a job that runs, else a result the user has not seen.
    func pill(_ session: URL) -> Job? {
        let v = visible(session)
        return v.last { $0.status.live } ?? v.last { $0.status == .done }
    }

    /// What the row says on the right. Copy in the jobs plan (Simplified Technical English).
    nonisolated static func line(_ j: Job, woken: Bool = false, again: Bool = false, now: Date = Date()) -> String {
        let elapsed = j.started.map { now.timeIntervalSince($0) } ?? 0
        let minutes = elapsed < 60 ? "Just started" : "\(Int(elapsed / 60)) min"
        switch j.status {
        case .starting: return "Just started"
        case .running where j.isGenerate: return elapsed < 60 ? "Making the clip" : "Making the clip · \(Int(elapsed / 60)) min"
        case .running:
            let step = j.stage.map { "\($0) · " } ?? ""
            guard let p = j.progress, p > 0 else { return j.stage.map { elapsed < 60 ? $0 : "\($0) · \(minutes)" } ?? minutes }
            let pct = "\(step)\(Int((p * 100).rounded()))%"
            guard let eta = j.eta else { return pct }
            return eta < 60 ? "\(pct) · less than a minute left" : "\(pct) · about \(Int((eta / 60).rounded())) min left"
        case .done: return j.stage.flatMap { $0.hasPrefix("Ready") ? $0 : nil } ?? "Ready"
        case .failed:
            return woken ? "\(j.label) did not finish. Takes is on it."
                : again ? "\(j.label) did not finish again." : "\(j.label) did not finish."
        case .lost: return "\(j.label) stopped. The Mac restarted or the job quit."
        case .stopped: return j.stoppedBy == "takes" ? "Takes stopped it" : "You stopped it"
        }
    }

    /// Stop from the row: the runner ends the command and all it started.
    func stop(_ job: Job) {
        guard job.stoppable else { return }
        try? Data("you".utf8).write(to: job.file(".stop"), options: .atomic)
        if let pid = job.pid, Self.lockHeld(job.file(".lock")) { kill(pid, SIGTERM) }
    }

    /// Show, or the file opened: the done row goes.
    func seen(_ job: Job) {
        seenKeys.insert(job.key)
        keep(seenKeys, "jobs.seen")
    }

    /// × on a row: it goes, and so do the files a failed job left in its partial folder.
    func dismiss(_ job: Job) {
        dismissedKeys.insert(job.key)
        keep(dismissedKeys, "jobs.dismissed")
        try? FileManager.default.removeItem(at: job.file(".partial"))
    }

    private func keep(_ keys: Set<String>, _ name: String) {
        var list = defaults.stringArray(forKey: name) ?? []
        list.removeAll { !keys.contains($0) }
        for k in keys where !list.contains(k) { list.append(k) }
        defaults.set(Array(list.suffix(200)), forKey: name)
    }
}

/// The two-click Stop: the first click asks, a second one within 3 s stops.
struct StopArm {
    private(set) var armed: String?
    private(set) var at = Date.distantPast
    static let window: TimeInterval = 3

    /// True when this click stops the job.
    mutating func click(_ key: String, now: Date = Date()) -> Bool {
        if armed == key, now.timeIntervalSince(at) < Self.window { armed = nil; return true }
        armed = key
        at = now
        return false
    }

    func asking(_ key: String, now: Date = Date()) -> Bool { armed == key && now.timeIntervalSince(at) < Self.window }
}

/// The session's jobs above the message box: what runs, and an end the chat does not hear about.
struct JobsRow: View {
    @Environment(AppModel.self) var app
    let session: URL
    @State private var arm = StopArm()

    var body: some View {
        let jobs = app.jobs.row(session)
        if !jobs.isEmpty {
            // Each second while something is young or about to go; else every 30 s.
            let fast = jobs.contains { j in
                j.status == .stopped || j.status == .starting || (j.started.map { -$0.timeIntervalSinceNow < 60 } ?? true)
            } || arm.armed != nil
            TimelineView(.periodic(from: .now, by: fast ? 1 : 30)) { ctx in
                let now = app.jobs.row(session, now: ctx.date)
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(now.prefix(3).enumerated()), id: \.element.key) { i, j in
                        row(j, now: ctx.date).arrive(i)
                    }
                    if now.count > 3 {
                        Text(now.count == 4 ? "+1 more job" : "+\(now.count - 3) more jobs").font(Theme.sans(11)).foregroundStyle(Theme.faint)
                            .padding(.leading, 12)
                    }
                }
            }
            .transition(.opacity.combined(with: .offset(y: 4)))
        }
    }

    private func row(_ j: Job, now: Date) -> some View {
        let woken = app.jobs.woken.contains(j.key)
        let again = app.jobs.capped.contains(j.key)
        let text = JobBoard.line(j, woken: woken, again: again, now: now)
        let whole = j.status == .failed || j.status == .lost  // the line names the job itself
        return VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: j.icon).font(.system(size: 10.5))
                    .foregroundStyle(j.status == .failed || j.status == .lost ? Theme.accentInk : Theme.faint)
                    .frame(width: 14)
                if whole {
                    Text(text).font(Theme.sans(12)).foregroundStyle(Theme.ink).lineLimit(2)
                } else {
                    Text(j.label).font(Theme.sans(12, .medium)).foregroundStyle(Theme.ink).lineLimit(1)
                    Spacer(minLength: 6)
                    Text(text).font(Theme.sans(11.5)).foregroundStyle(Theme.muted).monospacedDigit().lineLimit(1)
                }
                if whole { Spacer(minLength: 6) }
                actions(j, woken: woken, now: now)
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            .help(help(j, woken: woken))
            if j.status.live, let p = j.progress, p > 0 {
                GeometryReader { g in
                    Rectangle().fill(Theme.accent).frame(width: g.size.width * min(max(p, 0), 1))
                        .animation(Theme.motion, value: p)
                }
                .frame(height: 2)
            }
        }
        .background(Theme.hover, in: RoundedRectangle(cornerRadius: 10))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder private func actions(_ j: Job, woken: Bool, now: Date) -> some View {
        switch j.status {
        case .starting where j.stoppable, .running where j.stoppable:
            let asking = arm.asking(j.key, now: now)
            textButton(asking ? "Stop it?" : "Stop", accent: asking,
                       help: asking ? "Click again to stop this job" : "Stop this job") {
                if arm.click(j.key) { app.jobs.stop(j) }
            }
        case .done:
            textButton("Show", accent: true, help: "Play the file on the stage") { show(j) }
        case .failed:
            if !woken { textButton("Ask Takes", accent: true, help: "Ask Takes to look at it") { app.jobs.ask(j) } }
            close(j)
        case .lost:
            textButton("Run again", accent: true, help: "Ask Takes to start this job again") { app.jobs.ask(j) }
            close(j)
        default:
            EmptyView()
        }
    }

    private func textButton(_ title: String, accent: Bool, help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(Theme.sans(11.5, .semibold))
                .foregroundStyle(accent ? Theme.accentInk : Theme.muted)
                .padding(.horizontal, 8).frame(height: 22)
                .background(accent ? Theme.accentSoft : Color.clear, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(PressStyle())
        .help(help)
    }

    private func close(_ j: Job) -> some View {
        Button { withAnimation(Theme.motion) { app.jobs.dismiss(j) } } label: {
            Image(systemName: "xmark").font(.system(size: 9.5, weight: .semibold)).foregroundStyle(Theme.faint)
                .frame(width: 18, height: 18).contentShape(Rectangle())
        }
        .buttonStyle(.plain).help("Close")
    }

    private func help(_ j: Job, woken: Bool) -> String {
        switch j.status {
        case .running where j.isGenerate: return "You paid for this clip when it started, so you cannot stop it."
        case .failed:
            let last = j.error.map { "Last line from the job: \($0)" } ?? ""
            return woken ? last : ["Ask Takes to look at it.", last].filter { !$0.isEmpty }.joined(separator: " ")
        default: return ""
        }
    }

    private func show(_ j: Job) {
        guard let first = j.outputs.first else { app.jobs.seen(j); return }
        app.jobs.seen(j)
        app.follow(session.appending(path: first))
    }
}

/// The closed chat's pill, left of the mascot: what runs, or a result to see.
struct JobPill: View {
    @Environment(AppModel.self) var app
    let job: Job
    let open: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(action: open) {
                Label(job.status == .done ? "\(job.label) is ready" : "\(job.label) · \(JobBoard.line(job))",
                      systemImage: job.icon)
                    .lineLimit(1)
                    .padding(.leading, 14).padding(.trailing, job.status == .done ? 8 : 14)
            }
            .buttonStyle(PressStyle())
            .help("Open the chat")
            if job.status == .done {
                Button {
                    app.jobs.seen(job)
                    if let f = job.outputs.first { app.follow(job.session.appending(path: f)) }
                } label: {
                    Text("Show").padding(.trailing, 14).padding(.leading, 2)
                }
                .buttonStyle(PressStyle())
                .help("Play the file on the stage")
            }
        }
        .font(Theme.sans(12.5, .semibold))
        .foregroundStyle(Theme.ink)
        .frame(height: 34)
        .background(Theme.raised, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.border, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.12), radius: 8, y: 4)
        .transition(.scale(scale: 0.9, anchor: .trailing).combined(with: .opacity))
    }
}
