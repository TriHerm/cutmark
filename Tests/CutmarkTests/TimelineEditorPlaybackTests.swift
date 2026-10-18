import AVFoundation
import Testing
@testable import Cutmark

@MainActor
struct TimelineEditorPlaybackTests {
    @Test func editingCommandsWaitForExactSeekAndUsePlayerClock() async throws {
        let playback = TimelineEditorPlayback()
        defer { playback.close() }

        let composition = AVMutableComposition()
        let track = try #require(composition.addMutableTrack(
            withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid))
        track.insertEmptyTimeRange(CMTimeRange(
            start: .zero, duration: CMTime(seconds: 2, preferredTimescale: 600)))
        playback.player.replaceCurrentItem(with: AVPlayerItem(asset: composition))

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

        // Empty compositions do not advertise reverse playback, so J takes Cutmark's safe
        // one-second fallback path. It must also base that move on the settled AVPlayer clock.
        if playback.player.currentItem?.canPlayReverse == false {
            playback.seek(1.5, duration: 2)
            await playback.shuttleBackward(duration: 2, fps: 4)
            let shuttled = try #require(await playback.commandTime(duration: 2, pause: true))
            #expect(abs(shuttled - 0.5) < 0.001)
        }
    }
}
