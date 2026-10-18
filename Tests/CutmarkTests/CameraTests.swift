import AVFoundation
import Testing
@testable import Cutmark

// The camera writes HEVC at a set bitrate (CameraRecorder.swift).
struct CameraBitrateTests {
    @Test func bitrateScalesWithPixels() {
        #expect(CameraRecorder.bitrate(CMVideoDimensions(width: 1080, height: 1920)) == 20_000_000)
        #expect(CameraRecorder.bitrate(CMVideoDimensions(width: 1920, height: 1080)) == 20_000_000)
        #expect(CameraRecorder.bitrate(CMVideoDimensions(width: 3840, height: 2160)) == 80_000_000)
    }

    @Test func recordingFragmentsBoundTheCrashTail() {
        #expect(CameraRecorder.fragmentSeconds == 2)
    }

    @Test func captureModesChooseOnlyTheirRequestedSources() {
        #expect(Mode.camera.recordsCamera && !Mode.camera.recordsScreen)
        #expect(!Mode.screen.recordsCamera && Mode.screen.recordsScreen)
        #expect(Mode.cameraScreen.recordsCamera && Mode.cameraScreen.recordsScreen)
        #expect(Mode.cameraScreen.captureMode(cameraPaused: true) == .screen)
        #expect(Mode.cameraScreen.captureMode(cameraPaused: false) == .cameraScreen)
        #expect(Mode.camera.captureMode(cameraPaused: true) == .camera)
    }

    @Test func screenOnlyKeepsTheCameraHeldWhileRecording() {
        #expect(AppModel.holdsCamera(idle: false, preview: false, seen: true, recordsCamera: false))
        #expect(AppModel.holdsCamera(idle: true, preview: false, seen: true, recordsCamera: false))
    }

    @Test func audioFirstMovieStartWaitsForTheFirstEligibleVideoFrame() throws {
        var gate = CameraRecorder.VideoStartGate()
        gate.arm(at: CMTime(seconds: 10, preferredTimescale: 600))
        let stale = gate.noteVideo(CMTime(seconds: 9.9, preferredTimescale: 600))
        let audioFirst = gate.noteMovieStart(CMTime(seconds: 10.01, preferredTimescale: 600))
        #expect(stale == nil && audioFirst == nil)
        let expected = CMTime(value: 6020, timescale: 600)
        let firstCandidate = gate.noteVideo(expected)
        let first = try #require(firstCandidate)
        #expect(CMTimeCompare(first, expected) == 0)
        #expect(!gate.isArmed)
    }

    @Test func delayedMovieCallbackRejectsVideoFramesBeforeItsStartPTS() throws {
        var gate = CameraRecorder.VideoStartGate()
        gate.arm(at: CMTime(seconds: 20, preferredTimescale: 600))
        let earlier = gate.noteVideo(CMTime(seconds: 20.01, preferredTimescale: 600))
        let eligible = gate.noteVideo(CMTime(seconds: 20.05, preferredTimescale: 600))
        #expect(earlier == nil && eligible == nil)
        let firstCandidate = gate.noteMovieStart(CMTime(seconds: 20.03, preferredTimescale: 600))
        let first = try #require(firstCandidate)
        #expect(CMTimeCompare(first, CMTime(seconds: 20.05, preferredTimescale: 600)) == 0)
    }

    @Test func recordingActivationRejectsBufferedVideoEvenWhenAudioMoviePTSIsEarlier() throws {
        var gate = CameraRecorder.VideoStartGate()
        let activation = CMTime(seconds: 40, preferredTimescale: 600)
        gate.arm(at: activation)
        let earlierMovie = gate.noteMovieStart(CMTime(seconds: 39.9, preferredTimescale: 600))
        let staleVideo = gate.noteVideo(CMTime(seconds: 39.99, preferredTimescale: 600))
        #expect(earlierMovie == nil && staleVideo == nil)
        let expected = CMTime(seconds: 40.02, preferredTimescale: 600)
        let firstCandidate = gate.noteVideo(expected)
        let first = try #require(firstCandidate)
        #expect(CMTimeCompare(first, expected) == 0)
    }

    @Test func clearingVideoStartGateCannotLeakAnOldTakeIntoTheNextStart() {
        var gate = CameraRecorder.VideoStartGate()
        gate.arm(at: CMTime(seconds: 30, preferredTimescale: 600))
        _ = gate.noteVideo(CMTime(seconds: 30.1, preferredTimescale: 600))
        gate.reset()
        #expect(!gate.isArmed)
        let staleMovie = gate.noteMovieStart(CMTime(seconds: 30.05, preferredTimescale: 600))
        let staleVideo = gate.noteVideo(CMTime(seconds: 30.2, preferredTimescale: 600))
        #expect(staleMovie == nil && staleVideo == nil)
    }
}
