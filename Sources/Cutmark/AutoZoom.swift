import Foundation

/// A conservative, non-destructive zoom suggestion derived from one screen take's capture events.
/// The planner never changes source media or an EditRecipe. `source*` stays on the screen take's PTS
/// clock; callers can project the suggestion through EditTimeMap when an edit exists.
struct AutoZoomSuggestion: Equatable, Sendable {
    let take: Int
    let sourceTrigger: Double
    let sourceIn: Double
    let sourceOut: Double
    let focusX: Double
    let focusY: Double
    let scale: Double
    let reason: String
}

struct MappedAutoZoomSuggestion: Equatable, Sendable {
    let suggestion: AutoZoomSuggestion
    let outputTrigger: Double?
    let outputIn: Double
    let outputOut: Double
    let spanIndex: Int
}

enum AutoZoomPlanner {
    static let version = 1
    static let identifier = "click_focus_v1"
    /// Deliberately modest: enough to focus the UI target without turning ordinary screen capture into
    /// constant camera motion. Later rendering may ease into/out of this rectangle; the planner only
    /// proposes the stable interval and target.
    static let scale = 1.35
    static let preRoll = 0.12
    static let hold = 1.35
    static let mergeWindow = 0.75
    static let sameTargetRadius = 0.10
    static let pointerWindow = 0.18
    static let pointerRadius = 0.08
    static let minGap = 0.20
    static let minMappedDuration = 0.35

    /// Primary-button downs are the only trigger in v1. Right/other clicks, scrolls and movement alone
    /// do not cause zooms. Nearby pointer samples only stabilize the target around the click.
    static func suggestions(events: [CaptureEvent], take: Int, through duration: Double? = nil) -> [AutoZoomSuggestion] {
        let limit = duration.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        let ordered = events.enumerated().sorted {
            if $0.element.t == $1.element.t { return $0.offset < $1.offset }
            return $0.element.t < $1.element.t
        }.map(\.element)
        let moves = ordered.filter { event in
            guard event.type == .move, event.t.isFinite,
                  let x = event.x, let y = event.y else { return false }
            return x.isFinite && y.isFinite && (0...1).contains(x) && (0...1).contains(y)
        }
        let clicks = ordered.filter { event in
            guard event.type == .down, event.button == 0, event.t.isFinite, event.t >= 0,
                  let x = event.x, let y = event.y,
                  x.isFinite, y.isFinite, (0...1).contains(x), (0...1).contains(y) else { return false }
            return limit.map { event.t <= $0 + 0.001 } ?? true
        }

        // Collapse a rapid click burst before planning motion. The user's last click is the most useful
        // focus target (double-clicks and quick navigation often end somewhere slightly different), while
        // the burst's first click supplies the earliest safe pre-roll.
        var bursts: [[CaptureEvent]] = []
        for click in clicks {
            if let last = bursts.last?.last, click.t - last.t <= mergeWindow {
                bursts[bursts.count - 1].append(click)
            } else {
                bursts.append([click])
            }
        }

        var out: [AutoZoomSuggestion] = []
        for burst in bursts {
            guard let first = burst.first, let click = burst.last,
                  let x = click.x, let y = click.y else { continue }
            let focus = stabilizedFocus(clickX: x, clickY: y, at: click.t, moves: moves)
            let sourceOut = min(limit ?? (click.t + hold), click.t + hold)
            guard sourceOut > max(0, first.t - preRoll) else { continue }
            let candidate = AutoZoomSuggestion(
                take: take,
                sourceTrigger: click.t,
                sourceIn: max(0, first.t - preRoll),
                sourceOut: sourceOut,
                focusX: focus.x,
                focusY: focus.y,
                scale: scale,
                reason: "primary_click"
            )

            if let last = out.last {
                let distance = hypot(candidate.focusX - last.focusX, candidate.focusY - last.focusY)
                if distance <= sameTargetRadius, candidate.sourceIn <= last.sourceOut + minGap {
                    // Same target again: keep one continuous zoom, but let the newest click define focus.
                    out[out.count - 1] = AutoZoomSuggestion(
                        take: last.take,
                        sourceTrigger: candidate.sourceTrigger,
                        sourceIn: last.sourceIn,
                        sourceOut: max(last.sourceOut, candidate.sourceOut),
                        focusX: candidate.focusX,
                        focusY: candidate.focusY,
                        scale: last.scale,
                        reason: last.reason
                    )
                    continue
                }
                // Far targets do not overlap. Shorten the older suggestion to leave a neutral gap; if
                // that would end it before its own trigger, the newer navigation target wins entirely.
                if candidate.sourceIn < last.sourceOut + minGap {
                    let shortened = candidate.sourceIn - minGap
                    if shortened > last.sourceTrigger {
                        out[out.count - 1] = AutoZoomSuggestion(
                            take: last.take, sourceTrigger: last.sourceTrigger, sourceIn: last.sourceIn,
                            sourceOut: shortened, focusX: last.focusX, focusY: last.focusY,
                            scale: last.scale, reason: last.reason)
                    } else {
                        out.removeLast()
                    }
                }
            }
            out.append(candidate)
        }
        return out
    }

    private static func stabilizedFocus(clickX: Double, clickY: Double, at time: Double,
                                        moves: [CaptureEvent]) -> (x: Double, y: Double) {
        var points = [(clickX, clickY)]
        for move in moves {
            guard abs(move.t - time) <= pointerWindow, let x = move.x, let y = move.y,
                  hypot(x - clickX, y - clickY) <= pointerRadius else { continue }
            points.append((x, y))
        }
        let xs = points.map(\.0).sorted()
        let ys = points.map(\.1).sorted()
        return (median(xs), median(ys))
    }

    private static func median(_ xs: [Double]) -> Double {
        guard !xs.isEmpty else { return 0.5 }
        let i = xs.count / 2
        return xs.count.isMultiple(of: 2) ? (xs[i - 1] + xs[i]) / 2 : xs[i]
    }

}

extension EditTimeMap {
    /// A click must survive somewhere in the edit before any part of its zoom window is mapped. The
    /// interval is then intersected with each matching screen span, so cuts can split it and reused
    /// source ranges can intentionally duplicate it. Very short fragments are dropped to avoid flashes.
    func outputZooms(_ suggestions: [AutoZoomSuggestion], take: Int,
                     minimumDuration: Double = AutoZoomPlanner.minMappedDuration) -> [MappedAutoZoomSuggestion] {
        let source = Source(take: take, kind: .screen)
        var out: [MappedAutoZoomSuggestion] = []
        for suggestion in suggestions where suggestion.take == take {
            // A suggestion whose click was completely removed must not leak a pre/post window into the edit.
            guard !outputTimes(source: source, time: suggestion.sourceTrigger).isEmpty else { continue }
            for range in outputRanges(source: source, in: suggestion.sourceIn, out: suggestion.sourceOut) {
                guard range.outputOut - range.outputIn >= minimumDuration else { continue }
                let span = spans[range.spanIndex]
                let containsTrigger = span.sourceIn <= suggestion.sourceTrigger && suggestion.sourceTrigger < span.sourceOut
                let trigger = containsTrigger
                    ? span.outputStart + (suggestion.sourceTrigger - span.sourceIn) / span.rate : nil
                out.append(.init(suggestion: suggestion, outputTrigger: trigger, outputIn: range.outputIn,
                                 outputOut: range.outputOut, spanIndex: range.spanIndex))
            }
        }
        return out.sorted {
            if $0.outputIn == $1.outputIn { return $0.spanIndex < $1.spanIndex }
            return $0.outputIn < $1.outputIn
        }
    }
}
