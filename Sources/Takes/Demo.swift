import Foundation

/// Cutmark's first-run demo. v0.1 ships a local script-only example; a future release can opt into
/// a richer pack with CUTMARK_DEMO_URL without making first launch depend on a remote asset.
/// Help › Add the Demo Session adds it again, or opens it when it is there.
@MainActor @Observable
final class Demo {
    static let shared = Demo()
    static let doneKey = "demoAdded"
    static let project = "Start here"
    static let folder = "2026-10-08-your-first-video"
    static let title = "Your first video"
    /// Optional richer demo pack for development or a later first-party release.
    static var pack: URL? = ProcessInfo.processInfo.environment["CUTMARK_DEMO_URL"].flatMap(URL.init(string:))
    /// The script of the video, for the session without the download.
    static let script = """
        This app records the take, and an agent does the edit.

        You are reading this script on the teleprompter. It scrolls as you talk. Press R to record a take. Read it out loud once, right now.

        It's easy, no?

        Every take is kept. Star the best one, and that is your keeper. The agent edits the keeper.

        Then ask in the chat: cut the silences, add captions in my style, make a vertical version. Each edit is a new version, so you never lose one.

        Comment on any frame of an edit. The agent fixes it, and keeps the fix as a rule for your next video.

        When the edit is done, the post is waiting under it. Change one line, and schedule it.

        """

    private(set) var working = false
    @ObservationIgnored private var task: Task<URL?, Never>?

    /// First launch: a library without projects gets the demo once, in the background. It opens
    /// only when nothing else is open, so it never takes the screen from a session just made.
    func addIfNew(_ library: Library) {
        let d = UserDefaults.standard
        guard !d.bool(forKey: Self.doneKey) else { return }
        d.set(true, forKey: Self.doneKey)
        guard library.projects.isEmpty else { return }
        Task { _ = await add(library, open: nil) }
    }

    /// Adds the demo, or finds it, and opens it (open nil: only when no session is open).
    /// The session's folder, or nil when even the script-only session could not be made.
    @discardableResult
    func add(_ library: Library, open: Bool? = true) async -> URL? {
        let url: URL?
        if let task {
            url = await task.value
        } else {
            let t = Task { await self.fetch(library) }
            task = t
            working = true
            url = await t.value
            working = false
            task = nil
        }
        guard let url else { return nil }
        library.reload()
        if open ?? (library.current == nil) { library.select(url) }
        return url
    }

    private func fetch(_ library: Library) async -> URL? {
        let project = library.root.appending(path: Self.project)
        let there = project.appending(path: Self.folder)
        if FileManager.default.fileExists(atPath: there.appending(path: "session.json").path) { return there }
        if let pack = Self.pack, let zip = try? await Self.download(pack) {
            defer { try? FileManager.default.removeItem(at: zip) }
            if let url = try? await Task.detached { try Self.install(zip: zip, into: project) }.value {
                SessionDoc(url: url).save()  // SESSION.md names this Mac's folder
                return url
            }
        }
        return try? Self.scriptOnly(into: project)
    }

    nonisolated static func download(_ from: URL) async throws -> URL {
        let (file, response) = try await URLSession.shared.download(from: from)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            try? FileManager.default.removeItem(at: file)
            throw URLError(.badServerResponse)
        }
        let zip = FileManager.default.temporaryDirectory.appending(path: "cutmark-demo-\(UUID().uuidString).zip")
        try FileManager.default.moveItem(at: file, to: zip)
        return zip
    }

    /// Unpacks the zip next to the project and moves its one session in. A folder already there
    /// stays: the demo then gets the next free name.
    nonisolated static func install(zip: URL, into project: URL) throws -> URL {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appending(path: "cutmark-demo-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-x", "-k", zip.path, tmp.path]
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0,
              let session = try fm.contentsOfDirectory(at: tmp, includingPropertiesForKeys: nil)
                .first(where: { fm.fileExists(atPath: $0.appending(path: "session.json").path) })
        else { throw CocoaError(.fileReadCorruptFile) }
        try fm.createDirectory(at: project, withIntermediateDirectories: true)
        let to = free(project.appending(path: session.lastPathComponent))
        try fm.moveItem(at: session, to: to)
        return to
    }

    /// No download: the session with its script, ready to record.
    static func scriptOnly(into project: URL) throws -> URL {
        let url = free(project.appending(path: folder))
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try script.write(to: url.appending(path: "script.md"), atomically: true, encoding: .utf8)
        let doc = SessionDoc(url: url)
        doc.meta = SessionMeta(title: title, createdAt: Date(), named: true)
        doc.save()
        return url
    }

    nonisolated private static func free(_ url: URL) -> URL {
        var to = url, n = 2
        while FileManager.default.fileExists(atPath: to.path) {
            to = url.deletingLastPathComponent().appending(path: "\(url.lastPathComponent)-\(n)"); n += 1
        }
        return to
    }
}
