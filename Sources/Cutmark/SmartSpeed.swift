import Foundation

/// One source-clock range that should remain at normal speed while smart-speed planning looks for
/// idle gaps. Today these come from prepared speech words and voiced non-word sounds.
struct SmartSpeedProtectedRange: Equatable, Sendable {
    let `in`: Double
    let out: Double
}

/// A conservative, non-destructive speed suggestion for one screen take. The planner only proposes
/// silent, interaction-free source ranges; it never changes media or an EditRecipe.
struct SmartSpeedSuggestion: Equatable, Sendable {
    let take: Int
    let sourceIn: Double
    let sourceOut: Double
    let rate: Double
    let reason: String
}

struct MappedSmartSpeedSuggestion: Equatable, Sendable {
    let suggestion: SmartSpeedSuggestion
    let outputIn: Double
    let outputOut: Double
    let suggestedOutputDuration: Double
    let spanIndex: Int
}

enum SmartSpeedPlanner {
    static let version = 1
    static let identifier = "idle_silence_v1"

    /// V1 deliberately stays mild. It only proposes speeding dead screen time; spoken or otherwise
    /// voiced audio, pointer/scroll/click activity and deliberate markers keep normal speed.
    static let rate = 1.5
    static let visualGuard = 0.25
    static let activityGuard = 0.35
    static let markerGuard = 0.75
    static let speechGuard = 0.40
    static let edgeGuard = 0.50
    static let minSourceDuration = 2.5
    static let minMappedSourceDuration = 1.50

    static func suggestions(events: [CaptureEvent], spoken: [SmartSpeedProtectedRange],
                            sounds: [SmartSpeedProtectedRange], take: Int,
                            through duration: Double?) -> [SmartSpeedSuggestion] {
        guard let duration, duration.isFinite, duration > 0 else { return [] }
        let idle = visualIdleRanges(events: events, through: duration)
        guard !idle.isEmpty else { return [] }

        var protected: [SmartSpeedProtectedRange] = []

        protected.append(.init(in: 0, out: min(duration, edgeGuard)))
        protected.append(.init(in: max(0, duration - edgeGuard), out: duration))

        for event in events where event.source == .screen && event.t.isFinite && event.t >= 0 && event.t <= duration + 0.001 {
            let guardTime: Double
            switch event.type {
            case .move, .down, .up, .scroll:
                guardTime = activityGuard
            case .marker:
                guardTime = markerGuard
            case .recordingStarted, .recordingStopped, .visualActive, .visualIdle:
                continue
            }
            protected.append(.init(in: max(0, event.t - guardTime), out: min(duration, event.t + guardTime)))
        }

        for range in spoken + sounds {
            guard range.in.isFinite, range.out.isFinite, range.out > range.in else { continue }
            let a = max(0, range.in - speechGuard)
            let b = min(duration, range.out + speechGuard)
            if b > a { protected.append(.init(in: a, out: b)) }
        }

        let merged = merge(protected, through: duration)
        var result: [SmartSpeedSuggestion] = []
        for visual in idle {
            var cursor = visual.in
            for block in merged where block.out > visual.in && block.in < visual.out {
                let a = max(visual.in, block.in)
                let b = min(visual.out, block.out)
                if a - cursor >= minSourceDuration {
                    result.append(.init(take: take, sourceIn: cursor, sourceOut: a,
                                        rate: rate, reason: "idle_silence"))
                }
                cursor = max(cursor, b)
            }
            if visual.out - cursor >= minSourceDuration {
                result.append(.init(take: take, sourceIn: cursor, sourceOut: visual.out,
                                    rate: rate, reason: "idle_silence"))
            }
        }
        return result
    }

    /// Only ScreenCaptureKit can tell us that captured pixels stopped changing. Mouse inactivity is
    /// insufficient because keyboard-driven work can change the screen without pointer activity.
    private static func visualIdleRanges(events: [CaptureEvent], through duration: Double) -> [SmartSpeedProtectedRange] {
        let ordered = events.enumerated().filter {
            $0.element.source == .screen && $0.element.t.isFinite && $0.element.t >= 0 && $0.element.t <= duration + 0.001
        }.sorted {
            if $0.element.t == $1.element.t { return $0.offset < $1.offset }
            return $0.element.t < $1.element.t
        }.map(\.element)
        var start: Double?
        var out: [SmartSpeedProtectedRange] = []
        for event in ordered {
            switch event.type {
            case .visualIdle:
                if start == nil { start = event.t }
            case .visualActive:
                if let idleStart = start {
                    let a = max(0, idleStart + visualGuard)
                    let b = min(duration, event.t - visualGuard)
                    if b > a { out.append(.init(in: a, out: b)) }
                    start = nil
                }
            default:
                continue
            }
        }
        if let start {
            let a = max(0, start + visualGuard)
            let b = max(a, duration - visualGuard)
            if b > a { out.append(.init(in: a, out: b)) }
        }
        return out
    }


    private static func merge(_ ranges: [SmartSpeedProtectedRange], through duration: Double) -> [SmartSpeedProtectedRange] {
        let sorted = ranges.compactMap { range -> SmartSpeedProtectedRange? in
            let a = min(duration, max(0, range.in))
            let b = min(duration, max(0, range.out))
            return b > a ? .init(in: a, out: b) : nil
        }.sorted { $0.in == $1.in ? $0.out < $1.out : $0.in < $1.in }
        var out: [SmartSpeedProtectedRange] = []
        for range in sorted {
            if let last = out.last, range.in <= last.out {
                out[out.count - 1] = .init(in: last.in, out: max(last.out, range.out))
            } else {
                out.append(range)
            }
        }
        return out
    }
}

extension EditTimeMap {
    /// Map each proposed source interval independently through matching screen spans. Cuts can split an
    /// idle range and source reuse can intentionally duplicate it; camera spans never receive screen speed.
    func outputSmartSpeeds(_ suggestions: [SmartSpeedSuggestion], take: Int,
                           minimumSourceDuration: Double = SmartSpeedPlanner.minMappedSourceDuration)
        -> [MappedSmartSpeedSuggestion] {
        let source = Source(take: take, kind: .screen)
        var out: [MappedSmartSpeedSuggestion] = []
        for suggestion in suggestions where suggestion.take == take {
            for range in outputRanges(source: source, in: suggestion.sourceIn, out: suggestion.sourceOut) {
                let survivingSource = range.sourceOut - range.sourceIn
                guard survivingSource >= minimumSourceDuration else { continue }
                let currentDuration = range.outputOut - range.outputIn
                out.append(.init(suggestion: suggestion, outputIn: range.outputIn, outputOut: range.outputOut,
                                 suggestedOutputDuration: currentDuration / suggestion.rate,
                                 spanIndex: range.spanIndex))
            }
        }
        return out.sorted {
            if $0.outputIn == $1.outputIn { return $0.spanIndex < $1.spanIndex }
            return $0.outputIn < $1.outputIn
        }
    }
}
