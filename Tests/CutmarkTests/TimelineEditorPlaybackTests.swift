import AVFoundation
import CoreVideo
import Foundation
import Testing
@testable import Cutmark

@MainActor
struct TimelineEditorPlaybackTests {
    @Test func editingCommandsWaitForExactSeekAndUsePlayerClock() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "cutmark-editor-playback-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let movie = root.appending(path: "fixture.mov")
        try await makeVideo(movie, seconds: 2, fps: 30)
        let asset = AVURLAsset(url: movie)
        _ = try await asset.load(.duration)
        _ = try #require(try await asset.loadTracks(withMediaType: .video).first)

        let playback = TimelineEditorPlayback()
        defer { playback.close() }
        playback.player.replaceCurrentItem(with: AVPlayerItem(asset: asset))

        // The edit command arrives immediately, while seek() may still be settling. It must wait
        // for that exact seek and then sample AVPlayer.currentTime(), not the 80 ms UI observer.
        playback.seek(1.25, duration: 2)
        let sampled = try #require(await playback.commandTime(duration: 2, pause: true))
        #expect(abs(sampled - 1.25) < 0.001)

        // Frame stepping must likewise start from the player's settled clock, even when invoked
        // immediately after a prior scrub/seek.
        playback.seek(0.5, duration: 2)
        await playback.step(frames: 1, fps: 4, duration: 2)
        let stepped = try #require(await playback.commandTime(duration: 2, pause: true))
        #expect(abs(stepped - 0.75) < 0.001)

        // Dragging a visible playhead sends frequent seeks. Only the last target wins, even
        // when an earlier AVPlayer seek completion arrives out of order.
        playback.seek(0.30, duration: 2)
        playback.seek(1.60, duration: 2)
        playback.seek(0.90, duration: 2)
        let scrubbed = try #require(await playback.commandTime(duration: 2, pause: true))
        #expect(abs(scrubbed - 0.90) < 0.001)

        // When this asset does not advertise reverse playback, J takes Cutmark's safe one-second
        // fallback path. It must also base that move on the settled AVPlayer clock.
        if playback.player.currentItem?.canPlayReverse == false {
            playback.seek(1.5, duration: 2)
            await playback.shuttleBackward(duration: 2, fps: 4)
            let shuttled = try #require(await playback.commandTime(duration: 2, pause: true))
            #expect(abs(shuttled - 0.5) < 0.001)
        }
    }

    private func makeVideo(_ url: URL, seconds: Int, fps: Int) async throws {
        let size = CGSize(width: 64, height: 48)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferWidthKey as String: Int(size.width),
            kCVPixelBufferHeightKey as String: Int(size.height),
        ])
        guard writer.canAdd(input) else { throw FixtureError.writer }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? FixtureError.writer }
        writer.startSession(atSourceTime: .zero)
        guard let pool = adaptor.pixelBufferPool else { throw FixtureError.writer }

        for frame in 0..<(seconds * fps) {
            while !input.isReadyForMoreMediaData { await Task.yield() }
            var pixel: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixel) == kCVReturnSuccess,
                  let pixel else { throw FixtureError.writer }
            CVPixelBufferLockBaseAddress(pixel, [])
            if let base = CVPixelBufferGetBaseAddress(pixel) {
                base.assumingMemoryBound(to: UInt8.self)
                    .initialize(repeating: UInt8((frame * 13) % 255), count: CVPixelBufferGetDataSize(pixel))
            }
            CVPixelBufferUnlockBaseAddress(pixel, [])
            guard adaptor.append(pixel, withPresentationTime: CMTime(value: CMTimeValue(frame),
                                                                      timescale: CMTimeScale(fps))) else {
                throw writer.error ?? FixtureError.writer
            }
        }
        input.markAsFinished()
        await withCheckedContinuation { continuation in
            writer.finishWriting { continuation.resume() }
        }
        guard writer.status == .completed else { throw writer.error ?? FixtureError.writer }
    }

    private enum FixtureError: Error { case writer }
}
