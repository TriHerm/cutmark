import AppKit
import SwiftUI
import Testing
@testable import Takes

// What a session switch costs, end to end: the click, the new session's views, their layout and
// drawing, in the whole window. A made-up library with the shape of the user's (2026-10-11: 18
// sessions, up to 82 edits, 64 generated images, 12 takes, 290 KB chats). Off by default:
//   TAKES_BENCH=1 ./test.sh --filter ZBenchSwitch
@MainActor
@Suite(.serialized) struct ZBenchSwitch {
    /// takes, edits, thumbnails, generated images, posts, storyboard shots, chat KB.
    static let shapes: [(Int, Int, Int, Int, Int, Int, Int)] = [
        (2, 6, 0, 0, 3, 0, 80), (2, 8, 0, 0, 4, 0, 96), (0, 0, 0, 0, 0, 0, 0), (1, 36, 2, 0, 4, 0, 43),
        (0, 2, 0, 0, 5, 0, 0), (1, 30, 7, 0, 5, 0, 98), (0, 0, 6, 0, 5, 0, 0), (4, 29, 6, 0, 5, 0, 0),
        (3, 82, 14, 0, 5, 1, 228), (1, 22, 0, 0, 5, 0, 159), (9, 21, 0, 2, 4, 20, 205), (0, 0, 18, 0, 4, 16, 183),
        (1, 21, 0, 0, 0, 11, 226), (12, 6, 0, 0, 0, 11, 35), (4, 5, 0, 0, 2, 0, 79), (1, 43, 0, 1, 0, 8, 4),
        (2, 2, 1, 10, 2, 7, 0), (2, 57, 8, 64, 5, 7, 290),
    ]

    static func png(_ url: URL, _ w: Int, _ h: Int) {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    /// Real clips when TAKES_BENCH_MEDIA has tall.mp4 and wide.mov (APFS clones, no disk), else empty files.
    static let media = ProcessInfo.processInfo.environment["TAKES_BENCH_MEDIA"].map { URL(fileURLWithPath: $0) }
    static var tall: URL? { media?.appending(path: "tall.mp4") }
    static var wide: URL? { media?.appending(path: "wide.mov") }
    static func video(_ from: URL?, _ to: URL) {
        if let from, (try? FileManager.default.copyItem(at: from, to: to)) != nil { return }
        FileManager.default.createFile(atPath: to.path, contents: Data())
    }

    static func library() -> URL {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appending(path: "takes-switchbench-\(UUID().uuidString)")
        let project = root.appending(path: "Bench")
        try? fm.createDirectory(at: project, withIntermediateDirectories: true)
        let words = Array(repeating: "the quick brown fox jumps over a lazy dog and says something", count: 60).joined(separator: " ")
        for (i, s) in shapes.enumerated() {
            let (takes, edits, thumbs, gen, posts, shots, chatKB) = s
            let url = project.appending(path: String(format: "2026-10-%02d-session-%02d", i + 1, i))
            try? fm.createDirectory(at: url, withIntermediateDirectories: true)
            let doc = SessionDoc(url: url)
            doc.meta = SessionMeta(title: "Session \(i)", createdAt: Date(), named: true)
            try? (words + "\n\n" + words).write(to: url.appending(path: "script.md"), atomically: true, encoding: .utf8)
            var list: [Take] = []
            for n in 0..<takes {
                let file = "take-\(String(format: "%02d", n + 1))-camera.mov"
                video(wide, url.appending(path: file))
                list.append(Take(number: n + 1, kind: .camera, file: file, startedAt: Date(), duration: 42,
                                 script: nil, hook: n % 3 == 0 ? "Hook text \(n)" : nil, shot: nil))
            }
            doc.meta.takes = list
            doc.save()
            try? #"{"hooks":[{"id":"h1","text":"Hook text 0"},{"id":"h2","text":"Hook text 3"}],"chosen":"h1"}"#
                .write(to: url.appending(path: "hooks.json"), atomically: true, encoding: .utf8)
            for (folder, n, ext) in [("edits", edits, "mp4"), ("thumbnails", thumbs, "png"), ("generated", gen, "png")] where n > 0 {
                let dir = url.appending(path: folder)
                try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
                for k in 0..<n {
                    let f = dir.appending(path: "clip-v\(k + 1).\(ext)")
                    if ext == "png" { png(f, 1920, 1080) } else { video(tall, f) }
                }
            }
            if posts > 0 {
                let dir = url.appending(path: "posts")
                try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
                for p in PostPlatform.allCases.prefix(min(posts, 4)) {
                    let media = edits > 0 ? "media: edits/clip-v1.mp4\n" : ""
                    try? "---\n\(media)status: ready\nat: 2026-10-12T09:02:00-07:00\n---\n\(words)"
                        .write(to: dir.appending(path: "\(p.rawValue).md"), atomically: true, encoding: .utf8)
                }
            }
            if shots > 0 {
                let dir = url.appending(path: "storyboard")
                try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
                for k in 0..<shots { png(dir.appending(path: "shot-\(k).png"), 320, 180) }
            }
            if chatKB > 0 {
                var log = ChatLog(conversation: UUID().uuidString, started: true)
                var size = 0
                while size < chatKB * 1000 {
                    let m = ChatMessage(role: log.messages.count % 2 == 0 ? .user : .claude, text: String(words.prefix(600)))
                    log.messages.append(m); size += 700
                }
                try? JSONEncoder().encode(log).write(to: ClaudeChat.file(url))
            }
        }
        return root
    }

    func cpu() -> Double {
        var t = timespec()
        clock_gettime(CLOCK_THREAD_CPUTIME_ID, &t)
        return Double(t.tv_sec) + Double(t.tv_nsec) / 1e9
    }

    @Test(.enabled(if: bench)) func sessionSwitch() throws {
        let root = Self.library()
        defer { try? FileManager.default.removeItem(at: root) }
        let d = UserDefaults.standard
        let oldTab = d.string(forKey: "rightTab")
        defer { d.set(oldTab, forKey: "rightTab") }
        let app = AppModel()
        app.library.setRoot(root)
        app.library.selectedProject = app.library.projects.first?.url
        let urls = app.library.sessions.map(\.url)
        // The chat beside the session, as the user keeps it (TAKES_BENCH_CHAT=0 closes it).
        let chatOpen = ProcessInfo.processInfo.environment["TAKES_BENCH_CHAT"] != "0"
        app.chats.docked = chatOpen
        app.chats.open = chatOpen
        try #require(urls.count == Self.shapes.count)
        let host = NSHostingView(rootView: AnyView(ContentView(library: app.library).environment(app).frame(width: 1400, height: 900)))
        let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 1400, height: 900),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        func settle() {
            for _ in 0..<3 {
                RunLoop.main.run(until: Date())
                host.layoutSubtreeIfNeeded()
                host.displayIfNeeded()
            }
        }
        settle()
        var report: [String] = []
        defer {
            var all = d.dictionary(forKey: SessionView.key) ?? [:]
            for key in all.keys where key.hasPrefix(root.standardizedFileURL.path) { all[key] = nil }
            d.set(all, forKey: SessionView.key)
        }
        let only = ProcessInfo.processInfo.environment["TAKES_BENCH_ONLY"]
        for tab in ["script", "assets", "post", "remembered"] where only == nil || only == tab {
            if tab == "remembered" {
                // Each session opens on its own tab, as in the app: Assets with an edit in the player,
                // the post, or the script.
                for (i, u) in urls.enumerated() {
                    let edit = u.appending(path: "edits/clip-v1.mp4")
                    let hasEdit = FileManager.default.fileExists(atPath: edit.path)
                    switch i % 3 {
                    case 0 where hasEdit: SessionView.write(u, mode: .assets, file: edit, time: 0)
                    case 1: SessionView.write(u, mode: .post, file: nil, time: nil)
                    default: SessionView.write(u, mode: .record, file: nil, time: nil)
                    }
                }
            } else {
                d.set(tab, forKey: "rightTab")
            }
            app.library.selectedSessions = []
            settle()
            var times: [Double] = [], opens: [Double] = []
            let names = ["TakeRow", "AssetTile", "TakesList", "SessionHeader", "DetailView", "ChatRows", "PostPane", "ScriptPane"]
            let before = names.map { Perf.count($0) }
            for round in 0..<(Int(ProcessInfo.processInfo.environment["TAKES_BENCH_ROUNDS"] ?? "") ?? 3) {
                for u in urls {
                    // The main thread's own CPU time: other work on the Mac barely moves it.
                    let t = cpu()
                    app.library.selectedSessions = [u]
                    let o = cpu()
                    settle()
                    if round > 0 { times.append((cpu() - t) * 1000); opens.append((o - t) * 1000) }
                }
            }
            let bodies = zip(names, before).map { "\($0.0) \(Perf.count($0.0) - $0.1)" }.joined(separator: ", ")
            report.append(String(format: "BENCH   %@ open (sync) mean %.1f ms; bodies: %@",
                                 tab, opens.reduce(0, +) / Double(opens.count), bodies))
            let s = times.sorted()
            let p = { (q: Double) in s[min(s.count - 1, Int(Double(s.count) * q))] }
            report.append(String(format: "BENCH switch %@ (main thread CPU): n %d, p50 %.1f ms, p90 %.1f, max %.1f, mean %.1f",
                                 tab, s.count, p(0.5), p(0.9), s.last ?? 0, s.reduce(0, +) / Double(s.count)))
        }
        report.forEach { print($0) }
    }
}
