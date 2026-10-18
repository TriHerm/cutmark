import CoreGraphics
import Foundation

/// The editor's horizontal workspace is not media. Extra blank ruler/lane time must never
/// change a draft's cut list, AVPlayer duration, or the bounds of a render request.
enum TimelineCanvasLayout {
    static let minimumScale = 0.05
    static let maximumScale = 1000.0
    static let defaultScale = 72.0

    /// Reelbird-style fit: use almost all of the visible lane for real media and reserve only a
    /// small visual tail. Very long media may zoom below the manual slider's comfortable range,
    /// because Fit should actually fit instead of silently creating a large horizontal scroll.
    static func fitPixelsPerSecond(outputDuration: Double, viewportWidth: CGFloat) -> Double {
        guard outputDuration.isFinite, outputDuration > 0,
              viewportWidth.isFinite, viewportWidth > 0 else { return defaultScale }
        let usable = max(1, Double(viewportWidth - trailingWidth(viewportWidth: viewportWidth)))
        let scale = usable / outputDuration
        guard scale.isFinite else { return defaultScale }
        return min(maximumScale, max(minimumScale, scale))
    }

    /// Blank timeline is a navigation affordance, not fake duration. Keep a modest tail that
    /// scales with the viewport instead of forcing every short clip into a 30-second workspace.
    static func trailingWidth(viewportWidth: CGFloat) -> CGFloat {
        guard viewportWidth.isFinite, viewportWidth > 0 else { return 0 }
        return min(140, max(48, viewportWidth * 0.12))
    }

    /// A linear 0.05...1000 slider would make normal editing scales impossible to control.
    /// Store the real pixels/second in state, but expose a perceptually even logarithmic thumb.
    static func zoomSliderValue(pixelsPerSecond: Double) -> Double {
        guard pixelsPerSecond.isFinite, pixelsPerSecond > 0 else { return 0 }
        let clamped = min(maximumScale, max(minimumScale, pixelsPerSecond))
        let low = log(minimumScale), high = log(maximumScale)
        return (log(clamped) - low) / (high - low)
    }

    static func pixelsPerSecond(zoomSliderValue: Double) -> Double {
        guard zoomSliderValue.isFinite else { return defaultScale }
        let value = min(1, max(0, zoomSliderValue))
        let low = log(minimumScale), high = log(maximumScale)
        return exp(low + value * (high - low))
    }

    /// The canvas is only as wide as the actual output plus the small navigation tail, or the
    /// viewport when the whole edit already fits. Export duration remains draft.duration.
    static func width(outputDuration: Double, pixelsPerSecond: Double, viewportWidth: CGFloat) -> CGFloat {
        guard outputDuration.isFinite, outputDuration >= 0,
              pixelsPerSecond.isFinite, pixelsPerSecond > 0,
              viewportWidth.isFinite, viewportWidth >= 0 else { return 0 }
        let contentWidth = outputDuration * pixelsPerSecond + Double(trailingWidth(viewportWidth: viewportWidth))
        // Malformed/unbounded inputs should never create a nonfinite SwiftUI frame.
        guard contentWidth.isFinite else { return viewportWidth }
        return max(viewportWidth, CGFloat(contentWidth))
    }

    /// Clicking or scrubbing the empty workspace clamps to the actual last output frame/time.
    static func seekTime(at x: CGFloat, pixelsPerSecond: Double, outputDuration: Double) -> Double {
        guard x.isFinite, pixelsPerSecond.isFinite, pixelsPerSecond > 0,
              outputDuration.isFinite, outputDuration > 0 else { return 0 }
        return min(outputDuration, max(0, Double(x) / pixelsPerSecond))
    }

    static func rulerStep(pixelsPerSecond: Double) -> Double {
        guard pixelsPerSecond.isFinite, pixelsPerSecond > 0 else { return 5 }
        // Keep major ticks roughly 56+ points apart from sub-second detail through multi-hour edits.
        for seconds in [0.25, 0.5, 1, 2, 5, 10, 30, 60, 120, 300, 600, 1800] where seconds * pixelsPerSecond >= 56 {
            return seconds
        }
        return 3600
    }

    /// Arrow keys step on the same output-frame grid the editor uses for trim/split proposals.
    static func nudgedTime(_ time: Double, frames: Int, fps: Double, outputDuration: Double) -> Double {
        guard time.isFinite, fps.isFinite, fps > 0,
              outputDuration.isFinite, outputDuration >= 0 else { return 0 }
        let proposed = time + Double(frames) / fps
        return min(outputDuration, max(0, proposed))
    }
}
