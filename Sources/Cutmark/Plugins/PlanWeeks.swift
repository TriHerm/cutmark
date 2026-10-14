import SwiftUI

/// The Plan board's chart (2026-10-10, in place of the four number tiles): videos per week,
/// posted (green), scheduled (blue) and planned (dashed), against the goal of posting days a
/// week. The last six weeks, this week and the plan's weeks ahead. Hover a week for its numbers.
struct PlanWeeks: View {
    let weeks: [ConsistencyStats.WeekCount]
    let goal: Int
    let note: String
    /// The game: draws the streak chain under the weeks and a crown over the best post's week.
    var game: WeekGame?
    var open: (URL) -> Void = { _ in }
    @State private var hovered: Date?

    private let plotHeight: CGFloat = 120

    var body: some View {
        let top = max(goal, weeks.map(\.total).max() ?? 0, 1)
        let this = Calendar.current.dateInterval(of: .weekOfYear, for: Date())?.start
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text("Videos per week").font(Theme.sans(13, .semibold)).foregroundStyle(Theme.ink)
                if let game {
                    if game.streak > 0 { streakPill(game) }
                    Spacer()
                    Text(GameWords.streak(game)).font(Theme.sans(11.5)).foregroundStyle(Theme.muted)
                        .swapIn(GameWords.streak(game))
                } else {
                    Spacer()
                    legends
                }
            }
            GeometryReader { g in
                let col = g.size.width / CGFloat(max(weeks.count, 1))
                let bar = min(col * 0.55, 34)
                // Room above the tallest bar for the crown.
                let unit = (plotHeight - (crown == nil ? 0 : 18)) / CGFloat(top)
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
            if let game, game.streak > 0 || !game.chain.isEmpty { chain(game, this: this) }
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
                } else if game != nil {
                    legends.transition(.opacity)
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
        .overlay(alignment: .bottom) {
            if let c = crown, c.week == wk.start {
                // Sits on top of the bar.
                Button { open(c.win.url) } label: {
                    Image(systemName: "crown.fill").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.gold)
                }
                .buttonStyle(.plain)
                .offset(y: -(unit * CGFloat(wk.total) + 4))
                .help("\(c.win.label): \(c.win.title), \(Num.short(c.win.reach)) impressions on \(c.win.platform)")
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

    /// The best recent win and its week, when that week is on the chart.
    private var crown: (week: Date, win: WeekGame.Win)? {
        guard let w = game?.wins.first,
              let week = Calendar.current.dateInterval(of: .weekOfYear, for: w.at)?.start,
              weeks.contains(where: { $0.start == week }) else { return nil }
        return (week, w)
    }

    private func streakPill(_ g: WeekGame) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "flame.fill").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.gold)
            Text("\(g.streak) week\(g.streak == 1 ? "" : "s") in a row").font(Theme.sans(12, .semibold)).foregroundStyle(Theme.ink)
                .monospacedDigit()
        }
        .padding(.horizontal, 9).padding(.vertical, 4)
        .background(Capsule().fill(Theme.gold.opacity(0.13)))
        .help(GameWords.rest(g) + ". Miss a week? One rest week a month keeps your streak.")
    }

    /// The chain: a flame under each week that reached the goal, a moon on a rest week, a dashed
    /// circle on this week while it is still open. Gold links join them.
    private func chain(_ g: WeekGame, this: Date?) -> some View {
        let open = g.streak > 0 && !g.weekCounted ? this : nil
        return GeometryReader { geo in
            let col = geo.size.width / CGFloat(max(weeks.count, 1))
            ZStack(alignment: .topLeading) {
                ForEach(Array(weeks.enumerated()), id: \.element.id) { i, wk in
                    let here = g.chain[wk.start] != nil
                    if i + 1 < weeks.count, here {
                        let next = weeks[i + 1].start
                        if g.chain[next] != nil || next == open {
                            Capsule().fill(Theme.gold.opacity(next == open ? 0.18 : 0.45))
                                .frame(width: col, height: 3)
                                .offset(x: col * (CGFloat(i) + 0.5), y: 8.5)
                        }
                    }
                }
                ForEach(Array(weeks.enumerated()), id: \.element.id) { i, wk in
                    Group {
                        switch g.chain[wk.start] {
                        case .counted:
                            Image(systemName: "flame.fill").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.gold)
                                .frame(width: 20, height: 20).background(Circle().fill(Theme.canvas))
                                .help("Reached your goal")
                        case .rest:
                            Image(systemName: "moon.zzz.fill").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.muted)
                                .frame(width: 20, height: 20).background(Circle().fill(Theme.canvas))
                                .help("A rest week kept the streak going")
                        case nil:
                            if wk.start == open {
                                Circle().strokeBorder(Theme.gold.opacity(0.6), style: StrokeStyle(lineWidth: 1.5, dash: [3, 2]))
                                    .frame(width: 14, height: 14).background(Circle().fill(Theme.canvas))
                                    .help(GameWords.streak(g))
                            }
                        }
                    }
                    .position(x: col * (CGFloat(i) + 0.5), y: 10)
                }
            }
        }
        .frame(height: 20)
    }

    private var legends: some View {
        HStack(spacing: 14) {
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
