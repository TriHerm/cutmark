import SwiftUI

/// The Plan board's chart (2026-10-10, in place of the four number tiles): videos per week,
/// posted (green), scheduled (blue) and planned (dashed), against the goal of posting days a
/// week. The last six weeks, this week and the plan's weeks ahead. Hover a week for its numbers.
struct PlanWeeks: View {
    let weeks: [ConsistencyStats.WeekCount]
    let goal: Int
    let note: String
    @State private var hovered: Date?

    private let plotHeight: CGFloat = 120

    var body: some View {
        let top = max(goal, weeks.map(\.total).max() ?? 0, 1)
        let this = Calendar.current.dateInterval(of: .weekOfYear, for: Date())?.start
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                Text("Videos per week").font(Theme.sans(13, .semibold)).foregroundStyle(Theme.ink)
                Spacer()
                legend("Posted") { RoundedRectangle(cornerRadius: 2).fill(Theme.live) }
                legend("Scheduled") { RoundedRectangle(cornerRadius: 2).fill(Theme.accent) }
                legend("Planned") {
                    RoundedRectangle(cornerRadius: 2).strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 1.2, dash: [3, 2]))
                }
                if goal > 0 {
                    legend("Goal: \(goal) a week") {
                        Rectangle().fill(Theme.muted).frame(height: 1.5).frame(maxHeight: .infinity)
                    }
                }
            }
            GeometryReader { g in
                let col = g.size.width / CGFloat(max(weeks.count, 1))
                let bar = min(col * 0.55, 34)
                let unit = plotHeight / CGFloat(top)
                ZStack(alignment: .topLeading) {
                    Rectangle().fill(Theme.border).frame(width: g.size.width, height: 1).offset(y: plotHeight)
                    ForEach(Array(weeks.enumerated()), id: \.element.id) { i, wk in
                        column(wk, bar: bar, unit: unit, now: wk.start == this)
                            .frame(width: col, height: plotHeight)
                            .offset(x: CGFloat(i) * col)
                    }
                    if goal > 0 {
                        Path { p in
                            let y = plotHeight - unit * CGFloat(goal)
                            p.move(to: CGPoint(x: 0, y: y))
                            p.addLine(to: CGPoint(x: g.size.width, y: y))
                        }
                        .stroke(Theme.muted, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                        .allowsHitTesting(false)
                    }
                }
            }
            .frame(height: plotHeight)
            HStack(spacing: 0) {
                ForEach(weeks) { wk in
                    let now = wk.start == this
                    Text(now ? "This week" : Self.label(wk.start))
                        .font(Theme.sans(10, now ? .semibold : .regular))
                        .foregroundStyle(now ? Theme.ink : Theme.faint)
                        .lineLimit(1).minimumScaleFactor(0.7)
                        .frame(maxWidth: .infinity)
                }
            }
            HStack {
                Text(note).font(Theme.sans(11.5)).foregroundStyle(Theme.faint)
                Spacer()
                if let h = hovered, let wk = weeks.first(where: { $0.start == h }) {
                    Text(Self.words(wk, now: wk.start == this)).font(Theme.sans(11.5, .medium)).foregroundStyle(Theme.ink)
                        .transition(.opacity)
                }
            }
        }
    }

    private func column(_ wk: ConsistencyStats.WeekCount, bar: CGFloat, unit: CGFloat, now: Bool) -> some View {
        VStack(spacing: 2) {
            Spacer(minLength: 0)
            if wk.planned > 0 {
                RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 1.4, dash: [4, 3]))
                    .frame(width: bar, height: max(unit * CGFloat(wk.planned) - 2, 3))
            }
            if wk.scheduled > 0 {
                RoundedRectangle(cornerRadius: 4).fill(Theme.accent)
                    .frame(width: bar, height: max(unit * CGFloat(wk.scheduled) - 2, 3))
            }
            if wk.posted > 0 {
                RoundedRectangle(cornerRadius: 4).fill(Theme.live)
                    .frame(width: bar, height: max(unit * CGFloat(wk.posted) - 2, 3))
            }
        }
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 8)
            .fill(hovered == wk.start ? Theme.hover : now ? Theme.hover.opacity(0.5) : .clear)
            .padding(.horizontal, 2))
        .contentShape(Rectangle())
        .onHover { on in
            withAnimation(Theme.motion) { if on { hovered = wk.start } else if hovered == wk.start { hovered = nil } }
        }
    }

    private func legend<S: View>(_ text: String, @ViewBuilder swatch: () -> S) -> some View {
        HStack(spacing: 5) {
            swatch().frame(width: 12, height: 10)
            Text(text).font(Theme.sans(11)).foregroundStyle(Theme.muted)
        }
    }

    static func label(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f.string(from: d)
    }

    static func words(_ w: ConsistencyStats.WeekCount, now: Bool) -> String {
        var parts: [String] = []
        if w.posted > 0 { parts.append("\(w.posted) posted") }
        if w.scheduled > 0 { parts.append("\(w.scheduled) scheduled") }
        if w.planned > 0 { parts.append("\(w.planned) planned") }
        return (now ? "This week" : "Week of \(label(w.start))") + ": " + (parts.isEmpty ? "no videos" : parts.joined(separator: ", "))
    }
}
