import CoreGraphics
import Foundation

/// The editor's horizontal workspace is not media. Extra blank ruler/lane time must never
/// change a draft's cut list, AVPlayer duration, or the bounds of a render request.
enum TimelineCanvasLayout {
    static let minimumScale = 0.05
    static let maximumScale = 1000.0
    static let defaultScale = 72.0
    static let rulerHeight: CGFloat = 34
    static let filmstripHeight: CGFloat = 100
    static let waveformHeight: CGFloat = 54

    /// Reserve an actual editing surface at normal and compact window sizes. The preview
    /// receives the remaining space; resizing the window never compresses the tracks.
    static func editorHeight(windowHeight: CGFloat) -> CGFloat {
        guard windowHeight.isFinite, windowHeight > 0 else { return 238 }
        return min(355, max(238, windowHeight * 0.44))
    }

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

    /// Scrubbing, clip taps, and handle drags share one output-frame grid. Keep the exact
    /// end boundary reachable, even when the output is not an integral frame duration.
    static func snappedTime(_ time: Double, fps: Double, outputDuration: Double) -> Double {
        guard time.isFinite, fps.isFinite, fps > 0, outputDuration.isFinite,
              outputDuration > 0 else { return 0 }
        let clamped = min(outputDuration, max(0, time))
        if clamped == outputDuration { return outputDuration }
        let frames = clamped * fps
        guard frames.isFinite else { return clamped }
        return min(outputDuration, max(0, frames.rounded() / fps))
    }

    static func snappedSeekTime(at x: CGFloat, pixelsPerSecond: Double,
                                outputDuration: Double, fps: Double) -> Double {
        snappedTime(seekTime(at: x, pixelsPerSecond: pixelsPerSecond,
                             outputDuration: outputDuration), fps: fps,
                    outputDuration: outputDuration)
    }

    /// On a cut boundary select the clip starting at that output time. The last clip
    /// stays selected at the end marker; blank canvas does not create phantom clips.
    static func clipIndex(at time: Double, durations: [Double]) -> Int? {
        guard time.isFinite, !durations.isEmpty,
              durations.allSatisfy({ $0.isFinite && $0 > 0 }) else { return nil }
        var end = 0.0
        for (index, duration) in durations.enumerated() {
            end += duration
            if time < end || index == durations.count - 1 { return index }
        }
        return nil
    }

    /// A playhead drag is relative to where the gesture began, not to the asynchronously
    /// updating AVPlayer clock. Otherwise the marker jumps or runs ahead of the pointer while
    /// seeks settle. This only maps UI geometry; it never changes the export duration.
    static func draggedPlayheadTime(start: Double, translation: CGFloat,
                                    pixelsPerSecond: Double, outputDuration: Double) -> Double {
        guard start.isFinite, translation.isFinite, pixelsPerSecond.isFinite,
              pixelsPerSecond > 0, outputDuration.isFinite, outputDuration >= 0 else { return 0 }
        return min(outputDuration, max(0, start + Double(translation) / pixelsPerSecond))
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
