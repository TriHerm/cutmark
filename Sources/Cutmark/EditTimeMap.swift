import Foundation

/// One clock for an edit (2026-10-16). A Cutmark edit can reorder ranges from several takes and
/// camera/screen files, so source time is identified by both the take and its kind. Preview, words,
/// comments and future speed changes must all use this map instead of each summing cut durations.
struct EditTimeMap: Equatable {
    struct Source: Hashable {
        let take: Int
        let kind: TakeKind
    }

    struct Cut: Equatable {
        let source: Source
        let `in`: Double
        let out: Double
        var rate: Double = 1
    }

    struct Span: Equatable {
        let index: Int
        let source: Source
        let sourceIn: Double
        let sourceOut: Double
        let outputStart: Double
        let outputEnd: Double
        let rate: Double

        var outputDuration: Double { outputEnd - outputStart }
    }

    struct MappedRange: Equatable {
        let spanIndex: Int
        let sourceIn: Double
        let sourceOut: Double
        let outputIn: Double
        let outputOut: Double
        let rate: Double
    }

    let lead: Double
    let spans: [Span]
    let duration: Double

    init(cuts: [Cut], lead: Double = 0) {
        self.lead = lead
        var at = lead
        var made: [Span] = []
        made.reserveCapacity(cuts.count)
        for (i, cut) in cuts.enumerated() {
            precondition(cut.rate > 0, "timeline rate must be greater than zero")
            let rate = cut.rate
            let length = max(0, cut.out - cut.in)
            let end = at + length / rate
            made.append(Span(index: i, source: cut.source, sourceIn: cut.in, sourceOut: cut.out,
                             outputStart: at, outputEnd: end, rate: rate))
            at = end
        }
        spans = made
        duration = at
    }

    /// Every place a source moment appears. A source range can be intentionally reused later in an edit.
    func outputTimes(source: Source, time: Double) -> [Double] {
        spans.enumerated().compactMap { i, span in
            let contains = span.sourceIn <= time && (time < span.sourceOut || (i == spans.count - 1 && time == span.sourceOut))
            guard span.source == source, contains else { return nil }
            return span.outputStart + (min(time, span.sourceOut) - span.sourceIn) / span.rate
        }
    }

    /// Every intersection of one source interval with this edit. Each returned range belongs to one
    /// timeline span, so reused source ranges never cross-pair their start/end occurrences. Source and
    /// output intervals are half-open; a cut simply removes the part that does not intersect a span.
    func outputRanges(source: Source, in sourceIn: Double, out sourceOut: Double) -> [MappedRange] {
        guard sourceOut > sourceIn else { return [] }
        return spans.compactMap { span in
            guard span.source == source else { return nil }
            let a = max(sourceIn, span.sourceIn)
            let b = min(sourceOut, span.sourceOut)
            guard b > a else { return nil }
            return MappedRange(
                spanIndex: span.index,
                sourceIn: a,
                sourceOut: b,
                outputIn: span.outputStart + (a - span.sourceIn) / span.rate,
                outputOut: span.outputStart + (b - span.sourceIn) / span.rate,
                rate: span.rate
            )
        }
    }

    /// The source under an output moment. Output-only lead time (a cover) has no source.
    func source(at outputTime: Double) -> (source: Source, time: Double)? {
        guard let span = spans.enumerated().first(where: { i, span in
            span.outputStart <= outputTime && (outputTime < span.outputEnd || (i == spans.count - 1 && outputTime == span.outputEnd))
        })?.element else { return nil }
        return (span.source, min(span.sourceOut, span.sourceIn + (outputTime - span.outputStart) * span.rate))
    }
}
