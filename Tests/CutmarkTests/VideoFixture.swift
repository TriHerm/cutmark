import CoreGraphics
import Foundation

/// Software encoding keeps fixture creation independent of VideoToolbox encoder availability.
enum VideoFixture {
    static func makeVideo(_ url: URL, size: CGSize, seconds: Int, fps: Int = 30) async throws {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/env")
        process.arguments = [
            "ffmpeg", "-nostdin", "-v", "error",
            "-f", "lavfi", "-i", "testsrc2=size=\(Int(size.width))x\(Int(size.height)):rate=\(fps):duration=\(seconds)",
            "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000:duration=\(seconds)",
            "-c:v", "libx264", "-threads", "1", "-pix_fmt", "yuv420p", "-bf", "0",
            "-af", "volume=6.4", "-c:a", "aac", "-shortest", url.path,
        ]
        try process.run()
        let deadline = ContinuousClock.now + .seconds(30)
        defer { if process.isRunning { process.terminate() } }
        while process.isRunning {
            guard ContinuousClock.now < deadline else { throw Failure.timedOut }
            try await Task.sleep(for: .milliseconds(10))
        }
        guard process.terminationStatus == 0 else { throw Failure.encoder(process.terminationStatus) }
    }

    private enum Failure: Error { case timedOut, encoder(Int32) }
}
