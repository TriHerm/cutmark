import Foundation

/// Native assembly lives under _edit/studio; existing take files and published recipes are immutable.
struct MediaEditProject: Codable, Equatable {
    enum Kind: String, Codable { case video, image, audio }
    enum Lane: String, Codable, CaseIterable { case video, overlay, audio }
    enum Format: String, Codable, CaseIterable, Identifiable {
        case landscape, portrait, square
        var id: String { rawValue }
        var title: String { switch self { case .landscape: "16:9"; case .portrait: "9:16"; case .square: "1:1" } }
    }
    struct Clip: Codable, Equatable, Identifiable {
        var id = UUID()
        var file: String
        var name: String
        var kind: Kind
        var lane: Lane
        var sourceDuration: Double
        var start: Double = 0
        var end: Double
        var offset: Double = 0
        var speed: Double = 1
        var volume: Double = 1
        var fadeIn: Double = 0
        var fadeOut: Double = 0
        var fill = false
        var zoom: Double = 1
        var focusX: Double = 0.5
        var focusY: Double = 0.5
        var autoZoom = false
        var overlaySize: Double = 0.30
        var overlayLeft = false
        var overlayBottom = false
        var duration: Double { (end - start) / speed }
    }
    var version = 1
    var format: Format = .landscape
    var clips: [Clip] = []
    var duration: Double { clips.filter { $0.lane == .video }.reduce(0) { $0 + $1.duration } }
    func position(_ id: UUID) -> Double {
        var at = 0.0
        for clip in clips {
            if clip.id == id { return clip.lane == .video ? at : clip.offset }
            if clip.lane == .video { at += clip.duration }
        }
        return 0
    }
    func validate() throws {
        guard version == 1, clips.count <= 200, Set(clips.map(\.id)).count == clips.count else { throw Failure.invalid("This edit format is not supported.") }
        for c in clips {
            guard !c.file.isEmpty, !c.file.hasPrefix("/"), !c.file.split(separator: "/").contains(".."),
                  [c.start, c.end, c.sourceDuration, c.offset, c.speed, c.volume, c.fadeIn, c.fadeOut, c.zoom, c.focusX, c.focusY, c.overlaySize].allSatisfy(\.isFinite),
                  c.start >= 0, c.end <= c.sourceDuration + 0.001, c.duration >= 1 / 30,
                  c.speed >= 0.25, c.speed <= 4, c.volume >= 0, c.volume <= 1,
                  c.offset >= 0, c.offset <= 86400, c.sourceDuration <= 86400,
                  c.fadeIn >= 0, c.fadeOut >= 0, c.fadeIn + c.fadeOut <= c.duration + 0.001,
                  c.zoom >= 1, c.zoom <= 3, (0...1).contains(c.focusX), (0...1).contains(c.focusY), (0.15...0.65).contains(c.overlaySize),
                  (c.kind == .audio ? c.lane == .audio : c.lane != .audio)
            else { throw Failure.invalid("A clip has invalid timing or settings.") }
        }
        guard duration <= 86400 else { throw Failure.invalid("Keep this edit shorter than 24 hours.") }
    }
    enum Failure: LocalizedError {
        case invalid(String)
        var errorDescription: String? { switch self { case .invalid(let text): text } }
    }
    static func file(in session: URL) -> URL { session.appending(path: "_edit/studio/project.json") }
    static func source(_ relative: String, session: URL) throws -> URL {
        let root = session.standardizedFileURL.resolvingSymlinksInPath()
        let url = root.appending(path: relative).standardizedFileURL.resolvingSymlinksInPath()
        guard !relative.hasPrefix("/"), !relative.split(separator: "/").contains(".."),
              url.path.hasPrefix(root.path + "/"),
              (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        else { throw Failure.invalid("A media file is missing. Locate it in the media library or remove its clip.") }
        return url
    }
    static func directory(_ relative: String, in session: URL) throws -> URL {
        let root = session.standardizedFileURL.resolvingSymlinksInPath()
        var current = root
        for part in relative.split(separator: "/") {
            guard part != ".." && part != "." else { throw Failure.invalid("Invalid edit folder.") }
            current.appendPathComponent(String(part))
            guard current.resolvingSymlinksInPath().path.hasPrefix(root.path + "/") else { throw Failure.invalid("The edit folder points outside this session.") }
            try FileManager.default.createDirectory(at: current, withIntermediateDirectories: true)
        }
        return current
    }
    func save(in session: URL) throws {
        try validate()
        let target = Self.file(in: session)
        let root = session.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        guard target.resolvingSymlinksInPath().path.hasPrefix(root) else { throw Failure.invalid("The edit folder points outside this session.") }
        _ = try Self.directory("_edit/studio", in: session)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: target, options: .atomic)
    }
    static func load(in session: URL) throws -> Self {
        let target = file(in: session)
        guard FileManager.default.fileExists(atPath: target.path) else { return Self() }
        _ = try source("_edit/studio/project.json", session: session)
        guard let size = try target.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 4_194_304 else { throw Failure.invalid("This edit file is too large to open.") }
        let project = try JSONDecoder().decode(Self.self, from: Data(contentsOf: target))
        try project.validate()
        return project
    }
    mutating func split(_ id: UUID, at time: Double) -> Bool {
        guard let i = clips.firstIndex(where: { $0.id == id }) else { return false }
        let c = clips[i], local = time - position(id)
        guard local >= 1 / 30, c.duration - local >= 1 / 30 else { return false }
        var right = c; right.id = UUID(); right.start = c.start + local * c.speed
        if c.lane != .video { right.offset = time }
        right.fadeIn = 0; right.fadeOut = min(c.fadeOut, right.duration)
        clips[i].end = right.start; clips[i].fadeOut = 0; clips[i].fadeIn = min(c.fadeIn, local)
        clips.insert(right, at: i + 1)
        return true
    }
    mutating func move(_ id: UUID, before target: UUID?) {
        guard let index = clips.firstIndex(where: { $0.id == id }), target != id else { return }
        let item = clips.remove(at: index)
        if let target, let destination = clips.firstIndex(where: { $0.id == target }) { clips.insert(item, at: destination) }
        else { clips.append(item) }
    }
    mutating func trim(_ id: UUID, start: Double, end: Double) {
        guard let i = clips.firstIndex(where: { $0.id == id }) else { return }
        if clips[i].lane != .video { clips[i].offset += (start - clips[i].start) / clips[i].speed }
        clips[i].start = start; clips[i].end = end
        let duration = clips[i].duration
        clips[i].fadeIn = min(clips[i].fadeIn, max(0, duration / 2))
        clips[i].fadeOut = min(clips[i].fadeOut, max(0, duration / 2))
    }
}
