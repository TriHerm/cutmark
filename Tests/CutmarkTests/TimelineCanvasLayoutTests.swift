import CoreGraphics
import Foundation
import Testing
@testable import Cutmark

struct TimelineCanvasLayoutTests {
    @Test func shortMediaHasScrollableBlankWorkspaceWithoutStretchingClips() {
        let scale = 72.0
        let output = 10.46
        let width = TimelineCanvasLayout.width(outputDuration: output, pixelsPerSecond: scale,
                                               viewportWidth: 1140)
        #expect(width >= 30 * scale)
        #expect(width > 1140)
        #expect(width > output * scale + 400)
        // The strip, waveform and output marker are still positioned using the actual media time.
        #expect(abs(output * scale - 753.12) < 0.001)
    }

    @Test func workspaceRespondsToWindowSizeZoomAndLongFootage() {
        let small = TimelineCanvasLayout.width(outputDuration: 3, pixelsPerSecond: 24,
                                              viewportWidth: 1400)
        #expect(small >= 1400 + 8 * 24)
        let zoom = TimelineCanvasLayout.width(outputDuration: 3, pixelsPerSecond: 180,
                                             viewportWidth: 1400)
        #expect(zoom > small)
        let long = TimelineCanvasLayout.width(outputDuration: 95, pixelsPerSecond: 72,
                                             viewportWidth: 850)
        #expect(long >= (95 + 8) * 72)
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
    }

    @Test func largerWorkspaceNeverAppearsInTheUnpublishedExportCut() throws {
        let take = Take(number: 1, kind: .screen, file: "take-01-screen.mov",
                        startedAt: .distantPast, duration: 10)
        var draft = try #require(EditTimelineDraft.fromTake(take, duration: 10, fps: 30))
        let kept = draft.apply(.init(op: "trim", index: 0, in: 2, out: 6))
        #expect(kept)
        let hugeCanvas = TimelineCanvasLayout.width(outputDuration: draft.duration,
                                                    pixelsPerSecond: 180, viewportWidth: 2400)
        #expect(hugeCanvas > draft.duration * 180)
        let recipe = try #require(draft.initialRecipe())
        let cuts = try #require(recipe["cut"] as? [[String: Any]])
        #expect(cuts.count == 1)
        #expect(cuts[0]["in"] as? Double == 2)
        #expect(cuts[0]["out"] as? Double == 6)
        #expect(draft.duration == 4)
    }
}
