import Testing
@testable import Cutmark

struct SmartSpeedTests {
    private func event(_ t: Double, _ type: CaptureEvent.Kind) -> CaptureEvent {
        .init(t: t, type: type)
    }

    @Test func plannerOnlySuggestsLongSilentInteractionFreeGaps() {
        let suggestions = SmartSpeedPlanner.suggestions(
            events: [
                event(0.0, .visualActive), event(0.6, .visualIdle), event(3.7, .visualActive),
                event(8.6, .visualIdle), event(11.7, .visualActive),
            ],
            spoken: [.init(in: 5.0, out: 6.0)], sounds: [], take: 2, through: 12.0)

        #expect(suggestions.count == 2)
        #expect(abs(suggestions[0].sourceIn - 0.85) < 0.0001)
        #expect(abs(suggestions[0].sourceOut - 3.45) < 0.0001)
        #expect(abs(suggestions[1].sourceIn - 8.85) < 0.0001)
        #expect(abs(suggestions[1].sourceOut - 11.45) < 0.0001)
        #expect(suggestions.allSatisfy { $0.rate == 1.5 && $0.reason == "idle_silence" })

        let guarded = SmartSpeedPlanner.suggestions(
            events: [event(0, .visualActive), event(0.25, .visualIdle), event(4.5, .marker), event(9.75, .visualActive)],
            spoken: [], sounds: [], take: 1, through: 10.0)
        #expect(guarded.count == 2)
        #expect(abs(guarded[0].sourceIn - 0.5) < 0.0001)
        #expect(abs(guarded[0].sourceOut - 3.75) < 0.0001)
        #expect(abs(guarded[1].sourceIn - 5.25) < 0.0001)
        #expect(abs(guarded[1].sourceOut - 9.5) < 0.0001)
    }

    @Test func voicedNonWordSoundsProtectOtherwiseIdleTime() {
        let suggestions = SmartSpeedPlanner.suggestions(
            events: [event(0, .visualActive), event(0.25, .visualIdle), event(8.75, .visualActive)],
            spoken: [], sounds: [.init(in: 4.0, out: 5.0)], take: 1, through: 9.0)
        #expect(suggestions.count == 2)
        #expect(abs(suggestions[0].sourceIn - 0.5) < 0.0001)
        #expect(abs(suggestions[0].sourceOut - 3.6) < 0.0001)
        #expect(abs(suggestions[1].sourceIn - 5.4) < 0.0001)
        #expect(abs(suggestions[1].sourceOut - 8.5) < 0.0001)
    }

    @Test func pointerSilenceWithoutVisualIdleNeverCreatesASuggestion() {
        let suggestions = SmartSpeedPlanner.suggestions(
            events: [event(0, .visualActive), event(3, .move), event(7, .marker)],
            spoken: [], sounds: [], take: 1, through: 12.0)
        #expect(suggestions.isEmpty)
    }

    @Test func mappingSplitsCutsDuplicatesReuseAndIgnoresCamera() {
        let screen = EditTimeMap.Source(take: 4, kind: .screen)
        let map = EditTimeMap(cuts: [
            .init(source: screen, in: 1, out: 5),
            .init(source: .init(take: 4, kind: .camera), in: 1, out: 5),
            .init(source: screen, in: 2, out: 5, rate: 2),
        ], lead: 0.1)
        let idle = SmartSpeedSuggestion(take: 4, sourceIn: 1.5, sourceOut: 4.5,
                                        rate: 1.5, reason: "idle_silence")
        let mapped = map.outputSmartSpeeds([idle], take: 4)
        #expect(mapped.count == 2)
        #expect(mapped.map(\.spanIndex) == [0, 2])
        #expect(abs(mapped[0].outputIn - 0.6) < 0.0001)
        #expect(abs(mapped[0].outputOut - 3.6) < 0.0001)
        #expect(abs(mapped[0].suggestedOutputDuration - 2.0) < 0.0001)
        #expect(abs(mapped[1].outputIn - 8.1) < 0.0001)
        #expect(abs(mapped[1].outputOut - 9.35) < 0.0001)
        #expect(abs(mapped[1].suggestedOutputDuration - (1.25 / 1.5)) < 0.0001)
    }

    @Test func tinyCutFragmentsAreNotSuggestedForSpeedChanges() {
        let screen = EditTimeMap.Source(take: 1, kind: .screen)
        let map = EditTimeMap(cuts: [.init(source: screen, in: 2.0, out: 3.2)])
        let idle = SmartSpeedSuggestion(take: 1, sourceIn: 1.0, sourceOut: 4.0,
                                        rate: 1.5, reason: "idle_silence")
        #expect(map.outputSmartSpeeds([idle], take: 1).isEmpty)
        #expect(SmartSpeedPlanner.version == 1)
        #expect(SmartSpeedPlanner.identifier == "idle_silence_v1")
    }
}
