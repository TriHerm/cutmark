import AVFoundation
import Foundation
import Testing
@testable import Cutmark

struct ScreenRecorderTests {
    @Test func screenMovieUsesRecoverableHEVCFragments() throws {
        #expect(ScreenMovieWriter.fragmentSeconds == 2)
        #expect(ScreenMovieWriter.frameRate == 60)
        let settings = ScreenMovieWriter.videoSettings(width: 3024, height: 1964)
        #expect(settings[AVVideoCodecKey] as? AVVideoCodecType == .hevc)
        #expect(settings[AVVideoWidthKey] as? Int == 3024)
        #expect(settings[AVVideoHeightKey] as? Int == 1964)
        let compression = try #require(settings[AVVideoCompressionPropertiesKey] as? [String: Any])
        #expect(compression[AVVideoExpectedSourceFrameRateKey] as? Int == 60)
        #expect(compression[AVVideoMaxKeyFrameIntervalDurationKey] as? Double == 2)
    }

    @Test func screenMicrophoneStaysInTheScreenMovie() {
        #expect(ScreenMovieWriter.microphoneSettings[AVFormatIDKey] as? AudioFormatID == kAudioFormatMPEG4AAC)
        #expect(ScreenMovieWriter.microphoneSettings[AVSampleRateKey] as? Int == 48_000)
        #expect(ScreenMovieWriter.microphoneSettings[AVNumberOfChannelsKey] as? Int == 1)
    }

    @Test func delayedRealFrameCannotRegressVideoTimeAfterFiller() {
        let last = CMTime(seconds: 2, preferredTimescale: 600)
        #expect(!ScreenMovieWriter.isNewerVideoPTS(CMTime(seconds: 1.99, preferredTimescale: 600), than: last))
        #expect(!ScreenMovieWriter.isNewerVideoPTS(last, than: last))
        #expect(ScreenMovieWriter.isNewerVideoPTS(CMTime(seconds: 2.01, preferredTimescale: 600), than: last))
    }

    @Test func screenPreviewDownscalesWithoutChangingDisplayAspect() {
        let size = ScreenRecorder.previewSize(contentRect: CGRect(x: 0, y: 0, width: 1512, height: 982), scale: 2)
        #expect(size.width == 640)
        #expect(size.height == 416)

        let small = ScreenRecorder.previewSize(contentRect: CGRect(x: 0, y: 0, width: 320, height: 180), scale: 1)
        #expect(small.width == 320)
        #expect(small.height == 180)
    }

    @Test func finishingBeforeTheFirstFrameIsIdempotent() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "cutmark-screen-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: file) }
        let movie = try ScreenMovieWriter(url: file, width: 320, height: 180, microphone: false)
        var finished = 0
        movie.finish { finished += 1 }
        movie.finish { finished += 1 }
        #expect(finished == 2)
    }
}
