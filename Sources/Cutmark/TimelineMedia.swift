import AVFoundation
import Combine
import CoreGraphics
import Foundation

/// One real frame sampled from a clip's source range. `sourceTime` stays on the take's clock so
/// the timeline can map a visible frame back to split and trim operations without guessing.
struct TimelineThumbnail {
    let sourceTime: Double
    let image: CGImage
}

enum TimelineMediaError: Error {
    case invalidRange
    case unreadable
}

/// Lightweight, read-only media sampling for the timeline. Nothing is cached on disk: samples
/// exist only while the editor is open, and every read stays inside the selected session.
enum TimelineMedia {
    private static let maximumThumbnailsPerRequest = 48
    private static let maximumWaveformSamplesPerRequest = 2_048
    private static let waveformSampleRate = 8_000.0

    /// Resolve a recipe segment through session.json first, because named takes no longer have the
    /// canonical `take-03-camera.mov` spelling. The fallback keeps recovered older sessions useful.
    static func sourceURL(for segment: EditTimelineDraft.Segment, session: URL) -> URL? {
        guard segment.take > 0, let kind = TakeKind(rawValue: segment.kind) else { return nil }
        let root = session.standardizedFileURL.resolvingSymlinksInPath()
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        let metadata = root.appending(path: "session.json").standardizedFileURL.resolvingSymlinksInPath()
        let take = metadata.path.hasPrefix(rootPath)
            ? Store.readMeta(root)?.takes.first { $0.number == segment.take && $0.kind == kind }
            : nil

        func resolvedSource(_ name: String) -> URL? {
            guard !name.isEmpty else { return nil }
            let candidate = root.appending(path: name).standardizedFileURL.resolvingSymlinksInPath()
            guard candidate.path.hasPrefix(rootPath), FileManager.default.fileExists(atPath: candidate.path) else {
                return nil
            }
            return candidate
        }

        // session.json is authoritative when it has this take. If that exact file is gone or
        // unsafe, show no media rather than silently substituting a stale canonical recording.
        if let take { return resolvedSource(take.file) }
        // SessionDoc.takeFile is @MainActor due to the UI-facing session model. This pure
        // fallback runs safely off-main, with the exact same two-digit canonical spelling.
        return resolvedSource(String(format: "take-%02d-%@.mov", segment.take, kind.rawValue))
    }

    /// Sample evenly across a source interval. Work is capped even when a caller accidentally asks
    /// for hundreds of images, and actual returned frame times are preserved for source alignment.
    static func thumbnails(url: URL, start: Double, end: Double, imageCount: Int) async throws -> [TimelineThumbnail] {
        guard start.isFinite, end.isFinite, end > start, imageCount > 0 else { throw TimelineMediaError.invalidRange }
        let count = min(imageCount, maximumThumbnailsPerRequest)
        let task = Task.detached(priority: .utility) { () async throws -> [TimelineThumbnail] in
            try Task.checkCancellation()
            let asset = AVURLAsset(url: url)
            let assetDuration = try await asset.load(.duration).seconds
            guard assetDuration.isFinite, assetDuration > 0 else { throw TimelineMediaError.unreadable }
            let lower = max(0, start)
            let upper = min(end, assetDuration)
            guard upper > lower else { throw TimelineMediaError.invalidRange }

            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            // Without maximumSize a 4K/5K screen frame costs tens of MB, and a short timeline
            // could retain >1 GB of decoded CGImages despite its bounded thumbnail count.
            generator.maximumSize = CGSize(width: 256, height: 160)
            let step = (upper - lower) / Double(count)
            let tolerance = CMTime(seconds: min(0.2, max(1.0 / 600.0, step * 0.4)), preferredTimescale: 600)
            generator.requestedTimeToleranceBefore = tolerance
            generator.requestedTimeToleranceAfter = tolerance

            var result: [TimelineThumbnail] = []
            result.reserveCapacity(count)
            for index in 0..<count {
                try Task.checkCancellation()
                // Bin centres avoid requesting the exact trailing boundary, where some containers
                // legitimately have no decodable frame.
                let requested = lower + (Double(index) + 0.5) * step
                do {
                    let sampled = try await generator.image(
                        at: CMTime(seconds: requested, preferredTimescale: 600))
                    let sourceTime = sampled.actualTime.seconds.isFinite ? sampled.actualTime.seconds : requested
                    result.append(TimelineThumbnail(sourceTime: sourceTime, image: sampled.image))
                } catch {
                    // One corrupt GOP should leave a gap, not make every other clip lose its strip.
                    continue
                }
            }
            try Task.checkCancellation()
            return result
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// Read the source audio as mono float PCM and peak-bin it directly against source timestamps.
    /// Values use a fixed -60 dB...0 dB scale, so quiet and loud clips remain comparable instead of
    /// each segment being normalized to look equally loud. A silent/missing track returns no shape.
    static func waveform(url: URL, start: Double, end: Double, sampleCount: Int) async throws -> [CGFloat] {
        guard start.isFinite, end.isFinite, end > start, sampleCount > 0 else { throw TimelineMediaError.invalidRange }
        let count = min(sampleCount, maximumWaveformSamplesPerRequest)
        let task = Task.detached(priority: .utility) { () async throws -> [CGFloat] in
            try Task.checkCancellation()
            let asset = AVURLAsset(url: url)
            guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return [] }
            let assetDuration = try await asset.load(.duration).seconds
            guard assetDuration.isFinite, assetDuration > 0 else { throw TimelineMediaError.unreadable }
            let lower = max(0, start)
            let upper = min(end, assetDuration)
            guard upper > lower else { throw TimelineMediaError.invalidRange }

            let reader = try AVAssetReader(asset: asset)
            reader.timeRange = CMTimeRange(
                start: CMTime(seconds: lower, preferredTimescale: 60_000),
                duration: CMTime(seconds: upper - lower, preferredTimescale: 60_000))
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: waveformSampleRate,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ]
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
            guard reader.canAdd(output) else { throw TimelineMediaError.unreadable }
            reader.add(output)
            guard reader.startReading(),
                  let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                             sampleRate: waveformSampleRate,
                                             channels: 1, interleaved: true) else {
                throw reader.error ?? TimelineMediaError.unreadable
            }

            let span = upper - lower
            var peaks = Array(repeating: Float.zero, count: count)
            while let sample = output.copyNextSampleBuffer() {
                try Task.checkCancellation()
                let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sample))
                guard frames > 0,
                      let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { continue }
                buffer.frameLength = frames
                guard CMSampleBufferCopyPCMDataIntoAudioBufferList(
                    sample, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList) == noErr,
                    let values = buffer.floatChannelData?[0] else { continue }

                let pts = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                let bufferStart = pts.isFinite ? pts : lower
                for frame in 0..<Int(frames) {
                    let sourceTime = bufferStart + Double(frame) / waveformSampleRate
                    let relative = (sourceTime - lower) / span
                    guard relative >= 0, relative < 1 else { continue }
                    let bin = min(count - 1, Int(relative * Double(count)))
                    let magnitude = abs(values[frame])
                    if magnitude.isFinite { peaks[bin] = max(peaks[bin], magnitude) }
                }
            }
            if reader.status == .failed { throw reader.error ?? TimelineMediaError.unreadable }
            try Task.checkCancellation()

            return peaks.map { peak in
                guard peak > 0 else { return 0 }
                let db = 20.0 * log10(Double(min(1, peak)))
                return CGFloat(min(1, max(0, (db + 60.0) / 60.0)))
            }
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }
}

/// Bounded editor-level cache. It publishes once per completed clip instead of streaming hundreds
/// of tiny updates through SwiftUI, and a new load cancels the previous session immediately.
@MainActor
final class TimelineMediaCache: ObservableObject {
    @Published private(set) var thumbnails: [Int: [TimelineThumbnail]] = [:]
    @Published private(set) var waveform: [Int: [CGFloat]] = [:]
    @Published private(set) var isLoading = false

    private var loadTask: Task<Void, Never>?
    private var generation = 0

    func load(draft: EditTimelineDraft, session: URL) async {
        cancel()
        thumbnails = [:]
        waveform = [:]
        isLoading = true
        generation += 1
        let mine = generation

        let totalDuration = max(0.001, draft.duration)
        let thumbnailBudget = min(72, max(draft.segments.count, Int(ceil(totalDuration / 1.25))))
        let waveformBudget = min(4_096, max(draft.segments.count * 24, Int(ceil(totalDuration * 40))))

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            for (index, segment) in draft.segments.enumerated() {
                guard !Task.isCancelled, self.generation == mine else { return }
                guard let url = TimelineMedia.sourceURL(for: segment, session: session) else { continue }
                let share = segment.duration / totalDuration
                let imageCount = min(12, max(1, Int(ceil(Double(thumbnailBudget) * share))))
                let sampleCount = min(512, max(24, Int(ceil(Double(waveformBudget) * share))))

                async let sampledThumbnails = try? TimelineMedia.thumbnails(
                    url: url, start: segment.start, end: segment.end, imageCount: imageCount)
                async let sampledWaveform = try? TimelineMedia.waveform(
                    url: url, start: segment.start, end: segment.end, sampleCount: sampleCount)
                let (frames, amplitudes) = await (sampledThumbnails, sampledWaveform)

                guard !Task.isCancelled, self.generation == mine else { return }
                if let frames, !frames.isEmpty { self.thumbnails[index] = frames }
                if let amplitudes, !amplitudes.isEmpty { self.waveform[index] = amplitudes }
            }
        }
        loadTask = task
        await task.value
        if generation == mine {
            isLoading = false
            loadTask = nil
        }
    }

    func cancel() {
        generation += 1
        loadTask?.cancel()
        loadTask = nil
        isLoading = false
    }

    deinit {
        loadTask?.cancel()
    }
}
