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
}
