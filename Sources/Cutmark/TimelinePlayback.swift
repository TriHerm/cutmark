import AVFoundation
import CoreGraphics
import Foundation

/// Builds an in-memory preview of the current timeline draft from the immutable recorded takes.
/// Nothing is rendered or written: AVPlayer reads the same source files that render_edit will cut.
@MainActor
enum TimelinePlayback {
    enum Failure: LocalizedError {
        case emptyTimeline
        case invalidFrameRate(Double)
        case missingSessionMetadata
        case invalidSource(take: Int, kind: String)
        case missingSource(take: Int, kind: String)
        case sourceOutsideSession(String)
        case missingVideo(String)
        case invalidRange(take: Int, start: Double, end: Double)
        case rangeOutsideSource(take: Int, end: Double, duration: Double)
        case unresolvedSourceFrameRate(take: Int)
        case sourceFrameRateChanged(take: Int, expected: Double, actual: Double)

        var errorDescription: String? {
            switch self {
            case .emptyTimeline:
                return "The timeline has no clips to preview."
            case .invalidFrameRate(let fps):
                return "The timeline frame rate \(fps) is invalid."
            case .missingSessionMetadata:
                return "The session metadata is unavailable."
            case .invalidSource(let take, let kind):
                return "Take \(take) has an invalid source kind “\(kind)”."
            case .missingSource(let take, let kind):
                return "Take \(take) \(kind) is unavailable in this session."
            case .sourceOutsideSession(let file):
                return "The take source “\(file)” is outside this session."
            case .missingVideo(let file):
                return "The take source “\(file)” has no playable video track."
            case .invalidRange(let take, let start, let end):
                return String(format: "Take %d has an invalid preview range %.3f–%.3f s.", take, start, end)
            case .rangeOutsideSource(let take, let end, let duration):
                return String(format: "Take %d is %.3f s long; the preview asks for %.3f s.", take, duration, end)
            case .unresolvedSourceFrameRate(let take):
                return "Take \(take) has an uncertain source frame rate, so Cutmark cannot promise an exact preview."
            case .sourceFrameRateChanged(let take, let expected, let actual):
                return String(format: "Take %d changed frame rate (timeline %.0f fps, source %.0f fps). Reopen the editor.", take, expected, actual)
            }
        }
    }

    private struct SourceKey: Hashable {
        let take: Int
        let kind: TakeKind
    }

    private struct LoadedSource {
        let url: URL
        let asset: AVURLAsset
        let duration: CMTime
        let video: AVAssetTrack
        let videoRange: CMTimeRange
        let naturalSize: CGSize
        let preferredTransform: CGAffineTransform
        let audio: [(track: AVAssetTrack, range: CMTimeRange)]
        let sourceFPS: Double
    }

    private struct VideoSlice {
        let range: CMTimeRange
        let naturalSize: CGSize
        let preferredTransform: CGAffineTransform
    }

    /// A truthful cut preview. Each draft segment is read from the current session take file,
    /// trimmed on its source clock and concatenated in draft order. Audio follows the same ranges.
    /// Published media is never used as an input and no file is created or changed.
    static func playerItem(draft: EditTimelineDraft, session: URL) async throws -> AVPlayerItem {
        try Task.checkCancellation()
        guard !draft.segments.isEmpty else { throw Failure.emptyTimeline }
        guard draft.fps.isFinite, draft.fps > 0 else { throw Failure.invalidFrameRate(draft.fps) }
        guard let meta = Store.readMeta(session) else { throw Failure.missingSessionMetadata }

        let root = session.standardizedFileURL.resolvingSymlinksInPath()
        var takes: [SourceKey: Take] = [:]
        for take in meta.takes {
            // A healthy session has one file per number/kind. If recovery left a duplicate,
            // prefer the newest metadata entry rather than trapping while constructing a Dictionary.
            takes[SourceKey(take: take.number, kind: take.kind)] = take
        }

        var loaded: [SourceKey: LoadedSource] = [:]
        var requested: [(segment: EditTimelineDraft.Segment, source: LoadedSource)] = []
        requested.reserveCapacity(draft.segments.count)

        for segment in draft.segments {
            try Task.checkCancellation()
            guard segment.start.isFinite, segment.end.isFinite, segment.start >= 0, segment.end > segment.start else {
                throw Failure.invalidRange(take: segment.take, start: segment.start, end: segment.end)
            }
            guard let kind = TakeKind(rawValue: segment.kind) else {
                throw Failure.invalidSource(take: segment.take, kind: segment.kind)
            }
            let key = SourceKey(take: segment.take, kind: kind)
            let source: LoadedSource
            if let cached = loaded[key] {
                source = cached
            } else {
                guard let take = takes[key] else { throw Failure.missingSource(take: segment.take, kind: segment.kind) }
                let url = try sourceURL(file: take.file, session: root)
                let asset = AVURLAsset(url: url)
                let duration = try await asset.load(.duration)
                guard duration.isNumeric, duration > .zero else { throw Failure.missingVideo(take.file) }
                guard let video = try await asset.loadTracks(withMediaType: .video).first else {
                    throw Failure.missingVideo(take.file)
                }
                let (videoRange, naturalSize, preferredTransform) = try await video.load(.timeRange, .naturalSize, .preferredTransform)
                let (nominalFrameRate, minFrameDuration) = try await video.load(.nominalFrameRate, .minFrameDuration)
                guard let sourceFPS = EditTimelineDraft.rendererFPS(
                    nominalFrameRate: Double(nominalFrameRate), minFrameDuration: minFrameDuration) else {
                    throw Failure.unresolvedSourceFrameRate(take: segment.take)
                }
                var audio: [(AVAssetTrack, CMTimeRange)] = []
                for track in try await asset.loadTracks(withMediaType: .audio) {
                    audio.append((track, try await track.load(.timeRange)))
                }
                try Task.checkCancellation()
                source = LoadedSource(url: url, asset: asset, duration: duration, video: video,
                                      videoRange: videoRange, naturalSize: naturalSize,
                                      preferredTransform: preferredTransform, audio: audio,
                                      sourceFPS: sourceFPS)
                loaded[key] = source
            }

            if let expected = segment.sourceFPS, abs(expected - source.sourceFPS) > 0.001 {
                throw Failure.sourceFrameRateChanged(take: segment.take, expected: expected, actual: source.sourceFPS)
            }
            let end = CMTime(seconds: segment.end, preferredTimescale: 60_000)
            // Permit only sub-frame metadata drift; never silently preview a materially shorter clip.
            let tolerance = CMTime(seconds: 1 / max(1, source.sourceFPS), preferredTimescale: 60_000)
            if end > source.duration + tolerance {
                throw Failure.rangeOutsideSource(take: segment.take, end: segment.end, duration: source.duration.seconds)
            }
            requested.append((segment, source))
        }
        guard let outputFPS = requested.first?.source.sourceFPS else { throw Failure.emptyTimeline }

        let composition = AVMutableComposition()
        guard let videoTrack = composition.addMutableTrack(withMediaType: .video,
                                                           preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw Failure.emptyTimeline
        }
        var audioTracks: [AVMutableCompositionTrack] = []
        var slices: [VideoSlice] = []
        var cursor = CMTime.zero

        for (segment, source) in requested {
            try Task.checkCancellation()
            guard let span = EditTimelineDraft.rendererSpan(segment: segment,
                                                            sourceFPS: source.sourceFPS,
                                                            outputFPS: outputFPS) else {
                throw Failure.invalidRange(take: segment.take, start: segment.start, end: segment.end)
            }
            let start = CMTime(seconds: span.sourceStart, preferredTimescale: 60_000)
            let duration = CMTime(seconds: span.outputDuration, preferredTimescale: 60_000)
            let wanted = CMTimeRange(start: start, duration: duration)
            let videoOverlap = CMTimeRangeGetIntersection(wanted, otherRange: source.videoRange)
            let missingVideo = CMTimeAbsoluteValue(videoOverlap.duration - duration)
            let tolerance = CMTime(seconds: 1 / max(1, outputFPS), preferredTimescale: 60_000)
            guard videoOverlap.duration > .zero, missingVideo <= tolerance else {
                throw Failure.rangeOutsideSource(take: segment.take,
                                                 end: span.sourceStart + span.outputDuration,
                                                 duration: source.duration.seconds)
            }

            // A tiny track-start offset is represented as a tiny blank lead rather than shifting the edit clock.
            let videoOffset = max(.zero, videoOverlap.start - wanted.start)
            try videoTrack.insertTimeRange(videoOverlap, of: source.video, at: cursor + videoOffset)
            slices.append(VideoSlice(range: CMTimeRange(start: cursor, duration: duration),
                                     naturalSize: source.naturalSize,
                                     preferredTransform: source.preferredTransform))

            while audioTracks.count < source.audio.count {
                guard let track = composition.addMutableTrack(withMediaType: .audio,
                                                               preferredTrackID: kCMPersistentTrackID_Invalid) else { break }
                if cursor > .zero { track.insertEmptyTimeRange(CMTimeRange(start: .zero, duration: cursor)) }
                audioTracks.append(track)
            }
            for index in audioTracks.indices {
                guard source.audio.indices.contains(index) else {
                    audioTracks[index].insertEmptyTimeRange(CMTimeRange(start: cursor, duration: duration))
                    continue
                }
                let audio = source.audio[index]
                let overlap = CMTimeRangeGetIntersection(wanted, otherRange: audio.range)
                guard overlap.duration > .zero else {
                    audioTracks[index].insertEmptyTimeRange(CMTimeRange(start: cursor, duration: duration))
                    continue
                }
                let offset = max(.zero, overlap.start - wanted.start)
                try audioTracks[index].insertTimeRange(overlap, of: audio.track, at: cursor + offset)
            }
            cursor = cursor + duration
        }

        // A first-time raw edit uses the first kept shot's native frame. For a published edit,
        // render_edit preserves the base recipe's fixed frame even after moving a different
        // resolution/aspect take to the front. Match that fixed output instead of changing
        // the apparent canvas with every reorder.
        let fallbackCanvas = orientedSize(naturalSize: slices[0].naturalSize,
                                          transform: slices[0].preferredTransform)
        let canvas = await publishedCanvas(draft: draft, session: session) ?? fallbackCanvas
        guard canvas.width > 0, canvas.height > 0 else { throw Failure.missingVideo(requested[0].source.url.lastPathComponent) }
        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = canvas
        videoComposition.frameDuration = CMTime(seconds: 1 / max(1, outputFPS), preferredTimescale: 60_000)
        videoComposition.instructions = slices.map { slice in
            let instruction = AVMutableVideoCompositionInstruction()
            instruction.timeRange = slice.range
            let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTrack)
            layer.setTransform(fittedTransform(naturalSize: slice.naturalSize,
                                               preferredTransform: slice.preferredTransform,
                                               canvas: canvas), at: slice.range.start)
            instruction.layerInstructions = [layer]
            return instruction
        }

        let item = AVPlayerItem(asset: composition)
        item.videoComposition = videoComposition
        return item
    }

    private static func publishedCanvas(draft: EditTimelineDraft, session: URL) async -> CGSize? {
        guard !draft.isRawTake, draft.base.hasPrefix("edits/") else { return nil }
        let name = String(draft.base.dropFirst("edits/".count))
        guard !name.isEmpty, !name.contains("/"), name != ".", name != ".." else { return nil }
        let root = session.standardizedFileURL.resolvingSymlinksInPath()
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        let folder = root.appending(path: "edits").resolvingSymlinksInPath()
        guard folder.path.hasPrefix(rootPath) else { return nil }
        let edit = folder.appending(path: name).resolvingSymlinksInPath()
        let folderPath = folder.path.hasSuffix("/") ? folder.path : folder.path + "/"
        guard edit.path.hasPrefix(folderPath),
              EditRecipe.url(for: edit).resolvingSymlinksInPath().path.hasPrefix(rootPath)
        else { return nil }
        if let recipe = EditRecipe.read(edit), let frame = recipe["frame"] as? [String: Any],
           let w = frame["w"] as? NSNumber, let h = frame["h"] as? NSNumber,
           w.intValue >= 2, h.intValue >= 2, w.intValue <= 8192, h.intValue <= 8192 {
            return CGSize(width: w.intValue, height: h.intValue)
        }
        // Legacy published versions may have a recipe without explicit frame dimensions.
        // Their encoded movie is more authoritative than a newly reordered first raw take.
        guard FileManager.default.fileExists(atPath: edit.path) else { return nil }
        let movie = AVURLAsset(url: edit)
        guard let track = try? await movie.loadTracks(withMediaType: .video).first,
              let props = try? await track.load(.naturalSize, .preferredTransform) else { return nil }
        let size = orientedSize(naturalSize: props.0, transform: props.1)
        return size.width >= 2 && size.height >= 2 ? size : nil
    }

    /// Raw AVFoundation preview reproduces cuts and source audio, not render-only processing.
    /// The editor can show this beside the preview without blocking non-destructive editing.
    static func limitation(draft: EditTimelineDraft, session: URL) -> String? {
        guard !draft.isRawTake else { return nil }
        let generic = "Cut preview uses the recorded takes. Published effects, overlays, captions, framing, music, or processed voice may differ until this draft is rendered."
        guard draft.base.hasPrefix("edits/") else { return generic }
        let edit = session.appending(path: draft.base)
        guard let recipe = EditRecipe.read(edit) else { return generic }
        let renderOnly = ["auto_zoom", "over", "music", "sfx", "style", "steps", "cover", "loudness", "voice"]
        if renderOnly.contains(where: { recipe[$0] != nil }) { return generic }
        if let frame = recipe["frame"] as? [String: Any],
           frame["crop"] != nil || (frame["shape"] as? String).map({ $0 != "source" }) == true {
            return generic
        }
        return nil
    }

    static func sourceURL(file: String, session: URL) throws -> URL {
        guard !file.isEmpty else { throw Failure.sourceOutsideSession(file) }
        let root = session.standardizedFileURL.resolvingSymlinksInPath()
        let source = root.appending(path: file).standardizedFileURL.resolvingSymlinksInPath()
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard source.path.hasPrefix(rootPath), FileManager.default.fileExists(atPath: source.path) else {
            if source.path.hasPrefix(rootPath) { throw Failure.missingVideo(file) }
            throw Failure.sourceOutsideSession(file)
        }
        return source
    }

    static func orientedSize(naturalSize: CGSize, transform: CGAffineTransform) -> CGSize {
        let rect = CGRect(origin: .zero, size: naturalSize).applying(transform)
        return CGSize(width: abs(rect.width), height: abs(rect.height))
    }

    static func fittedTransform(naturalSize: CGSize, preferredTransform: CGAffineTransform,
                                canvas: CGSize) -> CGAffineTransform {
        let transformed = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform)
        let oriented = CGSize(width: abs(transformed.width), height: abs(transformed.height))
        guard oriented.width > 0, oriented.height > 0, canvas.width > 0, canvas.height > 0 else {
            return preferredTransform
        }
        let normalize = CGAffineTransform(translationX: -transformed.minX, y: -transformed.minY)
        let scale = min(canvas.width / oriented.width, canvas.height / oriented.height)
        let fitted = CGSize(width: oriented.width * scale, height: oriented.height * scale)
        let center = CGAffineTransform(translationX: (canvas.width - fitted.width) / 2,
                                       y: (canvas.height - fitted.height) / 2)
        return preferredTransform.concatenating(normalize)
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(center)
    }
}
