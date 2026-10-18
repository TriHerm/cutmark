import Foundation

/// An unpublished, recoverable timeline plan. Published recipes are immutable; the render agent
/// must validate every action against the selected base before making the next video version.
struct EditTimelineDraft: Codable {
    struct Segment: Codable, Equatable {
        let take: Int
        let kind: String
        var start: Double
        var end: Double
        var duration: Double { max(0, end - start) }
    }

    struct Action: Codable, Equatable {
        let op: String
        let index: Int
        var to: Int? = nil
        var at: Double? = nil
        var `in`: Double? = nil
        var out: Double? = nil
    }

    let base: String
    let fps: Double
    let source: [Segment]
    var segments: [Segment]
    var actions: [Action] = []

    var duration: Double { segments.reduce(0) { $0 + $1.duration } }

    static func read(video: URL) -> EditTimelineDraft? {
        guard let r = EditRecipe.read(video),
              let cuts = r["cut"] as? [[String: Any]],
              let frame = r["frame"] as? [String: Any],
              let fps = (frame["fps"] as? NSNumber)?.doubleValue, fps > 0,
              !cuts.isEmpty else { return nil }
        var segments: [Segment] = []
        for g in cuts {
            guard let take = (g["take"] as? NSNumber)?.intValue,
                  let start = (g["in"] as? NSNumber)?.doubleValue,
                  let end = (g["out"] as? NSNumber)?.doubleValue,
                  end > start else { return nil }
            segments.append(Segment(take: take, kind: g["kind"] as? String ?? "camera",
                                    start: start, end: end))
        }
        return EditTimelineDraft(base: "edits/" + video.lastPathComponent, fps: fps,
                                 source: segments, segments: segments)
    }

    /// The index always refers to the list as it exists *after* all prior actions.
    mutating func apply(_ action: Action) -> Bool {
        guard actions.count < 100, segments.indices.contains(action.index), fps.isFinite, fps > 0 else { return false }
        let index = action.index
        let item = segments[index]
        let minDuration = 2.0 / fps
        switch action.op {
        case "move":
            guard let to = action.to, segments.indices.contains(to) else { return false }
            segments.insert(segments.remove(at: index), at: to)
        case "duplicate":
            segments.insert(item, at: index + 1)
        case "remove":
            guard segments.count > 1 else { return false }
            segments.remove(at: index)
        case "split":
            guard let at = action.at, at.isFinite,
                  at - item.start >= minDuration, item.end - at >= minDuration else { return false }
            segments[index].end = at
            segments.insert(Segment(take: item.take, kind: item.kind, start: at, end: item.end), at: index + 1)
        case "trim":
            let start = action.in ?? item.start, end = action.out ?? item.end
            guard start.isFinite, end.isFinite, start >= item.start, end <= item.end,
                  end - start >= minDuration else { return false }
            segments[index].start = start
            segments[index].end = end
        default:
            return false
        }
        actions.append(action)
        return true
    }

    /// Drafts are private working files, never inside edits/ where published versions live.
    static func file(video: URL, session: URL) -> URL? {
        guard video.deletingLastPathComponent().standardizedFileURL.path
                == session.appending(path: "edits").standardizedFileURL.path,
              !video.lastPathComponent.contains("/") else { return nil }
        return session.appending(path: "_edit/.timeline-drafts/" + video.lastPathComponent + ".json")
    }

    static func restore(video: URL, session: URL) -> EditTimelineDraft? {
        guard let fresh = read(video: video), let file = file(video: video, session: session),
              let data = try? Data(contentsOf: file),
              let old = try? JSONDecoder().decode(Self.self, from: data),
              old.base == fresh.base, old.fps == fresh.fps, old.source == fresh.source
        else { return read(video: video) }
        var replay = fresh
        for action in old.actions {
            if !replay.apply(action) { return fresh }
        }
        return replay.segments == old.segments ? replay : fresh
    }

    func save(video: URL, session: URL) throws {
        guard let file = Self.file(video: video, session: session) else { return }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(self)
        try data.write(to: file, options: .atomic)
    }

    static func clear(video: URL, session: URL) {
        guard let file = file(video: video, session: session) else { return }
        try? FileManager.default.removeItem(at: file)
    }
}
