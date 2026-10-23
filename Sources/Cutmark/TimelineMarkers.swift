import AppKit
import AVFoundation
import Combine
import SwiftUI

/// A screen-source marker as one occurrence in the edited output. A duplicated range
/// intentionally creates two pins, while a trimmed-away marker creates none.
struct TimelineMarkerPin: Equatable, Identifiable {
    let index: Int
    let take: Int
    let ordinal: Int
    let sourceTime: Double
    let outputTime: Double
    let label: String

    var id: String { "\(index):\(take):\(ordinal)" }
}

enum TimelineMarkers {
    /// The editor and TimelinePlayback both use the renderer's frame-rounded segment clock.
    /// Only actual screen frames receive pins; never infer a camera-to-screen offset.
    static func project(draft: EditTimelineDraft, eventsByTake: [Int: [CaptureEvent]]) -> [TimelineMarkerPin] {
        var pins: [TimelineMarkerPin] = []
        var at = 0.0
        for (index, segment) in draft.segments.enumerated() {
            defer { at += segment.duration }
            guard segment.kind == TakeKind.screen.rawValue, segment.duration.isFinite,
                  segment.duration > 0, let events = eventsByTake[segment.take] else { continue }
            let sourceStart = segment.renderSourceStart ?? segment.start
            let sourceEnd = min(segment.end, sourceStart + segment.duration)
            guard sourceStart.isFinite, sourceEnd.isFinite, sourceEnd > sourceStart else { continue }
            for (ordinal, event) in events.enumerated() where event.type == .marker && CaptureEventLog.valid(event) {
                // Source intervals are half-open. A marker on a cut boundary belongs to the
                // next occurrence, and no marker can appear in the non-exported tail.
                guard event.t >= sourceStart, event.t < sourceEnd else { continue }
                let output = at + event.t - sourceStart
                guard output.isFinite, output >= at, output < at + segment.duration else { continue }
                pins.append(.init(index: index, take: segment.take, ordinal: ordinal, sourceTime: event.t,
                                  outputTime: output,
                                  label: String((event.label.flatMap { $0.isEmpty ? nil : $0 }
                                                 ?? "Marker \(ordinal + 1)").prefix(120))))
            }
        }
        let sorted = pins.sorted {
            if $0.outputTime != $1.outputTime { return $0.outputTime < $1.outputTime }
            return $0.index < $1.index
        }
        // Marker-rich imports and duplicated clips must never create thousands of SwiftUI
        // buttons. Keep a deterministic sample across the entire output, including both ends.
        let maximumVisible = 320
        guard sorted.count > maximumVisible else { return sorted }
        return (0..<maximumVisible).map { i in
            sorted[i * (sorted.count - 1) / (maximumVisible - 1)]
        }
    }
}

@MainActor
final class TimelineMarkerCache: ObservableObject {
    @Published private(set) var pins: [TimelineMarkerPin] = []

    private struct Key: Hashable {
        let source: URL
        let sourceSize: Int64
        let sourceDate: Date?
        let log: URL
        let logSize: Int64
        let logDate: Date?

        init?(source: URL, log: URL) {
            guard let media = try? FileManager.default.attributesOfItem(atPath: source.path),
                  let events = try? FileManager.default.attributesOfItem(atPath: log.path),
                  let mediaSize = media[.size] as? NSNumber,
                  let eventsSize = events[.size] as? NSNumber else { return nil }
            self.source = source
            sourceSize = mediaSize.int64Value
            sourceDate = media[.modificationDate] as? Date
            self.log = log
            logSize = eventsSize.int64Value
            logDate = events[.modificationDate] as? Date
        }
    }

    private var retained: [Key: [CaptureEvent]] = [:]
    private var generation = 0

    func load(draft: EditTimelineDraft, session: URL) async {
        generation += 1
        let mine = generation
        // One read per screen take even when the edited timeline uses it many times.
        var byTake: [Int: URL] = [:]
        for segment in draft.segments where segment.kind == TakeKind.screen.rawValue {
            if byTake[segment.take] == nil {
                byTake[segment.take] = TimelineMedia.sourceURL(for: segment, session: session)
            }
        }
        var fetched: [Int: [CaptureEvent]] = [:]
        var activeKeys: Set<Key> = []
        let root = session.standardizedFileURL.resolvingSymlinksInPath()
        let rootPrefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        for (take, source) in byTake.sorted(by: { $0.key < $1.key }) {
            guard !Task.isCancelled, generation == mine else { return }
            let log = CaptureEventLog.url(in: session, take: take)
            // Ignore a redirected events folder; timeline markers must come from this session.
            guard log.standardizedFileURL.resolvingSymlinksInPath().path.hasPrefix(rootPrefix)
            else { continue }
            guard let key = Key(source: source, log: log) else { continue }
            activeKeys.insert(key)
            if let cached = retained[key] { fetched[take] = cached; continue }
            let movie = AVURLAsset(url: source)
            guard let duration = try? await movie.load(.duration).seconds,
                  duration.isFinite, duration > 0 else { continue }
            let events = await Task.detached(priority: .utility) {
                CaptureEventLog.markers(in: session, screenFile: source, through: duration,
                                        shouldCancel: { Task.isCancelled })
            }.value
            guard !Task.isCancelled, generation == mine else { return }
            retained[key] = events
            fetched[take] = events
        }
        guard !Task.isCancelled, generation == mine else { return }
        retained = retained.filter { activeKeys.contains($0.key) }
        pins = TimelineMarkers.project(draft: draft, eventsByTake: fetched)
    }

    func clear() {
        generation += 1
        pins = []
        retained = [:]
    }
}

/// One ruler for timeline time labels and source-derived recording markers.
struct TimelineMarkerRuler: View {
    let pins: [TimelineMarkerPin]
    let pixelsPerSecond: Double
    let duration: Double
    let onSeek: (TimelineMarkerPin) -> Void
    let onScrub: (CGFloat) -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            Canvas { context, size in
                let step = TimelineCanvasLayout.rulerStep(pixelsPerSecond: pixelsPerSecond)
                let count = Int(min(6000, (Double(size.width) / pixelsPerSecond / step).rounded(.down)))
                for n in 0...count {
                    let seconds = Double(n) * step
                    let x = CGFloat(seconds * pixelsPerSecond)
                    let pastOutput = seconds > duration
                    var line = Path()
                    line.move(to: CGPoint(x: x, y: 18))
                    line.addLine(to: CGPoint(x: x, y: 26))
                    context.stroke(line, with: .color(Theme.muted.opacity(pastOutput ? 0.25 : 0.8)),
                                   lineWidth: 0.7)
                    let label = context.resolve(Text(formatTime(seconds)).font(Theme.mono(9.5))
                        .foregroundStyle(Theme.muted.opacity(pastOutput ? 0.35 : 1)))
                    context.draw(label, at: CGPoint(x: x + (n == 0 ? 20 : 3), y: 7), anchor: .leading)
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { onScrub($0.location.x) })
            .help("Click or drag to seek. The blank tail is not exported.")

            ForEach(pins) { pin in
                Button { onSeek(pin) } label: {
                    Image(systemName: "bookmark.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Theme.accent)
                        .frame(width: 19, height: 17)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .offset(x: CGFloat(pin.outputTime * pixelsPerSecond) - 9.5, y: 15)
                .accessibilityLabel("\(pin.label) · Take \(pin.take) · \(formatTime(pin.outputTime))")
                .help("\(pin.label) · \(formatTime(pin.outputTime))")
            }
        }
        .frame(height: TimelineCanvasLayout.rulerHeight)
        .background(Theme.canvas)
    }

    private func formatTime(_ seconds: Double) -> String {
        let value = max(0, seconds.isFinite ? seconds : 0)
        return String(format: "%01d:%05.2f", Int(value / 60), value.truncatingRemainder(dividingBy: 60))
    }
}
