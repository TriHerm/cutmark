import CoreGraphics
import Foundation

/// The editor's horizontal workspace is not media. Extra blank ruler/lane time must never
/// change a draft's cut list, AVPlayer duration, or the bounds of a render request.
enum TimelineCanvasLayout {
    static let minimumWorkspaceSeconds = 30.0
    static let trailingWorkspaceSeconds = 8.0

    /// Show a useful amount of empty timeline after even the shortest clip. The canvas extends
    /// beyond the viewport at every zoom level so the user can pan without changing output time.
    static func width(outputDuration: Double, pixelsPerSecond: Double, viewportWidth: CGFloat) -> CGFloat {
        guard outputDuration.isFinite, outputDuration >= 0,
              pixelsPerSecond.isFinite, pixelsPerSecond > 0,
              viewportWidth.isFinite, viewportWidth >= 0 else { return 0 }
        let seconds = max(minimumWorkspaceSeconds, outputDuration + trailingWorkspaceSeconds)
        let contentWidth = seconds * pixelsPerSecond
        let viewportWithTail = Double(viewportWidth) + trailingWorkspaceSeconds * pixelsPerSecond
        // Malformed/unbounded inputs should never create a nonfinite SwiftUI frame.
        guard contentWidth.isFinite, viewportWithTail.isFinite else { return viewportWidth }
        return max(CGFloat(contentWidth), CGFloat(viewportWithTail))
    }

    /// Clicking or scrubbing the empty workspace clamps to the actual last output frame/time.
    static func seekTime(at x: CGFloat, pixelsPerSecond: Double, outputDuration: Double) -> Double {
        guard x.isFinite, pixelsPerSecond.isFinite, pixelsPerSecond > 0,
              outputDuration.isFinite, outputDuration > 0 else { return 0 }
        return min(outputDuration, max(0, Double(x) / pixelsPerSecond))
    }
}
