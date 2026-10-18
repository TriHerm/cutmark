import CoreGraphics
import Foundation
import Testing
@testable import Cutmark

struct TimelineCanvasLayoutTests {
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
