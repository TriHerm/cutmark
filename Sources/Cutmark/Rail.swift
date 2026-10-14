import AppKit
import SwiftUI

// The window frame as in Codex (2026-10-11, picked in Claude Design): one 44 pt row on top with the
// traffic lights, sidebar, ‹ › and the page's title and tabs; under it a rail of board icons, the
// session list, and the page as one raised panel. The user found the old frame ugly: the lights,
// the ‹ › and the page title each sat on a different line.

enum Chrome {
    /// The top row. The traffic lights move down to its middle.
    static let bar: CGFloat = 44
    /// The board rail on the left.
    static let rail: CGFloat = 56
    /// The close button's left edge.
    static let lightsX: CGFloat = 18
    /// Where ‹ › start: after the three lights, or at the left edge in full screen.
    static func navX(fullScreen: Bool) -> CGFloat { fullScreen ? 12 : 84 }
    /// The end of the sidebar button, so a page title clears it when the sidebar is hidden.
    static func navEnd(fullScreen: Bool) -> CGFloat { navX(fullScreen: fullScreen) + 3 * 28 + 8 }
}

// A plain key, not @Entry: build.sh builds with the Command Line Tools (no macro plugin).
private struct TitleInsetKey: EnvironmentKey { static let defaultValue: CGFloat = 0 }

extension EnvironmentValues {
    /// Extra room before a page title in the top row: the sidebar is hidden and ‹ › sit there.
    var titleInset: CGFloat {
        get { self[TitleInsetKey.self] }
        set { self[TitleInsetKey.self] = newValue }
    }
}

extension View {
    /// The page as one raised panel under the top row, with a gap to the window's edge.
    func pagePanel() -> some View {
        self
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.paper)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
            .padding(.trailing, 8).padding(.bottom, 8)
    }
}

/// A board's line in the top row: its name, where a session shows its title and tabs.
struct BoardTitleBar: View {
    let title: String
    @Environment(\.titleInset) private var inset

    var body: some View {
        HStack {
            Text(title).font(Theme.sans(14, .semibold)).foregroundStyle(Theme.ink)
            Spacer()
        }
        .padding(.leading, 20 + inset)
        .frame(height: Chrome.bar)
        .contentShape(Rectangle())
        .gesture(WindowDragGesture())
    }
}

// MARK: - Rail

/// The boards as icons, one column at the window's left edge.
struct BoardRail: View {
    /// The Plugins board can turn a plugin off: draw again without it.
    @AppStorage(Plugins.removedKey) private var pluginsRemoved = ""
    @Environment(AppModel.self) var app

    var body: some View {
        VStack(spacing: 4) {
            RailButton(icon: "video", title: "Sessions", key: nil, selected: app.board == nil) { app.board = nil }
            if Features.socialBoards {
                PerformanceRail(board: app.performance, selected: app.board == .performance) { app.board = .performance }
                CommentsRail(store: app.copilot, runner: app.copilot.runner, chat: app.chats.comments,
                             post: app.chats.commentsPost, selected: app.board == .comments) { app.board = .comments }
            }
            ForEach(Plugins.boards) { p in
                RailButton(icon: p.icon, title: p.title, key: "⇧⌘\(p.key.uppercased())",
                           selected: app.board == .plugin(p.id)) { app.board = .plugin(p.id) } badge: { p.badge(app) }
                    .help(p.help)
            }
            Spacer(minLength: 8)
            RailButton(icon: "square.stack", title: "Styles", key: "⇧⌘Y", selected: app.board == .styles) { app.board = .styles }
            RailButton(icon: "puzzlepiece.extension", title: "Plugins", key: "⇧⌘P", selected: app.board == .plugins) { app.board = .plugins }
        }
        .padding(.top, 2).padding(.bottom, 12)
        .frame(width: Chrome.rail)
        .frame(maxHeight: .infinity, alignment: .top)
        // The session list's post dots read the post plan.
        .onAppear { app.posts.scanInBackground(app.library.root) }
        .onReceive(NotificationCenter.default.publisher(for: .cutmarkFilesChanged)) { n in
            if let paths = n.object as? [String], PostQueue.matters(paths) { app.posts.scanInBackground(app.library.root) }
        }
    }
}

/// One board icon: a well on hover, a paper card when its board is open, its badge on the corner.
struct RailButton<Badge: View>: View {
    let icon: String
    let title: String
    let key: String?
    let selected: Bool
    let action: () -> Void
    @ViewBuilder var badge: Badge
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 15))
                .foregroundStyle(selected || hover ? Theme.ink : Theme.muted)
                .frame(width: 36, height: 36)
                .background {
                    if selected {
                        RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.paper)
                            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Theme.border, lineWidth: 0.5))
                    } else if hover {
                        RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.hover)
                    }
                }
                .overlay(alignment: .topTrailing) { badge.scaleEffect(0.8).offset(x: 5, y: -3) }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(Theme.motion, value: hover)
        .animation(Theme.motion, value: selected)
        .help(key.map { "\(title) (\($0))" } ?? title)
        .accessibilityLabel(title)
    }
}

extension RailButton where Badge == EmptyView {
    init(icon: String, title: String, key: String?, selected: Bool, action: @escaping () -> Void) {
        self.init(icon: icon, title: title, key: key, selected: selected, action: action) { EmptyView() }
    }
}

/// Performance on the rail; it keeps the board's numbers current, as its sidebar row did.
struct PerformanceRail: View {
    @Environment(AppModel.self) var app
    @ObservedObject var board: PerfBoard
    let selected: Bool
    let open: () -> Void

    var body: some View {
        let reach = board.items.compactMap(\.post.latest?.reach).reduce(0, +)
        RailButton(icon: "chart.bar.xaxis", title: reach > 0 ? "Performance · \(Num.short(reach))" : "Performance",
                   key: "⇧⌘J", selected: selected, action: open)
            .onAppear { board.scan(app.library.root) }
            .onReceive(NotificationCenter.default.publisher(for: .cutmarkFilesChanged)) { n in
                if let paths = n.object as? [String], PerfBoard.matters(paths, root: app.library.root) {
                    board.scan(app.library.root)
                }
            }
    }
}

/// Comments on the rail, with how many drafts wait.
struct CommentsRail: View {
    @Environment(AppModel.self) var app
    @ObservedObject var store: CopilotStore
    @ObservedObject var runner: CopilotRunner
    var chat: ClaudeChat
    var post: ClaudeChat
    let selected: Bool
    let open: () -> Void

    var body: some View {
        RailButton(icon: "text.bubble", title: "Comments", key: "⇧⌘M", selected: selected, action: open) {
            if runner.running || chat.running || post.running {
                ProgressView().controlSize(.mini)
            } else if !store.review.isEmpty {
                Text("\(store.review.count)").font(Theme.mono(10.5, .bold)).foregroundStyle(.white)
                    .padding(.horizontal, 4).frame(minWidth: 16, minHeight: 16)
                    .background(Theme.accent, in: Capsule())
            }
        }
        .onAppear { store.scan(app.library.root) }
        .onReceive(NotificationCenter.default.publisher(for: .cutmarkFilesChanged)) { n in
            if let paths = n.object as? [String], CopilotStore.matters(paths, root: app.library.root) {
                store.scanInBackground(app.library.root)
            }
        }
    }
}

// MARK: - Traffic lights

/// Moves the window's traffic lights to the middle of the top row, as Electron's
/// trafficLightPosition does. AppKit puts them back on resize and full screen, so it
/// places them again after each.
struct TrafficLights: NSViewRepresentable {
    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ nsView: Probe, context: Context) { nsView.place() }

    final class Probe: NSView {
        private var tokens: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            tokens.forEach(NotificationCenter.default.removeObserver)
            tokens = []
            guard let w = window else { return }
            let names: [Notification.Name] = [NSWindow.didResizeNotification, NSWindow.didEndLiveResizeNotification,
                                              NSWindow.didExitFullScreenNotification, NSWindow.didBecomeKeyNotification,
                                              NSWindow.didResignKeyNotification, NSWindow.didChangeScreenNotification]
            tokens = names.map {
                NotificationCenter.default.addObserver(forName: $0, object: w, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.place() }
                }
            }
            place()
            // Once more after SwiftUI's first layout, which can lay the title bar out again.
            DispatchQueue.main.async { [weak self] in self?.place() }
        }

        func place() {
            guard let w = window, !w.styleMask.contains(.fullScreen),
                  let close = w.standardWindowButton(.closeButton),
                  let mini = w.standardWindowButton(.miniaturizeButton),
                  let zoom = w.standardWindowButton(.zoomButton),
                  let bar = close.superview, let container = bar.superview else { return }
            let h = Chrome.bar
            var f = container.frame
            if f.height != h || f.maxY != w.frame.height {
                f.size.height = h
                f.origin.y = w.frame.height - h
                container.frame = f
            }
            if bar.frame != container.bounds { bar.frame = container.bounds }
            let gap: CGFloat = 20
            for (i, b) in [close, mini, zoom].enumerated() {
                let origin = NSPoint(x: Chrome.lightsX + CGFloat(i) * gap, y: ((bar.frame.height - b.frame.height) / 2).rounded())
                if b.frame.origin != origin { b.setFrameOrigin(origin) }
            }
        }

        deinit { tokens.forEach(NotificationCenter.default.removeObserver) }
    }
}
