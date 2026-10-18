import AVFoundation
import AudioToolbox
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import Testing
@testable import Cutmark

struct TimelinePlaybackTests {
    @MainActor
    @Test func reorderedTrimmedRawTakesBuildARealCompositionWithoutWritingAnEdit() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "cutmark-playback-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let camera = "take-01-renamed-camera.mov"
        let screen = "take-02-screen.mov"
        try await makeVideo(root.appending(path: camera), size: CGSize(width: 64, height: 48), seconds: 2)
        try await makeVideo(root.appending(path: screen), size: CGSize(width: 80, height: 60), seconds: 2)
        let meta = SessionMeta(title: "Playback", createdAt: Date(timeIntervalSince1970: 0), takes: [
            Take(number: 1, kind: .camera, file: camera, startedAt: Date(timeIntervalSince1970: 0), duration: 2),
            Take(number: 2, kind: .screen, file: screen, startedAt: Date(timeIntervalSince1970: 0), duration: 2),
        ])
        try Store.encoder.encode(meta).write(to: root.appending(path: "session.json"), options: .atomic)

        let first = EditTimelineDraft.Segment(take: 1, kind: "camera", start: 0, end: 2)
        let second = EditTimelineDraft.Segment(take: 2, kind: "screen", start: 0, end: 2)
        let draft = EditTimelineDraft(base: "takes/\(camera)", fps: 30,
                                      source: [first],
                                      segments: [.init(take: 2, kind: "screen", start: 0.5, end: 1.5),
                                                 .init(take: 1, kind: "camera", start: 0.25, end: 1)])

        let before = try directorySnapshot(root)
        let item = try await TimelinePlayback.playerItem(draft: draft, session: root)
        let duration = try await item.asset.load(.duration).seconds
        let tracks = try await item.asset.loadTracks(withMediaType: .video)
        let audio = try await item.asset.loadTracks(withMediaType: .audio)
        let after = try directorySnapshot(root)

        #expect(abs(duration - 1.75) < 0.04)
        #expect(tracks.count == 1)
        #expect(audio.count == 1)
        #expect(item.videoComposition?.renderSize == CGSize(width: 80, height: 60))
        #expect(before == after)
        #expect(TimelinePlayback.limitation(draft: draft, session: root) == nil)
    }

    @MainActor
    @Test func sourceResolutionUsesSessionMetadataAndRejectsEscapes() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "cutmark-playback-path-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let actual = root.appending(path: "take-07-my-renamed-screen.mov")
        FileManager.default.createFile(atPath: actual.path, contents: Data())

        #expect(try TimelinePlayback.sourceURL(file: actual.lastPathComponent, session: root) == actual.resolvingSymlinksInPath())
        #expect(throws: TimelinePlayback.Failure.self) {
            _ = try TimelinePlayback.sourceURL(file: "../outside.mov", session: root)
        }
    }

    @MainActor
    @Test func fittedTransformCentersDifferentSourceGeometry() {
        let rotated = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 48, ty: 0)
        let canvas = CGSize(width: 120, height: 120)
        let transform = TimelinePlayback.fittedTransform(naturalSize: CGSize(width: 64, height: 48),
                                                         preferredTransform: rotated, canvas: canvas)
        let rect = CGRect(x: 0, y: 0, width: 64, height: 48).applying(transform)
        #expect(abs(rect.width - 90) < 0.001)
        #expect(abs(rect.height - 120) < 0.001)
        #expect(abs(rect.midX - 60) < 0.001)
        #expect(abs(rect.midY - 60) < 0.001)
    }

    @MainActor
    @Test func publishedDraftReportsRawPreviewLimitationWhenRenderEffectsExist() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "cutmark-playback-limit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appending(path: "edits"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let video = root.appending(path: "edits/demo-v1.mp4")
        let recipe: [String: Any] = [
            "name": "demo",
            "cut": [["take": 1, "kind": "screen", "in": 0, "out": 1]],
            "frame": ["shape": "source", "fps": 30],
            "auto_zoom": ["items": []],
        ]
        let data = try JSONSerialization.data(withJSONObject: recipe)
        try data.write(to: EditRecipe.url(for: video))
        let segment = EditTimelineDraft.Segment(take: 1, kind: "screen", start: 0, end: 1)
        let draft = EditTimelineDraft(base: "edits/demo-v1.mp4", fps: 30, source: [segment], segments: [segment])
        #expect(TimelinePlayback.limitation(draft: draft, session: root) != nil)
    }

    @MainActor
    @Test func publishedReorderKeepsBaseFrameInsteadOfFirstMovedTakeSize() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "cutmark-playback-frame-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appending(path: "edits"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await makeVideo(root.appending(path: "take-01-camera.mov"),
                            size: CGSize(width: 64, height: 48), seconds: 2)
        try await makeVideo(root.appending(path: "take-02-screen.mov"),
                            size: CGSize(width: 80, height: 60), seconds: 2)
        let takes = [
            Take(number: 1, kind: .camera, file: "take-01-camera.mov", startedAt: .distantPast, duration: 2),
            Take(number: 2, kind: .screen, file: "take-02-screen.mov", startedAt: .distantPast, duration: 2),
        ]
        let meta = SessionMeta(title: "Published frame", createdAt: .distantPast, takes: takes)
        try Store.encoder.encode(meta).write(to: root.appending(path: "session.json"), options: .atomic)
        let edit = root.appending(path: "edits/demo-v1.mp4")
        let recipe: [String: Any] = ["name": "demo",
                                     "cut": [["take": 1, "kind": "camera", "in": 0, "out": 1]],
                                     "frame": ["shape": "source", "w": 64, "h": 48, "fps": 30]]
        try JSONSerialization.data(withJSONObject: recipe).write(to: EditRecipe.url(for: edit))
        let fromCamera = EditTimelineDraft.Segment(take: 1, kind: "camera", start: 0, end: 1)
        let movedScreen = EditTimelineDraft.Segment(take: 2, kind: "screen", start: 0, end: 1)
        let draft = EditTimelineDraft(base: "edits/demo-v1.mp4", fps: 30,
                                      source: [fromCamera, movedScreen],
                                      segments: [movedScreen, fromCamera])
        let item = try await TimelinePlayback.playerItem(draft: draft, session: root)
        #expect(item.videoComposition?.renderSize == CGSize(width: 64, height: 48))
    }

    @MainActor
    @Test func publishedFrameNeverReadsRecipeFromEscapedEditsSymlink() async throws {
        let parent = FileManager.default.temporaryDirectory.appending(path: "cutmark-published-symlink-\(UUID().uuidString)")
        let session = parent.appending(path: "session")
        let outside = parent.appending(path: "outside")
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        try await makeVideo(session.appending(path: "take-01-camera.mov"),
                            size: CGSize(width: 64, height: 48), seconds: 2)
        let take = Take(number: 1, kind: .camera, file: "take-01-camera.mov",
                        startedAt: .distantPast, duration: 2)
        try Store.encoder.encode(SessionMeta(title: "No escape", createdAt: .distantPast, takes: [take]))
            .write(to: session.appending(path: "session.json"))
        try FileManager.default.createSymbolicLink(at: session.appending(path: "edits"), withDestinationURL: outside)
        let forged = outside.appending(path: "demo-v1.mp4")
        let recipe: [String: Any] = ["name": "demo", "frame": ["shape": "source", "w": 640, "h": 360, "fps": 30],
                                     "cut": [["take": 1, "kind": "camera", "in": 0, "out": 1]]]
        try JSONSerialization.data(withJSONObject: recipe).write(to: EditRecipe.url(for: forged))
        let segment = EditTimelineDraft.Segment(take: 1, kind: "camera", start: 0, end: 1)
        let draft = EditTimelineDraft(base: "edits/demo-v1.mp4", fps: 30,
                                      source: [segment], segments: [segment])
        let item = try await TimelinePlayback.playerItem(draft: draft, session: session)
        #expect(item.videoComposition?.renderSize == CGSize(width: 64, height: 48))
    }

    private func directorySnapshot(_ root: URL) throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(atPath: root.path))
    }

    private func makeVideo(_ url: URL, size: CGSize, seconds: Int, fps: Int = 30) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
        ])
        let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 64_000,
        ])
        input.expectsMediaDataInRealTime = false
        audio.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferWidthKey as String: Int(size.width),
            kCVPixelBufferHeightKey as String: Int(size.height),
        ])
        guard writer.canAdd(input), writer.canAdd(audio) else { throw TestFailure.writer }
        writer.add(input)
        writer.add(audio)
        guard writer.startWriting() else { throw writer.error ?? TestFailure.writer }
        writer.startSession(atSourceTime: .zero)
        guard let pool = adaptor.pixelBufferPool else { throw TestFailure.writer }

        for frame in 0..<(seconds * fps) {
            while !input.isReadyForMoreMediaData { await Task.yield() }
            var pixel: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixel) == kCVReturnSuccess, let pixel else {
                throw TestFailure.writer
            }
            CVPixelBufferLockBaseAddress(pixel, [])
            if let base = CVPixelBufferGetBaseAddress(pixel) {
                base.assumingMemoryBound(to: UInt8.self)
                    .initialize(repeating: UInt8((frame * 7) % 255), count: CVPixelBufferGetDataSize(pixel))
            }
            CVPixelBufferUnlockBaseAddress(pixel, [])
            guard adaptor.append(pixel, withPresentationTime: CMTime(value: CMTimeValue(frame),
                                                                      timescale: CMTimeScale(fps))) else {
                throw writer.error ?? TestFailure.writer
            }
        }
        input.markAsFinished()
        let audioFrames: Int32 = 4_800
        let chunks = seconds * 10
        for chunk in 0..<chunks {
            while !audio.isReadyForMoreMediaData { await Task.yield() }
            let sample = try audioSample(startFrame: Int64(chunk) * Int64(audioFrames), frames: audioFrames)
            guard audio.append(sample) else { throw writer.error ?? TestFailure.writer }
        }
        audio.markAsFinished()
        await withCheckedContinuation { continuation in
            writer.finishWriting { continuation.resume() }
        }
        guard writer.status == .completed else { throw writer.error ?? TestFailure.writer }
    }

    private func audioSample(startFrame: Int64, frames: Int32) throws -> CMSampleBuffer {
        var format = AudioStreamBasicDescription(
            mSampleRate: 48_000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2,
            mFramesPerPacket: 1,
            mBytesPerFrame: 2,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 16,
            mReserved: 0)
        var formatDescription: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &format,
                                             layoutSize: 0, layout: nil, magicCookieSize: 0,
                                             magicCookie: nil, extensions: nil,
                                             formatDescriptionOut: &formatDescription) == noErr,
              let formatDescription else { throw TestFailure.writer }

        let byteCount = Int(frames) * 2
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
                                                 blockLength: byteCount, blockAllocator: kCFAllocatorDefault,
                                                 customBlockSource: nil, offsetToData: 0, dataLength: byteCount,
                                                 flags: 0, blockBufferOut: &block) == kCMBlockBufferNoErr,
              let block else { throw TestFailure.writer }
        CMBlockBufferFillDataBytes(with: 0, blockBuffer: block, offsetIntoDestination: 0, dataLength: byteCount)

        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48_000),
                                        presentationTimeStamp: CMTime(value: startFrame, timescale: 48_000),
                                        decodeTimeStamp: .invalid)
        var sampleSize = 2
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block,
                                        formatDescription: formatDescription, sampleCount: CMItemCount(frames),
                                        sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                        sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize,
                                        sampleBufferOut: &sample) == noErr,
              let sample else { throw TestFailure.writer }
        return sample
    }

    private enum TestFailure: Error { case writer }
}
