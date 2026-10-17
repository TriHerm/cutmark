import Testing
@testable import Cutmark

struct AutoZoomTests {
    private func move(_ t: Double, _ x: Double, _ y: Double) -> CaptureEvent {
        .init(t: t, type: .move, x: x, y: y)
    }

    private func click(_ t: Double, _ x: Double, _ y: Double, button: Int = 0) -> CaptureEvent {
        .init(t: t, type: .down, x: x, y: y, button: button, count: 1)
    }

    @Test func primaryClickUsesNearbyPointerSamplesButKeepsRawNormalizedFocus() throws {
        let suggestions = AutoZoomPlanner.suggestions(events: [
            move(0.90, 0.01, 0.04),
            move(0.98, 0.02, 0.05),
            click(1.00, 0.01, 0.05),
            click(3.00, 0.95, 0.95, button: 1), // contextual click is not an auto-zoom trigger
        ], take: 2)

        let zoom = try #require(suggestions.first)
        #expect(suggestions.count == 1)
        #expect(zoom.take == 2)
        #expect(zoom.reason == "primary_click")
        #expect(abs(zoom.sourceTrigger - 1.0) < 0.0001)
        #expect(abs(zoom.sourceIn - 0.88) < 0.0001)
        #expect(abs(zoom.sourceOut - 2.35) < 0.0001)
        #expect(abs(zoom.focusX - 0.01) < 0.0001)
        #expect(abs(zoom.focusY - 0.05) < 0.0001)
    }

    @Test func rapidBurstKeepsTheLastTargetAndLaterFarTargetGetsANeutralGap() throws {
        let suggestions = AutoZoomPlanner.suggestions(events: [
            click(1.00, 0.50, 0.50),
            click(1.45, 0.53, 0.51),
            click(1.70, 0.80, 0.20), // one rapid burst: last target wins
            click(3.00, 0.20, 0.80), // separate target; earlier hold is shortened to leave a gap
        ], take: 1)

        #expect(suggestions.count == 2)
        let first = suggestions[0]
        #expect(abs(first.sourceTrigger - 1.7) < 0.0001)
        #expect(abs(first.focusX - 0.80) < 0.0001)
        #expect(abs(first.sourceIn - 0.88) < 0.0001)
        #expect(abs(first.sourceOut - 2.68) < 0.0001)
        #expect(abs(suggestions[1].sourceTrigger - 3.0) < 0.0001)
    }

    @Test func editMapRequiresTheClickToSurviveAndDuplicatesAReusedSourceRange() throws {
        let source = EditTimeMap.Source(take: 4, kind: .screen)
        let map = EditTimeMap(cuts: [
            .init(source: source, in: 2, out: 5),
            .init(source: .init(take: 1, kind: .camera), in: 0, out: 1),
            .init(source: source, in: 2.5, out: 4.0, rate: 2),
        ], lead: 0.1)
        let kept = AutoZoomSuggestion(take: 4, sourceTrigger: 3, sourceIn: 2.88, sourceOut: 4.35,
                                      focusX: 0.5, focusY: 0.5, scale: 1.35, reason: "primary_click")
        let removedTrigger = AutoZoomSuggestion(take: 4, sourceTrigger: 1.5, sourceIn: 1.4, sourceOut: 2.4,
                                                focusX: 0.5, focusY: 0.5, scale: 1.35, reason: "primary_click")

        let mapped = map.outputZooms([kept, removedTrigger], take: 4)
        #expect(mapped.count == 2)
        #expect(mapped.compactMap(\.outputTrigger).map { ($0 * 100).rounded() / 100 } == [1.1, 4.35])
        #expect(abs(mapped[0].outputIn - 0.98) < 0.0001)
        #expect(abs(mapped[0].outputOut - 2.45) < 0.0001)
        #expect(abs(mapped[1].outputIn - 4.29) < 0.0001)
        #expect(abs(mapped[1].outputOut - 4.85) < 0.0001)
    }

    @Test func tinyMappedFragmentsAreDroppedInsteadOfFlashing() {
        let source = EditTimeMap.Source(take: 1, kind: .screen)
        let map = EditTimeMap(cuts: [.init(source: source, in: 1.0, out: 1.2)])
        let zoom = AutoZoomSuggestion(take: 1, sourceTrigger: 1.1, sourceIn: 0.9, sourceOut: 2.0,
                                      focusX: 0.5, focusY: 0.5, scale: 1.35, reason: "primary_click")
        #expect(map.outputZooms([zoom], take: 1).isEmpty)
    }

    @Test func sourceRangeMappingSplitsAtCutsAndNeverTouchesCameraSpans() {
        let screen = EditTimeMap.Source(take: 2, kind: .screen)
        let map = EditTimeMap(cuts: [
            .init(source: screen, in: 1, out: 2),
            .init(source: .init(take: 2, kind: .camera), in: 1, out: 4),
            .init(source: screen, in: 2, out: 4, rate: 2),
        ])
        let ranges = map.outputRanges(source: screen, in: 1.5, out: 3.0)
        #expect(ranges.count == 2)
        #expect(ranges.map(\.spanIndex) == [0, 2])
        #expect(abs(ranges[0].outputIn - 0.5) < 0.0001)
        #expect(abs(ranges[0].outputOut - 1.0) < 0.0001)
        #expect(abs(ranges[1].outputIn - 4.0) < 0.0001)
        #expect(abs(ranges[1].outputOut - 4.5) < 0.0001)
    }

    @Test func playableDurationClipsTheSuggestedWindowAndDropsCrashTailClicks() throws {
        let suggestions = AutoZoomPlanner.suggestions(events: [
            click(1.0, 0.4, 0.6),
            click(2.4, 0.8, 0.2),
        ], take: 3, through: 2.0)
        let zoom = try #require(suggestions.first)
        #expect(suggestions.count == 1)
        #expect(abs(zoom.sourceOut - 2.0) < 0.0001)
        #expect(AutoZoomPlanner.version == 1)
        #expect(AutoZoomPlanner.identifier == "click_focus_v1")
    }
}
