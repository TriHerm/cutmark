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
    /// A raw take has no published recipe. It can still be edited without first asking an
    /// agent to create an edit; rendering it later starts a *new* named recipe.
    var isRawTake: Bool { base.hasPrefix("takes/") }

    static func fromTake(_ take: Take, duration: Double, fps: Double = 30) -> Self? {
        guard duration.isFinite, fps.isFinite, fps > 0, duration >= 2 / fps,
              !take.file.contains("/"), !take.file.contains("..") else { return nil }
        let segment = Segment(take: take.number, kind: take.kind.rawValue, start: 0, end: duration)
        return Self(base: "takes/" + take.file, fps: fps, source: [segment], segments: [segment])
    }

    enum TrimEdge { case start, end }

    /// One drag endpoint maps to source seconds; snap to full output frames and keep two frames.
    /// The gesture does not mutate until release, so undo is one atomic timeline action.
    func trimProposal(index: Int, edge: TrimEdge, dragSeconds: Double) -> Action? {
        guard segments.indices.contains(index), dragSeconds.isFinite, fps.isFinite, fps > 0 else { return nil }
        let s = segments[index]
        let frame = 1 / fps
        switch edge {
        case .start:
            let value = min(s.end - 2 * frame, max(s.start, ((s.start + dragSeconds) * fps).rounded() / fps))
            return value > s.start ? Action(op: "trim", index: index, in: value, out: s.end) : nil
        case .end:
            let value = max(s.start + 2 * frame, min(s.end, ((s.end + dragSeconds) * fps).rounded() / fps))
            return value < s.end ? Action(op: "trim", index: index, in: s.start, out: value) : nil
        }
    }

    /// The first raw-take render must use the canonical recipe shape; subsequent renders use
    /// base + plan_timeline_edit, preserving unrelated overlays/music from published versions.
    func initialRecipe() -> [String: Any]? {
        guard isRawTake, !segments.isEmpty else { return nil }
        let name = base.dropFirst("takes/".count).replacingOccurrences(of: ".mov", with: "")
        return ["name": "clip-" + name,
                "cut": segments.map { ["take": $0.take, "kind": $0.kind,
                                       "in": $0.start, "out": $0.end] as [String: Any] },
                // The encoder picks the native source rate; the timeline frame grid is only
                // an editing aid and must not force a 30 fps export from a 60 fps screen take.
                "frame": ["shape": "source"]]
    }

    /// The lead is the optional cover duration; cut ranges remain on each original source clock.
    func outputStart(of index: Int, lead: Double = 0) -> Double? {
        guard (0..<segments.count).contains(index), lead.isFinite, lead >= 0 else { return nil }
        return lead + segments.prefix(index).reduce(0) { $0 + $1.duration }
    }

    /// Half-open mapping from the rendered video playhead into one specific clip occurrence.
    func sourcePoint(atOutput seconds: Double, lead: Double = 0) -> (index: Int, source: Double)? {
        guard seconds.isFinite, lead.isFinite, lead >= 0 else { return nil }
        let local = seconds - lead
        guard local >= 0 && local < duration else { return nil }
        var cursor = 0.0
        for (index, segment) in segments.enumerated() {
            if local < cursor + segment.duration {
                return (index, segment.start + local - cursor)
            }
            cursor += segment.duration
        }
        return nil
    }

    /// The player shows the immutable published cut until a new render exists. Translate its
    /// playhead against source, not the reordered draft, or split would target the wrong footage.
    func originalSourcePoint(atOutput seconds: Double, lead: Double = 0)
        -> (take: Int, kind: String, source: Double)? {
        let original = Self(base: base, fps: fps, source: source, segments: source)
        guard let point = original.sourcePoint(atOutput: seconds, lead: lead) else { return nil }
        let segment = source[point.index]
        return (segment.take, segment.kind, point.source)
    }

    /// Seek to a selected draft segment's source position in the *original* published video.
    /// Duplicate occurrences reuse their existing first matching source preview until rendering.
    func originalOutputStart(of index: Int, lead: Double = 0) -> Double? {
        guard segments.indices.contains(index), lead.isFinite, lead >= 0 else { return nil }
        let selected = segments[index]
        var elapsed = lead
        for original in source {
            if original.take == selected.take && original.kind == selected.kind
                && original.start <= selected.start && selected.start < original.end {
                return elapsed + selected.start - original.start
            }
            elapsed += original.duration
        }
        return nil
    }

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

    /// Undo reconstructs from the immutable recipe's cut, not a possibly rounded intermediate.
    mutating func undoLast() -> Bool {
        guard !actions.isEmpty else { return false }
        let history = actions.dropLast()
        var replay = Self(base: base, fps: fps, source: source, segments: source)
        for action in history {
            guard replay.apply(action) else { return false }
        }
        self = replay
        return true
    }

    /// Drafts are private working files, never inside edits/ where published versions live.
    static func file(video: URL, session: URL) -> URL? {
        let folder = video.deletingLastPathComponent().standardizedFileURL.path
        let sessionRoot = session.standardizedFileURL.path
        guard (folder == sessionRoot && video.pathExtension.lowercased() == "mov")
              || folder == session.appending(path: "edits").standardizedFileURL.path,
              !video.lastPathComponent.contains("/") else { return nil }
        return session.appending(path: "_edit/.timeline-drafts/" + video.lastPathComponent + ".json")
    }

    static func restore(video: URL, session: URL, original: EditTimelineDraft? = nil) -> EditTimelineDraft? {
        let fresh = original ?? read(video: video)
        guard let fresh, let file = file(video: video, session: session),
              let data = try? Data(contentsOf: file),
              let old = try? JSONDecoder().decode(Self.self, from: data),
              old.base == fresh.base, old.fps == fresh.fps, old.source == fresh.source
        else { return fresh }
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
