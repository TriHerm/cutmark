import CoreGraphics
import Foundation
import Testing
@testable import Cutmark

struct TimelineCanvasLayoutTests {
    @Test func timelineHasReadableTracksAtCompactAndStandardWindowHeights() {
        let tracks = TimelineCanvasLayout.rulerHeight + TimelineCanvasLayout.filmstripHeight
            + TimelineCanvasLayout.waveformHeight
        #expect(tracks >= 180)
        let compact = TimelineCanvasLayout.editorHeight(windowHeight: 520)
        let standard = TimelineCanvasLayout.editorHeight(windowHeight: 680)
        let large = TimelineCanvasLayout.editorHeight(windowHeight: 1000)
        #expect(compact >= tracks + 44)
        #expect(standard > compact)
        #expect(standard >= 295)
        #expect(large <= 355)
        // On a small supported window there must still be room for video preview + transport.
        #expect(520 - 50 - 34 - compact >= 190)
    }

    @Test func rulerAndLanewiseScrubbingUseTheSameFrameGrid() {
        let fps = 30.0
        let duration = 5.4
        let scale = TimelineCanvasLayout.fitPixelsPerSecond(outputDuration: duration,
                                                            viewportWidth: 900)
        let x = CGFloat(2.49 * scale)
        let actual = TimelineCanvasLayout.snappedSeekTime(
            at: x, pixelsPerSecond: scale, outputDuration: duration, fps: fps)
        #expect(abs(actual - 2.5) < 0.000001)
        #expect(TimelineCanvasLayout.snappedSeekTime(
            at: 9999, pixelsPerSecond: scale, outputDuration: duration, fps: fps) == duration)
        #expect(TimelineCanvasLayout.snappedTime(0.016, fps: 30, outputDuration: duration) == 0)
        #expect(abs(TimelineCanvasLayout.snappedTime(
            2.49, fps: fps, outputDuration: duration) - 2.5) < 0.000001)
    }

    @Test func selectingAtCutBoundariesAndEndUsesOutputTime() {
        let clips = [1.25, 0.75, 3.4]
        #expect(TimelineCanvasLayout.clipIndex(at: 0, durations: clips) == 0)
        #expect(TimelineCanvasLayout.clipIndex(at: 1.249, durations: clips) == 0)
        #expect(TimelineCanvasLayout.clipIndex(at: 1.25, durations: clips) == 1)
        #expect(TimelineCanvasLayout.clipIndex(at: 2, durations: clips) == 2)
        #expect(TimelineCanvasLayout.clipIndex(at: 5.4, durations: clips) == 2)
        #expect(TimelineCanvasLayout.clipIndex(at: 999, durations: clips) == 2)
        #expect(TimelineCanvasLayout.clipIndex(at: 1, durations: []) == nil)
    }

    @Test func shortMediaFitsViewportWithoutFakeThirtySecondWorkspace() {
        let viewport: CGFloat = 1140
        let output = 10.46
        let scale = TimelineCanvasLayout.fitPixelsPerSecond(outputDuration: output,
                                                            viewportWidth: viewport)
        let width = TimelineCanvasLayout.width(outputDuration: output, pixelsPerSecond: scale,
                                               viewportWidth: viewport)
        #expect(scale > 80 && scale < 110)
        #expect(width == viewport)
        #expect(output * scale < Double(viewport))
        #expect(Double(viewport) - output * scale >= 48)
    }

    @Test func fitScaleUsesWindowAndManualZoomAddsOnlyAdaptiveTail() {
        let wide = TimelineCanvasLayout.fitPixelsPerSecond(outputDuration: 20, viewportWidth: 1400)
        let narrow = TimelineCanvasLayout.fitPixelsPerSecond(outputDuration: 20, viewportWidth: 700)
        #expect(wide > narrow)

        let normal = TimelineCanvasLayout.width(outputDuration: 3, pixelsPerSecond: 24,
                                                viewportWidth: 1400)
        #expect(normal == 1400)
        let zoom = TimelineCanvasLayout.width(outputDuration: 3, pixelsPerSecond: 220,
                                              viewportWidth: 500)
        #expect(zoom == CGFloat(3 * 220) + TimelineCanvasLayout.trailingWidth(viewportWidth: 500))
        #expect(TimelineCanvasLayout.trailingWidth(viewportWidth: 500) >= 48)
        #expect(TimelineCanvasLayout.trailingWidth(viewportWidth: 500) <= 140)
    }

    @Test func veryShortMediaUsesMostOfViewportInsteadOfHittingOldZoomCap() {
        let viewport: CGFloat = 1140
        let threeSeconds = TimelineCanvasLayout.fitPixelsPerSecond(outputDuration: 3,
                                                                   viewportWidth: viewport)
        let twoSeconds = TimelineCanvasLayout.fitPixelsPerSecond(outputDuration: 2,
                                                                 viewportWidth: viewport)
        #expect(threeSeconds > 300)
        #expect(twoSeconds > 450)
        #expect(TimelineCanvasLayout.width(outputDuration: 3, pixelsPerSecond: threeSeconds,
                                           viewportWidth: viewport) == viewport)
        #expect(TimelineCanvasLayout.width(outputDuration: 2, pixelsPerSecond: twoSeconds,
                                           viewportWidth: viewport) == viewport)
    }

    @Test func logarithmicZoomSliderRoundTripsEditingScales() {
        for scale in [0.22, 2.64, 24.0, 72.0, 220.0, 600.0] {
            let slider = TimelineCanvasLayout.zoomSliderValue(pixelsPerSecond: scale)
            let restored = TimelineCanvasLayout.pixelsPerSecond(zoomSliderValue: slider)
            #expect(slider >= 0 && slider <= 1)
            #expect(abs(restored - scale) / scale < 0.000_001)
        }
    }

    @Test func clickingRulerAfterMediaEndCannotSeekIntoNonExportedTime() {
        #expect(TimelineCanvasLayout.seekTime(at: 1000, pixelsPerSecond: 72,
                                              outputDuration: 4.5) == 4.5)
        #expect(TimelineCanvasLayout.seekTime(at: -100, pixelsPerSecond: 72,
                                              outputDuration: 4.5) == 0)
        #expect(TimelineCanvasLayout.seekTime(at: 180, pixelsPerSecond: 72,
                                              outputDuration: 4.5) == 2.5)
    }

    @Test func draggablePlayheadUsesGestureOriginNotAsynchronousPlayerUpdates() {
        // A handle grabbed at 3.2 s must follow total pointer translation even when AVPlayer
        // has not finished an earlier exact seek. The rendered output has no blank tail.
        #expect(abs(TimelineCanvasLayout.draggedPlayheadTime(
            start: 3.2, translation: 144, pixelsPerSecond: 72, outputDuration: 10) - 5.2) < 0.000001)
        #expect(TimelineCanvasLayout.draggedPlayheadTime(
            start: 3.2, translation: -500, pixelsPerSecond: 72, outputDuration: 10) == 0)
        #expect(TimelineCanvasLayout.draggedPlayheadTime(
            start: 9.5, translation: 500, pixelsPerSecond: 72, outputDuration: 10) == 10)
        #expect(TimelineCanvasLayout.draggedPlayheadTime(
            start: 2, translation: .nan, pixelsPerSecond: 72, outputDuration: 10) == 0)
        // Repeated updates use the *same* start, never compound the last 80ms UI clock.
        #expect(TimelineCanvasLayout.draggedPlayheadTime(
            start: 3.2, translation: 72, pixelsPerSecond: 72, outputDuration: 10) == 4.2)
    }

    @Test func malformedCanvasGeometryNeverProducesAnInfiniteFrame() {
        #expect(TimelineCanvasLayout.width(outputDuration: .infinity, pixelsPerSecond: 72,
                                           viewportWidth: 1100) == 0)
        #expect(TimelineCanvasLayout.width(outputDuration: 10, pixelsPerSecond: .nan,
                                           viewportWidth: 1100) == 0)
        #expect(TimelineCanvasLayout.width(outputDuration: .greatestFiniteMagnitude,
                                           pixelsPerSecond: 180, viewportWidth: 1100) == 1100)
        #expect(TimelineCanvasLayout.fitPixelsPerSecond(outputDuration: .nan,
                                                        viewportWidth: 1100) == TimelineCanvasLayout.defaultScale)
    }

    @Test func rulerAndArrowStepStayUsefulAcrossZoomLevels() {
        #expect(TimelineCanvasLayout.rulerStep(pixelsPerSecond: 180) == 0.5)
        #expect(TimelineCanvasLayout.rulerStep(pixelsPerSecond: 72) == 1)
        #expect(TimelineCanvasLayout.rulerStep(pixelsPerSecond: 24) == 5)
        #expect(TimelineCanvasLayout.rulerStep(pixelsPerSecond: 6) == 10)
        #expect(TimelineCanvasLayout.rulerStep(pixelsPerSecond: 0.2) == 300)
        #expect(abs(TimelineCanvasLayout.nudgedTime(2, frames: 1, fps: 30,
                                                   outputDuration: 5) - 2.033_333) < 0.000_01)
        #expect(TimelineCanvasLayout.nudgedTime(0, frames: -1, fps: 30, outputDuration: 5) == 0)
        #expect(TimelineCanvasLayout.nudgedTime(5, frames: 1, fps: 30, outputDuration: 5) == 5)
    }

    @Test func fitReallyFitsSeveralMinuteAndHourLongEdits() {
        let viewport: CGFloat = 900
        let fiveMinutes = TimelineCanvasLayout.fitPixelsPerSecond(outputDuration: 300,
                                                                  viewportWidth: viewport)
        let oneHour = TimelineCanvasLayout.fitPixelsPerSecond(outputDuration: 3600,
                                                              viewportWidth: viewport)
        #expect(fiveMinutes < 4)
        #expect(oneHour < 1)
        #expect(TimelineCanvasLayout.width(outputDuration: 300, pixelsPerSecond: fiveMinutes,
                                           viewportWidth: viewport) == viewport)
        #expect(TimelineCanvasLayout.width(outputDuration: 3600, pixelsPerSecond: oneHour,
                                           viewportWidth: viewport) == viewport)
    }

    @Test func largerWorkspaceNeverAppearsInTheUnpublishedExportCut() throws {
        let take = Take(number: 1, kind: .screen, file: "take-01-screen.mov",
                        startedAt: .distantPast, duration: 10)
        var draft = try #require(EditTimelineDraft.fromTake(take, duration: 10, fps: 30))
        let kept = draft.apply(.init(op: "trim", index: 0, in: 2, out: 6))
        #expect(kept)
        let hugeCanvas = TimelineCanvasLayout.width(outputDuration: draft.duration,
                                                    pixelsPerSecond: 220, viewportWidth: 500)
        #expect(Double(hugeCanvas) > draft.duration * 180)
        let recipe = try #require(draft.initialRecipe())
        let cuts = try #require(recipe["cut"] as? [[String: Any]])
        #expect(cuts.count == 1)
        #expect(cuts[0]["in"] as? Double == 2)
        #expect(cuts[0]["out"] as? Double == 6)
        #expect(draft.duration == 4)
    }
}
