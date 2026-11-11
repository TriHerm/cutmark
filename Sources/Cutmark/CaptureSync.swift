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

    /// Compare the shared microphone on the two movie clocks, including any gap before audio.
    /// A distinct match can correct encoder/clock startup error. Silence and ambiguous matches
    /// leave the original frame timing in control.
    static func microphoneOffset(camera: URL, cameraDuration: Double, screen: URL, screenDuration: Double,
                                 near frameOffset: Double?) async throws -> Double? {
        let rate = 100.0
        let cameraBins = Int((min(20, cameraDuration) * rate).rounded(.down))
        let screenBins = Int((min(20, screenDuration) * rate).rounded(.down))
        guard min(cameraBins, screenBins) >= 150 else { return nil }
        async let c = TimelineMedia.waveform(url: camera, start: 0, end: Double(cameraBins) / rate, sampleCount: cameraBins)
        async let s = TimelineMedia.waveform(url: screen, start: 0, end: Double(screenBins) / rate, sampleCount: screenBins)
        let estimate = Int(((frameOffset ?? 0) * rate).rounded())
        let radius = frameOffset == nil ? 200 : 30
        guard let lag = try await microphoneLag(camera: c, screen: s, search: (estimate - radius)...(estimate + radius)) else { return nil }
        let offset = Double(lag) / rate
        return abs(offset) <= 15 ? offset : nil
    }

    /// Correlate changes in level so leading silence and different gain cannot create a match.
    /// Positive lag means a screen sample at t matches a camera sample at t + lag.
    static func microphoneLag(camera: [CGFloat], screen: [CGFloat], search: ClosedRange<Int>) -> Int? {
        let c = zip(camera.dropFirst(2), camera).map { Double($0 - $1) }
        let s = zip(screen.dropFirst(2), screen).map { Double($0 - $1) }
        let scores = search.compactMap { lag -> (lag: Int, score: Double)? in
            let start = max(0, -lag), end = min(s.count, c.count - lag)
            guard end - start >= 125 else { return nil }
            var cameraEnergy = 0.0, screenEnergy = 0.0, cross = 0.0
            for i in start..<end {
                let x = c[i + lag], y = s[i]
                cameraEnergy += x * x
                screenEnergy += y * y
                cross += x * y
            }
            guard min(cameraEnergy, screenEnergy) >= 0.15 else { return nil }
            return (lag, cross / sqrt(cameraEnergy * screenEnergy))
        }
        guard let best = scores.max(by: { $0.score < $1.score }), best.score >= 0.68 else { return nil }
        let runnerUp = scores.filter { abs($0.lag - best.lag) > 3 }.map(\.score).max() ?? 0
        return best.score - runnerUp >= 0.1 ? best.lag : nil
    }
}
