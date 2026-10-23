import Foundation

/// The provenance of a take's start timestamp. A callback is not a media-frame timestamp.
enum CaptureTimingQuality: String, Codable, Sendable {
    case videoFrame
    case callback
    case unknown
}

enum CaptureSync {
    /// Seconds after the camera's first video frame that the screen's first accepted frame began.
    /// Both timestamps must be on the host clock and from the same numbered recording.
    /// This does not establish sample-accurate audio alignment or compensate for later drift.
    static func screenMinusCameraSeconds(camera: Take?, screen: Take?) -> Double? {
        guard let camera, let screen,
              camera.kind == .camera, screen.kind == .screen,
              camera.number == screen.number,
              camera.timingQuality == .videoFrame, screen.timingQuality == .videoFrame,
              let c = camera.captureHostTime, let s = screen.captureHostTime,
              c.isFinite, s.isFinite, c > 0, s > 0 else { return nil }
        let offset = s - c
        // Seconds apart, not minutes: far-apart host timestamps cannot describe one paired take.
        return offset.isFinite && abs(offset) <= 15 ? offset : nil
    }
}
