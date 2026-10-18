import AVFoundation
import Foundation

/// An unpublished, recoverable timeline plan. Published recipes are immutable; the render agent
/// must validate every action against the selected base before making the next video version.
struct EditTimelineDraft: Codable {
    struct Segment: Codable, Equatable {
        let take: Int
        let kind: String
        var start: Double
        var end: Double
        /// Derived from the real take file when the editor opens. These three values deliberately
        /// stay out of the saved draft JSON: they are a cache of renderer clock facts, not edits.
        var sourceFPS: Double? = nil
        var renderSourceStart: Double? = nil
        var renderDuration: Double? = nil

        var sourceDuration: Double { max(0, end - start) }
        /// Timeline/output duration, matching render_cut once the source clock is known.
        var duration: Double { renderDuration ?? sourceDuration }

        init(take: Int, kind: String, start: Double, end: Double, sourceFPS: Double? = nil) {
            self.take = take
            self.kind = kind
            self.start = start
            self.end = end
            self.sourceFPS = sourceFPS
        }

        private enum CodingKeys: String, CodingKey { case take, kind, start, end }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            take = try c.decode(Int.self, forKey: .take)
            kind = try c.decode(String.self, forKey: .kind)
            start = try c.decode(Double.self, forKey: .start)
            end = try c.decode(Double.self, forKey: .end)
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(take, forKey: .take)
            try c.encode(kind, forKey: .kind)
            try c.encode(start, forKey: .start)
            try c.encode(end, forKey: .end)
        }

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.take == rhs.take && lhs.kind == rhs.kind
                && lhs.start == rhs.start && lhs.end == rhs.end
        }
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

    init(base: String, fps: Double, source: [Segment], segments: [Segment], actions: [Action] = []) {
        self.base = base
        self.fps = fps
        self.source = Self.withRenderClock(source)
        self.segments = Self.withRenderClock(segments)
        self.actions = actions
        recomputeRenderClock()
    }

    static func fromTake(_ take: Take, duration: Double, fps: Double = 30,
                         sourceFPS: Double? = nil) -> Self? {
        guard duration.isFinite, fps.isFinite, fps > 0, duration >= 2 / fps,
              !take.file.contains("/"), !take.file.contains("..") else { return nil }
        // Keep the original editor frame grid (and saved draft compatibility) independent
        // of the actual MOV clock. ScreenCaptureKit VFR source FPS is detected from the file;
        // assuming every recorded screen file has 60 source frames caused preview to fail.
        guard let sourceFPS = sourceFPS ?? rendererFPS(observed: fps),
              sourceFPS.isFinite, sourceFPS > 0 else { return nil }
        let segment = Segment(take: take.number, kind: take.kind.rawValue,
                              start: 0, end: duration, sourceFPS: sourceFPS)
        return Self(base: "takes/" + take.file, fps: fps, source: [segment], segments: [segment])
    }

    struct RendererSpan: Equatable {
        let sourceStart: Double
        let declaredSourceEnd: Double
        let outputDuration: Double
    }

    /// Same integer-FPS normalization as take_clock when the renderer's source rate is already
    /// known (raw takes pass their capture rate directly).
    static func rendererFPS(observed: Double) -> Double? {
        guard observed.isFinite, observed > 0 else { return nil }
        if observed >= 24, observed <= 60 {
            return observed.rounded(.toNearestOrEven)
        }
        let choices = [24.0, 25.0, 30.0, 50.0, 60.0]
        return choices.min { abs($0 - observed) < abs($1 - observed) }
    }

    /// Match mcp/cutmark_mcp.py:take_clock's two-branch clock selection. FFprobe takes
    /// `round(r_frame_rate)` only when its rate lies in 24...60; otherwise it chooses the
    /// nearest 24/25/30/50/60 to `avg_frame_rate` (default 30). AVFoundation's minimum
    /// frame duration approximates r_frame_rate and its nominal rate approximates the average.
    ///
    /// ScreenCaptureKit produces sparse/VFR MOVs with an invalid or >60 minimum rate. Those
    /// files are perfectly playable; rejecting them made the entire editor preview black.
    /// A fallback is not a fabricated source: it is the *same branch* used by the renderer.
    static func rendererFPS(nominalFrameRate: Double, minFrameDuration: CMTime) -> Double? {
        if minFrameDuration.isNumeric, minFrameDuration > .zero {
            let seconds = minFrameDuration.seconds
            if seconds.isFinite, seconds > 0 {
                let rFrameRate = 1 / seconds
                if rFrameRate.isFinite, rFrameRate >= 24, rFrameRate <= 60 {
                    return rFrameRate.rounded(.toNearestOrEven)
                }
            }
        }
        let average = nominalFrameRate.isFinite && nominalFrameRate > 0 ? nominalFrameRate : 30.0
        let choices = [24.0, 25.0, 30.0, 50.0, 60.0]
        return choices.min { abs($0 - average) < abs($1 - average) }
    }

    /// Port of mcp/cutmark_mcp.py:rounded_cut_for_render. Python round() is ties-to-even, not
    /// Swift's default away-from-zero rounding. Endpoints snap on the source's clock; output length
    /// then snaps on the first *current cut source* clock with the renderer's two-frame minimum.
    static func rendererSpan(segment: Segment, sourceFPS: Double, outputFPS: Double) -> RendererSpan? {
        guard segment.start.isFinite, segment.end.isFinite, segment.end > segment.start,
              sourceFPS.isFinite, sourceFPS > 0, outputFPS.isFinite, outputFPS > 0 else { return nil }
        let a = (segment.start * sourceFPS).rounded(.toNearestOrEven) / sourceFPS
        let b = (segment.end * sourceFPS).rounded(.toNearestOrEven) / sourceFPS
        let frames = max(2, Int(((b - a) * outputFPS).rounded(.toNearestOrEven)))
        return RendererSpan(sourceStart: a, declaredSourceEnd: b,
                            outputDuration: Double(frames) / outputFPS)
    }

    /// Recompute only derived renderer facts. Raw source in/out stay untouched so trim/extend,
    /// draft persistence and the eventual render request keep the user's exact source decisions.
    private mutating func recomputeRenderClock() {
        segments = Self.withRenderClock(segments)
    }

    private static func withRenderClock(_ input: [Segment]) -> [Segment] {
        guard let firstFPS = input.first?.sourceFPS,
              firstFPS.isFinite, firstFPS > 0 else {
            return input.map {
                var s = $0
                s.renderSourceStart = nil
                s.renderDuration = nil
                return s
            }
        }
        return input.map { segment in
            var s = segment
            guard let sourceFPS = segment.sourceFPS,
                  let span = rendererSpan(segment: segment, sourceFPS: sourceFPS, outputFPS: firstFPS)
            else {
                s.renderSourceStart = nil
                s.renderDuration = nil
                return s
            }
            s.renderSourceStart = span.sourceStart
            s.renderDuration = span.outputDuration
            return s
        }
    }

    enum TrimEdge { case start, end }

    /// Pure preview geometry: clamp a mouse drag to this occurrence's recoverable media range.
    /// Pixels may be positive or negative for either handle; the controller never modifies the
    /// movie/recipe during the drag. The same frame limits are enforced again on commit.
    static func trimPreviewOffset(edge: TrimEdge, proposedPixels: Double, segment: Segment,
                                  bounds: Segment, pixelsPerSecond: Double, fps: Double) -> Double {
        guard proposedPixels.isFinite, pixelsPerSecond.isFinite, pixelsPerSecond > 0,
              fps.isFinite, fps > 0 else { return 0 }
        let shrink = max(0, (segment.sourceDuration - 2 / fps) * pixelsPerSecond)
        switch edge {
        case .start:
            return min(shrink, max((bounds.start - segment.start) * pixelsPerSecond, proposedPixels))
        case .end:
            return max(-shrink, min((bounds.end - segment.end) * pixelsPerSecond, proposedPixels))
        }
    }

    /// Each occurrence retains its own recoverable source envelope. Split divides that envelope;
    /// duplicate copies it; move/remove carry it; trim/extend never destroy it. Reconstruct
    /// from source+actions so saved drafts and undo remain backwards compatible.
    func trimBounds(index: Int) -> Segment? {
        guard segments.indices.contains(index) else { return nil }
        var bounds = source
        for a in actions {
            guard bounds.indices.contains(a.index) else { return nil }
            switch a.op {
            case "split":
                guard let at = a.at, at.isFinite else { return nil }
                let span = bounds[a.index]
                guard at >= span.start, at <= span.end else { return nil }
                bounds[a.index].end = at
                bounds.insert(.init(take: span.take, kind: span.kind, start: at, end: span.end,
                                    sourceFPS: span.sourceFPS), at: a.index + 1)
            case "duplicate": bounds.insert(bounds[a.index], at: a.index + 1)
            case "move":
                guard let to = a.to, bounds.indices.contains(to) else { return nil }
                bounds.insert(bounds.remove(at: a.index), at: to)
            case "remove": bounds.remove(at: a.index)
            case "trim", "extend": break
            default: return nil
            }
        }
        guard bounds.count == segments.count else { return nil }
        return bounds[index]
    }

    /// One drag endpoint maps to source seconds; snap to full output frames and keep two frames.
    /// The gesture does not mutate until release, so undo is one atomic timeline action.
    func trimProposal(index: Int, edge: TrimEdge, dragSeconds: Double) -> Action? {
        guard segments.indices.contains(index), dragSeconds.isFinite, fps.isFinite, fps > 0,
              let bounds = trimBounds(index: index) else { return nil }
        let s = segments[index]
        let frame = 1 / fps
        // Moving away and back to the initial edge within one gesture makes no history entry.
        guard abs(dragSeconds) >= frame / 2 else { return nil }
        switch edge {
        case .start:
            let value = min(s.end - 2 * frame, max(bounds.start, ((s.start + dragSeconds) * fps).rounded() / fps))
            guard abs(value - s.start) >= frame / 2 else { return nil }
            return Action(op: value < s.start ? "extend" : "trim", index: index, in: value, out: s.end)
        case .end:
            let value = max(s.start + 2 * frame, min(bounds.end, ((s.end + dragSeconds) * fps).rounded() / fps))
            guard abs(value - s.end) >= frame / 2 else { return nil }
            return Action(op: value > s.end ? "extend" : "trim", index: index, in: s.start, out: value)
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
                return (index, (segment.renderSourceStart ?? segment.start) + local - cursor)
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
                return elapsed + (selected.renderSourceStart ?? selected.start)
                    - (original.renderSourceStart ?? original.start)
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
        guard let session = sessionRoot(for: video),
              let meta = Store.readMeta(session) else { return nil }
        let root = session.standardizedFileURL.resolvingSymlinksInPath()
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        var clocks: [String: Double] = [:]
        var segments: [Segment] = []
        for g in cuts {
            guard let take = (g["take"] as? NSNumber)?.intValue,
                  let start = (g["in"] as? NSNumber)?.doubleValue,
                  let end = (g["out"] as? NSNumber)?.doubleValue,
                  end > start,
                  let kind = TakeKind(rawValue: g["kind"] as? String ?? "camera")
            else { return nil }
            let key = "\(take):\(kind.rawValue)"
            let sourceFPS: Double
            if let cached = clocks[key] {
                sourceFPS = cached
            } else {
                guard let sourceTake = meta.takes.last(where: { $0.number == take && $0.kind == kind }),
                      !sourceTake.file.isEmpty else { return nil }
                let sourceURL = root.appending(path: sourceTake.file).standardizedFileURL.resolvingSymlinksInPath()
                guard sourceURL.path.hasPrefix(rootPath),
                      FileManager.default.fileExists(atPath: sourceURL.path),
                      let track = AVURLAsset(url: sourceURL).tracks(withMediaType: .video).first,
                      let resolved = rendererFPS(nominalFrameRate: Double(track.nominalFrameRate),
                                                 minFrameDuration: track.minFrameDuration)
                else { return nil }
                clocks[key] = resolved
                sourceFPS = resolved
            }
            segments.append(Segment(take: take, kind: kind.rawValue, start: start, end: end,
                                    sourceFPS: sourceFPS))
        }
        return EditTimelineDraft(base: "edits/" + video.lastPathComponent, fps: fps,
                                 source: segments, segments: segments)
    }

    private static func sessionRoot(for video: URL) -> URL? {
        let folder = video.deletingLastPathComponent().standardizedFileURL
        if folder.lastPathComponent == "edits" {
            return folder.deletingLastPathComponent().standardizedFileURL
        }
        return folder
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
            segments.insert(Segment(take: item.take, kind: item.kind, start: at, end: item.end,
                                    sourceFPS: item.sourceFPS), at: index + 1)
        case "trim", "extend":
            let start = action.in ?? item.start, end = action.out ?? item.end
            guard start.isFinite, end.isFinite, end - start >= minDuration else { return false }
            if action.op == "trim" {
                guard start >= item.start, end <= item.end else { return false }
            } else {
                guard let bounds = trimBounds(index: index), start >= bounds.start,
                      end <= bounds.end, start <= item.start, end >= item.end,
                      start < item.start || end > item.end else { return false }
            }
            segments[index].start = start
            segments[index].end = end
        default:
            return false
        }
        actions.append(action)
        recomputeRenderClock()
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
