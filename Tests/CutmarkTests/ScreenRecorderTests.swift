import AVFoundation
import CoreGraphics
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

    @Test func captureClockKeepsFirstFrameOffsetIndependentOfCallbackDelay() throws {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let camera = try #require(CaptureClock.date(hostTime: 100, now: base.addingTimeInterval(10), currentHostTime: 110))
        let screen = try #require(CaptureClock.date(hostTime: 100.18, now: base.addingTimeInterval(11), currentHostTime: 111))
        #expect(abs(screen.timeIntervalSince(camera) - 0.18) < 0.000_1)
    }

    @Test func screenPreviewDownscalesWithoutChangingDisplayAspect() {
        let size = ScreenRecorder.previewSize(contentRect: CGRect(x: 0, y: 0, width: 1512, height: 982), scale: 2)
        #expect(size.width == 640)
        #expect(size.height == 416)

        let small = ScreenRecorder.previewSize(contentRect: CGRect(x: 0, y: 0, width: 320, height: 180), scale: 1)
        #expect(small.width == 320)
        #expect(small.height == 180)
    }

    @Test func selectedDisplayNeverSilentlyChangesWhenDisconnected() {
        let available: [CGDirectDisplayID] = [11, 22]
        #expect(ScreenRecorder.captureDisplayID(selected: 22, available: available) == 22)
        #expect(ScreenRecorder.captureDisplayID(selected: 33, available: available) == nil)
        #expect(ScreenRecorder.captureDisplayID(selected: nil, available: available) == 11)
        #expect(ScreenRecorder.captureDisplayID(selected: nil, available: []) == nil)
    }

    @Test func selectedWindowNeverFallsBackWhenItsIdentityIsStale() {
        let original = ScreenRecorder.WindowIdentity(id: 41, bundleIdentifier: "x.test.editor",
                                                     processID: 900, title: "Draft")
        let reusedID = ScreenRecorder.WindowIdentity(id: 41, bundleIdentifier: "x.test.browser",
                                                     processID: 901, title: "Search")
        let current = ScreenRecorder.WindowIdentity(id: 42, bundleIdentifier: "x.test.editor",
                                                    processID: 900, title: "Draft")

        #expect(ScreenRecorder.captureSource(selected: .window(original), availableDisplays: [11],
                                             availableWindows: [reusedID, current]) == nil)
        #expect(ScreenRecorder.captureSource(selected: .window(original), availableDisplays: [11],
                                             availableWindows: [original]) == .window(original))
        let renamed = ScreenRecorder.WindowIdentity(id: 41, bundleIdentifier: "x.test.editor",
                                                    processID: 900, title: "Draft — updated")
        #expect(ScreenRecorder.captureSource(selected: .window(original), availableDisplays: [11],
                                             availableWindows: [renamed]) == .window(original))
        #expect(ScreenRecorder.captureSource(selected: .window(ScreenRecorder.unconfirmedWindow),
                                             availableDisplays: [11], availableWindows: [original]) == nil)
        #expect(!ScreenRecorder.supportsPointerEventMapping(source: .window(original)))
        #expect(ScreenRecorder.supportsPointerEventMapping(source: .display(11)))
    }

    @Test func unsetSourceMayUseFirstDisplayButExplicitMissingDisplayDoesNot() {
        #expect(ScreenRecorder.captureSource(selected: nil, availableDisplays: [11, 22],
                                             availableWindows: []) == .display(11))
        #expect(ScreenRecorder.captureSource(selected: .display(33), availableDisplays: [11, 22],
                                             availableWindows: []) == nil)
    }

    @Test func windowUsesDisplayWithLargestVisibleIntersection() {
        let frames: [(CGDirectDisplayID, CGRect)] = [
            (11, CGRect(x: 0, y: 0, width: 1000, height: 800)),
            (22, CGRect(x: 1000, y: 0, width: 1000, height: 800)),
        ]
        let mostlySecond = CGRect(x: 900, y: 100, width: 700, height: 600)
        #expect(ScreenRecorder.hostDisplayID(windowFrame: mostlySecond, displayFrames: frames) == 22)
        #expect(ScreenRecorder.hostDisplayID(windowFrame: CGRect(x: 2500, y: 0, width: 100, height: 100),
                                             displayFrames: frames) == nil)
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
