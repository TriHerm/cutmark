import AppKit
import AVFoundation
import CoreVideo
import CryptoKit

/// One AVFoundation composition feeds both AVPlayer and export, including stills, speed and mixing.
enum MediaEditComposition {
    struct Result {
        let asset: AVMutableComposition
        let video: AVMutableVideoComposition
        let audio: AVMutableAudioMix
        let duration: Double
        func item() -> AVPlayerItem {
            let item = AVPlayerItem(asset: asset)
            item.videoComposition = video; item.audioMix = audio; item.audioTimePitchAlgorithm = .spectral
            return item
        }
    }
    static func size(_ format: MediaEditProject.Format) -> CGSize {
        switch format { case .landscape: CGSize(width: 1920, height: 1080)
        case .portrait: CGSize(width: 1080, height: 1920)
        case .square: CGSize(width: 1080, height: 1080) }
    }
    static func time(_ seconds: Double) -> CMTime { CMTime(seconds: seconds, preferredTimescale: 60000) }
    private struct Visual {
        let start: Double
        let end: Double
        let overlay: Bool
        let layer: AVMutableVideoCompositionLayerInstruction
    }
    static func build(_ project: MediaEditProject, session: URL) async throws -> Result {
        try project.validate()
        guard project.duration >= 1 / 30 else { throw MediaEditProject.Failure.invalid("Add a video or image to the main video track first.") }
        let composition = AVMutableComposition(), canvas = size(project.format)
        var visuals: [Visual] = [], audioParameters: [AVAudioMixInputParameters] = []
        for clip in project.clips {
            try Task.checkCancellation()
            let position = project.position(clip.id), length = min(clip.duration, project.duration - position)
            guard length > 0 else { continue }
            let original = try MediaEditProject.source(clip.file, session: session)
            let url = clip.kind == .image ? try await stillMovie(original, session: session) : original
            let asset = AVURLAsset(url: url)
            let sourceDuration = try await asset.load(.duration).seconds
            let sourceStart = clip.kind == .image ? 0 : clip.start
            let sourceLength = clip.kind == .image ? sourceDuration : length * clip.speed
            guard sourceDuration.isFinite, sourceStart + sourceLength <= sourceDuration + 0.04 else {
                throw MediaEditProject.Failure.invalid("\(clip.name) changed or is shorter than its saved trim. Re-import it before continuing.")
            }
            let requested = CMTimeRange(start: time(sourceStart), duration: time(sourceLength))
            let at = time(position), outputLength = time(length)
            if clip.kind != .audio {
                guard let track = try await asset.loadTracks(withMediaType: .video).first,
                      let destination = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
                else { throw MediaEditProject.Failure.invalid("No readable video in \(clip.name).") }
                let (natural, preferred) = try await track.load(.naturalSize, .preferredTransform)
                try destination.insertTimeRange(requested, of: track, at: at)
                destination.scaleTimeRange(CMTimeRange(start: at, duration: requested.duration), toDuration: outputLength)
                let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: destination)
                let target: CGRect
                if clip.lane == .overlay {
                    let width = canvas.width * clip.overlaySize, height = canvas.height * clip.overlaySize
                    target = CGRect(x: clip.overlayLeft ? canvas.width * 0.04 : canvas.width - width - canvas.width * 0.04, y: clip.overlayBottom ? canvas.height - height - canvas.height * 0.04 : canvas.height * 0.04, width: width, height: height)
                } else { target = CGRect(origin: .zero, size: canvas) }
                let base = transform(size: natural, preferred: preferred, target: target, fill: clip.fill, zoom: clip.zoom, focusX: clip.focusX, focusY: clip.focusY)
                layer.setTransform(base, at: at)
                if clip.lane == .overlay {
                    let crop = target.applying(base.inverted()).intersection(CGRect(origin: .zero, size: natural))
                    layer.setCropRectangle(crop, at: at)
                }
                if clip.autoZoom, clip.lane == .video,
                   let take = Store.readMeta(session)?.takes.first(where: { $0.file == clip.file && $0.kind == .screen }) {
                    let events = CaptureEventLog.read(CaptureEventLog.url(in: session, take: take.number), through: clip.end)
                    for suggestion in AutoZoomPlanner.suggestions(events: events, take: take.number, through: clip.end)
                    where suggestion.sourceTrigger >= clip.start && suggestion.sourceTrigger < clip.start + length * clip.speed {
                        let begin = max(0, (suggestion.sourceIn - clip.start) / clip.speed)
                        let finish = min(length, (suggestion.sourceOut - clip.start) / clip.speed)
                        guard finish - begin >= 0.2 else { continue }
                        let ease = min(0.22, (finish - begin) / 3)
                        let focused = transform(size: natural, preferred: preferred, target: target, fill: clip.fill,
                                                zoom: max(clip.zoom, suggestion.scale), focusX: suggestion.focusX, focusY: suggestion.focusY)
                        layer.setTransformRamp(fromStart: base, toEnd: focused, timeRange: CMTimeRange(start: time(position + begin), duration: time(ease)))
                        layer.setTransform(focused, at: time(position + begin + ease))
                        layer.setTransformRamp(fromStart: focused, toEnd: base, timeRange: CMTimeRange(start: time(position + finish - ease), duration: time(ease)))
                    }
                }
                visuals.append(Visual(start: position, end: position + length, overlay: clip.lane == .overlay, layer: layer))
            }
            if clip.kind != .image, let sourceAudio = try await asset.loadTracks(withMediaType: .audio).first,
               let destination = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                let range = try await sourceAudio.load(.timeRange)
                let overlap = CMTimeRangeGetIntersection(requested, otherRange: range)
                if overlap.duration > .zero {
                    let offset = (overlap.start - requested.start).seconds / clip.speed
                    let audioAt = time(position + offset)
                    try destination.insertTimeRange(overlap, of: sourceAudio, at: audioAt)
                    destination.scaleTimeRange(CMTimeRange(start: audioAt, duration: overlap.duration), toDuration: time(overlap.duration.seconds / clip.speed))
                    let mix = AVMutableAudioMixInputParameters(track: destination)
                    mix.audioTimePitchAlgorithm = .spectral
                    mix.setVolume(Float(clip.volume), at: at)
                    let fadeIn = min(clip.fadeIn, length / 2), fadeOut = min(clip.fadeOut, length / 2)
                    if fadeIn > 0 { mix.setVolumeRamp(fromStartVolume: 0, toEndVolume: Float(clip.volume), timeRange: CMTimeRange(start: at, duration: time(fadeIn))) }
                    if fadeOut > 0 { mix.setVolumeRamp(fromStartVolume: Float(clip.volume), toEndVolume: 0, timeRange: CMTimeRange(start: time(position + length - fadeOut), duration: time(fadeOut))) }
                    audioParameters.append(mix)
                }
            }
        }
        let boundaries = Array(Set([0, project.duration] + visuals.flatMap { [$0.start, $0.end] })).sorted()
        var instructions: [AVVideoCompositionInstructionProtocol] = []
        for (start, end) in zip(boundaries, boundaries.dropFirst()) where end > start {
            let instruction = AVMutableVideoCompositionInstruction()
            instruction.timeRange = CMTimeRange(start: time(start), duration: time(end - start))
            instruction.backgroundColor = NSColor.black.cgColor
            let active = visuals.filter { $0.start <= start + 0.00001 && $0.end > start + 0.00001 }
            instruction.layerInstructions = active.filter(\.overlay).reversed().map(\.layer) + active.filter { !$0.overlay }.map(\.layer)
            instructions.append(instruction)
        }
        let video = AVMutableVideoComposition()
        video.renderSize = canvas; video.frameDuration = CMTime(value: 1, timescale: 30); video.instructions = instructions
        let audio = AVMutableAudioMix(); audio.inputParameters = audioParameters
        return Result(asset: composition, video: video, audio: audio, duration: project.duration)
    }
    static func transform(size: CGSize, preferred: CGAffineTransform, target: CGRect, fill: Bool, zoom: Double, focusX: Double = 0.5, focusY: Double = 0.5) -> CGAffineTransform {
        let upright = CGRect(origin: .zero, size: size).applying(preferred)
        let scale = (fill ? max(target.width / upright.width, target.height / upright.height) : min(target.width / upright.width, target.height / upright.height)) * zoom
        let dx = target.minX + min(0, target.width - upright.width * scale) * focusX + max(0, target.width - upright.width * scale) / 2
        let dy = target.minY + min(0, target.height - upright.height * scale) * focusY + max(0, target.height - upright.height * scale) / 2
        return preferred.concatenating(CGAffineTransform(translationX: -upright.minX, y: -upright.minY))
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: dx, y: dy))
    }
    /// Cache a one-second still source, then scale its timeline duration without making duplicate files per trim.
    private static func stillMovie(_ image: URL, session: URL) async throws -> URL {
        let attrs = try image.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let key = SHA256.hash(data: Data(("alpha-v1|" + image.path + "|\(attrs.fileSize ?? 0)|\(attrs.contentModificationDate?.timeIntervalSince1970 ?? 0)").utf8)).map { String(format: "%02x", $0) }.joined()
        let directory = session.appending(path: "_edit/studio/stills")
        guard directory.resolvingSymlinksInPath().path.hasPrefix(session.resolvingSymlinksInPath().path + "/") else { throw MediaEditProject.Failure.invalid("The cache folder is outside this session.") }
        _ = try MediaEditProject.directory("_edit/studio/stills", in: session)
        let target = directory.appending(path: String(key) + ".mov")
        if FileManager.default.fileExists(atPath: target.path) { return target }
        guard let imageSource = CGImageSourceCreateWithURL(image as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 1920, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary)
        else { throw MediaEditProject.Failure.invalid("Cannot read \(image.lastPathComponent).") }
        let width = max(2, cg.width / 2 * 2), height = max(2, cg.height / 2 * 2)
        let temporary = directory.appending(path: UUID().uuidString + ".mov")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let writer = try AVAssetWriter(outputURL: temporary, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.proRes4444, AVVideoWidthKey: width, AVVideoHeightKey: height])
        let adapter = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB, kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height, kCVPixelBufferCGImageCompatibilityKey as String: true, kCVPixelBufferCGBitmapContextCompatibilityKey as String: true])
        writer.add(input)
        defer { if writer.status == .writing { writer.cancelWriting() } }
        guard writer.startWriting() else { throw writer.error ?? MediaEditProject.Failure.invalid("Could not prepare this image.") }
        writer.startSession(atSourceTime: .zero)
        guard let pool = adapter.pixelBufferPool else { throw MediaEditProject.Failure.invalid("Could not prepare this image.") }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        guard let buffer else { throw MediaEditProject.Failure.invalid("Could not allocate the image frame.") }
        CVPixelBufferLockBaseAddress(buffer, [])
        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { CVPixelBufferUnlockBaseAddress(buffer, []); throw MediaEditProject.Failure.invalid("Could not draw this image.") }
        context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height)); CVPixelBufferUnlockBaseAddress(buffer, [])
        for frame in 0..<30 {
            while !input.isReadyForMoreMediaData {
                try Task.checkCancellation()
                guard writer.status == .writing else { throw writer.error ?? MediaEditProject.Failure.invalid("Image preparation stopped.") }
                try await Task.sleep(for: .milliseconds(5))
            }
            guard adapter.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 30)) else { throw writer.error ?? MediaEditProject.Failure.invalid("Could not prepare this image.") }
        }
        input.markAsFinished(); await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? MediaEditProject.Failure.invalid("Could not finish this image.") }
        // Another preview may have prepared the same source while this task was suspended.
        if !FileManager.default.fileExists(atPath: target.path) { try FileManager.default.moveItem(at: temporary, to: target) }
        return target
    }
}
