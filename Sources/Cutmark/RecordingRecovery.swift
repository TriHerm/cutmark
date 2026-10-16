import AVFoundation
import Foundation

/// A tiny durable claim around recording (2026-10-16). The recorders still write Cutmark's normal
/// take-XX-camera.mov / take-XX-screen.mov files. If the app quits after a movie finished but before
/// session.json records it, the next launch can attach the playable files instead of orphaning them.
/// This is deliberately independent of the prompter and is the first step toward segmented capture.
enum RecordingRecovery {
    static let filePrefix = ".recording-take-"
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }()
    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    struct Journal: Codable, Equatable {
        var number: Int
        var camera: String
        var screen: String?
        var requestedAt: Date
        var cameraStartedAt: Date?
        var screenStartedAt: Date?
        var script: String?
        var hook: String?
        var shot: String?
    }

    static func url(in session: URL, number: Int) -> URL {
        session.appending(path: String(format: "%@%02d.json", filePrefix, number))
    }

    static func read(_ session: URL, number: Int) -> Journal? {
        guard let data = try? Data(contentsOf: url(in: session, number: number)) else { return nil }
        return try? decoder.decode(Journal.self, from: data)
    }

    /// Every unfinished claim in number order. A per-take file means starting a new recording can
    /// never overwrite an older crash claim that is still being validated.
    static func journals(in session: URL) -> [Journal] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: session.path)) ?? []
        return names.filter { $0.hasPrefix(filePrefix) && $0.hasSuffix(".json") }
            .compactMap { name -> Journal? in
                guard let data = try? Data(contentsOf: session.appending(path: name)) else { return nil }
                return try? decoder.decode(Journal.self, from: data)
            }
            .sorted { $0.number < $1.number }
    }

    @discardableResult
    static func write(_ journal: Journal, in session: URL) -> Bool {
        guard let data = try? encoder.encode(journal) else { return false }
        do {
            try data.write(to: url(in: session, number: journal.number), options: .atomic)
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    static func begin(in session: URL, number: Int, camera: URL, screen: URL?,
                      script: String?, hook: String?, shot: String?) -> Bool {
        write(Journal(number: number, camera: camera.lastPathComponent, screen: screen?.lastPathComponent,
                      requestedAt: Date(), script: script, hook: hook, shot: shot), in: session)
    }

    @discardableResult
    static func started(in session: URL, number: Int, camera: Date, screen: Date?) -> Bool {
        guard var journal = read(session, number: number) else { return false }
        journal.cameraStartedAt = camera
        journal.screenStartedAt = screen
        return write(journal, in: session)
    }

    static func clear(_ session: URL, number: Int) {
        try? FileManager.default.removeItem(at: url(in: session, number: number))
    }

    /// A claim that could not be recovered yet still owns its take number, so a new recording never
    /// overwrites potentially salvageable camera/screen files with the same name.
    static func nextTakeNumber(in session: URL, meta: SessionMeta) -> Int {
        let saved = meta.takes.map(\.number).max() ?? 0
        let pending = journals(in: session).map(\.number).max() ?? 0
        let disk = ((try? FileManager.default.contentsOfDirectory(atPath: session.path)) ?? []).compactMap { name -> Int? in
            let parts = name.split(separator: "-", maxSplits: 2)
            guard parts.count == 3, parts[0] == "take" else { return nil }
            return Int(parts[1])
        }.max() ?? 0
        return max(saved, pending, disk) + 1
    }

    /// Human-readable confirmation after a crash recovery. Keep the wording short enough for the
    /// stage toast; the files and session metadata remain the source of truth.
    static func notice(number: Int, kinds: [TakeKind]) -> String {
        let hasCamera = kinds.contains { $0 == .camera }
        let hasScreen = kinds.contains { $0 == .screen }
        let media: String
        if hasCamera && hasScreen {
            media = "camera + screen"
        } else if hasScreen {
            media = "screen"
        } else {
            media = "camera"
        }
        return "Recovered interrupted Take \(number) · \(media)"
    }

    /// Sessions with an unfinished recording claim. Only runs at launch, so a two-level scan is cheap.
    static func sessions(in root: URL) -> [URL] {
        let fm = FileManager.default
        let projects = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                                    options: [.skipsHiddenFiles])) ?? []
        var out: [URL] = []
        for project in projects where project.hasDirectoryPath && !project.lastPathComponent.hasPrefix("_") {
            let sessions = (try? fm.contentsOfDirectory(at: project, includingPropertiesForKeys: [.isDirectoryKey],
                                                        options: [.skipsHiddenFiles])) ?? []
            for session in sessions where session.hasDirectoryPath {
                if !journals(in: session).isEmpty { out.append(Store.dir(session)) }
            }
        }
        return out
    }

    static func recoverableTakes(in session: URL, journal: Journal, meta: SessionMeta) async -> [Take] {
        await recoverableTakes(in: session, journal: journal, meta: meta, duration: mediaDuration)
    }

    /// Pure apart from the supplied duration loader, so recovery policy is testable without real media.
    static func recoverableTakes(in session: URL, journal: Journal, meta: SessionMeta,
                                 duration: (URL) async -> Double?) async -> [Take] {
        guard !meta.takes.contains(where: { $0.number == journal.number }) else { return [] }
        var takes: [Take] = []
        let camera = session.appending(path: journal.camera)
        let cameraStart = journal.cameraStartedAt ?? created(camera) ?? journal.requestedAt
        if let cameraDuration = await duration(camera), cameraDuration > 0 {
            takes.append(Take(number: journal.number, kind: .camera, file: journal.camera, startedAt: cameraStart,
                              duration: cameraDuration, script: journal.script, hook: journal.hook, shot: journal.shot))
        }
        if let screenName = journal.screen {
            let screen = session.appending(path: screenName)
            if let screenDuration = await duration(screen), screenDuration > 0 {
                takes.append(Take(number: journal.number, kind: .screen, file: screenName,
                                  startedAt: journal.screenStartedAt ?? created(screen) ?? journal.requestedAt,
                                  duration: screenDuration, script: journal.script, hook: journal.hook, shot: journal.shot))
            }
        }
        return takes
    }

    private static func created(_ file: URL) -> Date? {
        try? file.resourceValues(forKeys: [.creationDateKey]).creationDate
    }

    private static func mediaDuration(_ file: URL) async -> Double? {
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let asset = AVURLAsset(url: file)
        guard (try? await asset.load(.isPlayable)) == true,
              let duration = try? await asset.load(.duration), duration.isNumeric, duration.seconds > 0 else { return nil }
        return duration.seconds
    }
}
