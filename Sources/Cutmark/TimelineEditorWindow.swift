import AppKit
import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

/// Editing has its own wide workspace. The Record split and the script column are intentionally
/// absent: a filmstrip cannot be operated reliably in a 380 pt recorder stage.
@MainActor
final class TimelineEditorWindow: NSObject, NSWindowDelegate {
    static let shared = TimelineEditorWindow()
    private var windows: [URL: NSWindow] = [:]

    func open(video: URL, doc: SessionDoc, app: AppModel) {
        // Never leave the ReviewPlayer playing the original soundtrack behind the cut preview.
        app.player?.pause()
        let key = video.standardizedFileURL
        if let window = windows[key] {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 790),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "Edit — \(video.deletingPathExtension().lastPathComponent)"
        window.minSize = NSSize(width: 850, height: 560)
        window.center()
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier(key.absoluteString)
        window.delegate = self
        window.contentView = NSHostingView(rootView: TimelineEditorWorkspace(video: key, doc: doc)
            .environment(app))
        windows[key] = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if let key = windows.first(where: { $0.value === window })?.key { windows.removeValue(forKey: key) }
    }
}

@MainActor
final class TimelineEditorPlayback: ObservableObject {
    @Published private(set) var time = 0.0
    @Published private(set) var playing = false
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    let player = AVPlayer()
    private var observer: Any?

    init() {
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.08, preferredTimescale: 600),
                                                  queue: .main) { [weak self] point in
            // AVPlayer's callback is Sendable even when queue=.main; enter actor isolation
            // explicitly rather than mutating @Published UI state from that callback.
            Task { @MainActor [weak self] in
                guard let self, !self.loading else { return }
                if point.seconds.isFinite { self.time = max(0, point.seconds) }
                self.playing = self.player.rate != 0
            }
        }
    }

    func close() {
        if let observer { player.removeTimeObserver(observer) }
        observer = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
    }

    func load(draft: EditTimelineDraft, session: URL) async {
        loading = true
        error = nil
        let oldTime = time
        let wasPlaying = player.rate != 0
        // A new draft and the old player must never coexist in an interactable editor. Clearing
        // the item immediately also ensures a costly composition rebuild cannot keep old audio
        // running or expose a stale playhead for a subsequent split.
        player.pause()
        playing = false
        player.replaceCurrentItem(with: nil)
        do {
            let item = try await TimelinePlayback.playerItem(draft: draft, session: session)
            guard !Task.isCancelled else { return }
            player.replaceCurrentItem(with: item)
            let restored = min(max(0, oldTime), max(0, draft.duration - 1 / max(1, draft.fps)))
            await player.seek(to: CMTime(seconds: restored, preferredTimescale: 600),
                              toleranceBefore: .zero, toleranceAfter: .zero)
            time = restored
            if wasPlaying { player.play() }
        } catch {
            guard !Task.isCancelled else { return }
            player.pause()
            player.replaceCurrentItem(with: nil)
            self.error = error.localizedDescription
        }
        loading = false
    }

    func seek(_ seconds: Double, duration: Double) {
        guard !loading, player.currentItem != nil else { return }
        let time = max(0, min(duration, seconds))
        self.time = time
        player.seek(to: CMTime(seconds: time, preferredTimescale: 600), toleranceBefore: .zero,
                    toleranceAfter: .zero)
    }

    func toggle() {
        guard !loading, player.currentItem != nil else { return }
        if player.rate == 0 { player.play(); playing = true }
        else { player.pause(); playing = false }
    }

    func stop() { player.pause(); playing = false }
}

/// No false editing preview: the player is an AVMutableComposition built from the current draft,
/// and its time ruler, selection and cuts use the exact same output timeline clock.
private struct TimelineEditorWorkspace: View {
    @Environment(AppModel.self) private var app
    let video: URL
    let doc: SessionDoc
    @StateObject private var playback = TimelineEditorPlayback()
    @StateObject private var media = TimelineMediaCache()
    @State private var draft: EditTimelineDraft?
    @State private var selected = 0
    @State private var revision = 0
    @State private var pixelsPerSecond: Double = 72
    @State private var problem: String?

    private var duration: Double { draft?.duration ?? 0 }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                preview
                Divider()
                inspector.frame(width: 222)
            }
            .frame(maxHeight: .infinity)
            Divider()
            editor
        }
        .background(Theme.canvas)
        .frame(minWidth: 850, minHeight: 560)
        .task(id: video) { await restore() }
        .task(id: revision) {
            guard let draft else { return }
            // Rebuild on edits and undo, not continuously while dragging or playing.
            await playback.load(draft: draft, session: doc.url)
        }
        .task(id: revision) {
            guard let draft else { return }
            await media.load(draft: draft, session: doc.url)
        }
        .onDisappear { playback.close(); media.cancel() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "film.stack").foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 3) {
                Text("Timeline").font(Theme.sans(15, .semibold))
                Text(video.lastPathComponent).font(Theme.sans(11)).foregroundStyle(Theme.muted)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            if let draft {
                Text("\(draft.segments.count) clips  ·  \(SessionDoc.clock(draft.duration))")
                    .font(Theme.mono(12)).foregroundStyle(Theme.muted)
            }
            Button("Reset") { reset() }.disabled(draft?.actions.isEmpty ?? true)
                .buttonStyle(AccentButtonStyle(kind: .quiet))
            Button("Render edit") { render() }
                .disabled(draft == nil || (!((draft?.isRawTake) ?? false) && (draft?.actions.isEmpty ?? true)))
                .buttonStyle(AccentButtonStyle(kind: .solid))
        }
        .padding(.horizontal, 20).frame(height: 68)
    }

    private var preview: some View {
        VStack(spacing: 0) {
            GeometryReader { region in
                ZStack {
                    Color.black
                    PlayerLayerView(player: playback.player)
                        .frame(width: region.size.width, height: region.size.height)
                        .allowsHitTesting(false)
                    if playback.loading {
                        ProgressView("Preparing cut preview…")
                            .tint(.white).foregroundStyle(.white)
                    }
                    if let error = playback.error {
                        Text("Preview unavailable: \(error)")
                            .font(Theme.sans(12)).foregroundStyle(.white)
                            .multilineTextAlignment(.center).padding(20)
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack(spacing: 12) {
                Button { playback.seek(0, duration: duration) } label: {
                    Image(systemName: "backward.end.fill")
                }
                Button { playback.toggle() } label: {
                    Image(systemName: playback.playing ? "pause.fill" : "play.fill")
                        .frame(width: 24, height: 28)
                }
                Text("\(formatTime(playback.time)) / \(formatTime(duration))")
                    .font(Theme.mono(12)).monospacedDigit()
                Slider(value: Binding(get: { min(duration, playback.time) },
                                      set: { playback.seek($0, duration: duration) }),
                       in: 0...max(0.001, duration))
                    .accessibilityLabel("Playhead position")
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 20)
            .frame(height: 60)
            .foregroundStyle(Theme.ink)
            .background(Theme.paper)
        }
    }

    private var inspector: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("CLIP").font(Theme.sans(11, .semibold)).foregroundStyle(Theme.muted)
            if let draft, draft.segments.indices.contains(selected) {
                let segment = draft.segments[selected]
                Text("Take \(segment.take) · \(segment.kind.capitalized)")
                    .font(Theme.sans(14, .semibold))
                LabeledContent("Start", value: formatTime(segment.start))
                LabeledContent("End", value: formatTime(segment.end))
                LabeledContent("Length", value: formatTime(segment.duration))
                Divider()
                Text("Drag either clip edge to trim. Drag a clip over another to reorder.")
                    .font(Theme.sans(11)).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                if let warning = TimelinePlayback.limitation(draft: draft, session: doc.url) {
                    Divider()
                    Label(warning, systemImage: "info.circle")
                        .font(Theme.sans(11)).foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !draft.isRawTake && draft.segments.contains(where: { $0.kind == "screen" }) {
                    Button("Suggest auto-zoom") { suggestZooms(draft) }
                        .buttonStyle(AccentButtonStyle(kind: .quiet))
                        .help("Inspect possible zooms; do not apply or publish them")
                }
            } else {
                Text("Select a clip to edit it.").font(Theme.sans(12)).foregroundStyle(Theme.muted)
            }
            Spacer()
            if let problem {
                Text(problem).font(Theme.sans(11)).foregroundStyle(Theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let draft, !draft.actions.isEmpty {
                Text("Draft saved automatically. Source files are untouched.")
                    .font(Theme.sans(11)).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.paper)
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                toolbar("scissors", "Split") { split() }
                toolbar("arrow.left", "Earlier") { move(-1) }
                toolbar("arrow.right", "Later") { move(1) }
                toolbar("plus.square.on.square", "Duplicate") { apply(.init(op: "duplicate", index: selected)) }
                toolbar("trash", "Remove") { apply(.init(op: "remove", index: selected)) }
                toolbar("arrow.uturn.backward", "Undo") { undo() }
                Spacer(minLength: 0)
                Text("Zoom").font(Theme.sans(11)).foregroundStyle(Theme.muted)
                Slider(value: $pixelsPerSecond, in: 24...180).frame(width: 135)
                    .accessibilityLabel("Timeline zoom")
            }
            .padding(.horizontal, 18).frame(height: 48)
            .background(Theme.paper)
            Divider()
            if let draft {
                ScrollView(.horizontal) {
                    VStack(alignment: .leading, spacing: 0) {
                        ruler(draft)
                        ZStack(alignment: .topLeading) {
                            VStack(spacing: 0) {
                                HStack(spacing: 0) {
                                    ForEach(Array(draft.segments.enumerated()), id: \.offset) { index, clip in
                                        clipView(clip, index: index)
                                    }
                                }
                                .frame(height: 74)
                                HStack(spacing: 0) {
                                    ForEach(Array(draft.segments.enumerated()), id: \.offset) { index, clip in
                                        TimelineWaveformBar(amplitudes: media.waveform[index] ?? [],
                                                            tint: Theme.accent)
                                            .frame(width: width(for: clip), height: 46)
                                    }
                                }
                                .background(Theme.paper)
                                .frame(height: 46)
                            }
                            Rectangle().fill(Theme.danger).frame(width: 2, height: 120)
                                .offset(x: CGFloat(playback.time) * pixelsPerSecond)
                                .allowsHitTesting(false)
                        }
                    }
                    .frame(width: max(700, CGFloat(draft.duration * pixelsPerSecond)), alignment: .leading)
                }
                .scrollIndicators(.visible)
            } else {
                Text(problem ?? "Opening source video…")
                    .font(Theme.sans(12)).foregroundStyle(Theme.muted).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(height: 218)
    }

    private func ruler(_ draft: EditTimelineDraft) -> some View {
        Canvas { context, size in
            let step = pixelsPerSecond >= 60 ? 1.0 : pixelsPerSecond >= 35 ? 2.0 : 5.0
            let count = min(6000, Int((draft.duration / step).rounded(.up)))
            for n in 0...count {
                let seconds = Double(n) * step
                let x = CGFloat(seconds * pixelsPerSecond)
                var line = Path()
                line.move(to: CGPoint(x: x, y: 23))
                line.addLine(to: CGPoint(x: x, y: 32))
                context.stroke(line, with: .color(Theme.muted.opacity(0.8)), lineWidth: 0.7)
                let label = context.resolve(Text(formatTime(seconds)).font(Theme.mono(10)).foregroundStyle(Theme.muted))
                context.draw(label, at: CGPoint(x: x + 3, y: 9), anchor: .leading)
            }
        }
        .frame(height: 32)
        .background(Theme.canvas)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { move in
            playback.seek(Double(move.location.x) / pixelsPerSecond, duration: duration)
        })
        .help("Click or drag to move playhead")
    }

    private func clipView(_ segment: EditTimelineDraft.Segment, index: Int) -> some View {
        let envelope = draft?.trimBounds(index: index) ?? segment
        return TimelineFilmstripBar(segment: segment, number: index + 1,
                             width: width(for: segment), thumbs: media.thumbnails[index] ?? [],
                             selected: selected == index, envelope: envelope,
                             pixelsPerSecond: pixelsPerSecond, fps: draft?.fps ?? 30,
                             seek: { fraction in
                                guard let draft, let start = draft.outputStart(of: index) else { return }
                                selected = index
                                playback.seek(start + segment.duration * fraction, duration: draft.duration)
                             }, trim: { edge, delta in
                                guard let draft,
                                      let operation = draft.trimProposal(index: index, edge: edge,
                                                                         dragSeconds: Double(delta / pixelsPerSecond))
                                else { return }
                                selected = index
                                apply(operation)
                             }, reorder: { from in
                                guard let draft, draft.segments.indices.contains(from) else { return }
                                selected = index
                                apply(.init(op: "move", index: from, to: index))
                             })
    }

    private func width(for clip: EditTimelineDraft.Segment) -> CGFloat {
        max(1, CGFloat(clip.duration * pixelsPerSecond))
    }

    private func toolbar(_ symbol: String, _ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol).font(Theme.sans(11, .medium))
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.ink)
        .help(title)
    }

    private func restore() async {
        let duration = try? await AVURLAsset(url: video).load(.duration)
        guard !Task.isCancelled else { return }
        let raw = doc.meta.takes.first { $0.file == video.lastPathComponent }
            .flatMap { take -> EditTimelineDraft? in
                let seconds = duration?.seconds ?? take.duration ?? 0
                return EditTimelineDraft.fromTake(take, duration: seconds,
                                                   fps: take.kind == .screen ? Double(ScreenMovieWriter.frameRate) : 30)
            }
        draft = EditTimelineDraft.restore(video: video, session: doc.url, original: raw)
        if draft == nil {
            problem = "No usable timeline recipe was found for this video. Open a recorded take or a published Cutmark edit."
        } else {
            problem = nil
        }
        selected = 0
        revision += 1
    }

    private func apply(_ action: EditTimelineDraft.Action) {
        guard var next = draft, next.apply(action) else {
            problem = "Invalid edit. Each clip must keep at least two frames."
            return
        }
        do {
            try next.save(video: video, session: doc.url)
            draft = next
            selected = min(selected, next.segments.count - 1)
            problem = nil
            revision += 1
        } catch { problem = "Could not save the draft: \(error.localizedDescription)" }
    }

    private func split() {
        guard !playback.loading else { return }
        guard let draft, let source = draft.sourcePoint(atOutput: playback.time) else {
            problem = "Move the playhead inside a clip to split it."
            return
        }
        selected = source.index
        apply(.init(op: "split", index: source.index, at: source.source))
    }

    private func move(_ direction: Int) {
        guard let draft, draft.segments.indices.contains(selected),
              draft.segments.indices.contains(selected + direction) else { return }
        let target = selected + direction
        apply(.init(op: "move", index: selected, to: target))
        selected = target
    }

    private func undo() {
        guard var previous = draft, previous.undoLast() else { return }
        do {
            try previous.save(video: video, session: doc.url)
            draft = previous
            selected = min(selected, previous.segments.count - 1)
            problem = nil
            revision += 1
        } catch { problem = "Could not save undo: \(error.localizedDescription)" }
    }

    private func reset() {
        guard let draft else { return }
        let fresh = EditTimelineDraft(base: draft.base, fps: draft.fps, source: draft.source,
                                      segments: draft.source)
        EditTimelineDraft.clear(video: video, session: doc.url)
        self.draft = fresh
        selected = 0
        playback.seek(0, duration: fresh.duration)
        problem = nil
        revision += 1
    }

    private func render() {
        guard let draft else { return }
        let request: String
        if draft.isRawTake {
            guard let recipe = draft.initialRecipe(),
                  let data = try? JSONSerialization.data(withJSONObject: recipe, options: [.sortedKeys]),
                  let json = String(data: data, encoding: .utf8) else { return }
            request = "Render a new non-destructive Cutmark edit using render_edit with this exact recipe: \(json). "
                + "Inspect the output. Do not publish_edit until I review the result. Do not modify original takes."
        } else {
            guard let data = try? JSONEncoder().encode(draft.actions),
                  let actions = String(data: data, encoding: .utf8) else { return }
            request = "For the published edit \(draft.base), call plan_timeline_edit with base=\(draft.base) "
                + "and these ordered actions: \(actions). Then render_edit using returned arguments, inspect checks, "
                + "and do not publish_edit until I review. Original edits and takes must remain unchanged."
        }
        app.chats.chat(doc.url).send(request, title: doc.meta.title, onStage: video,
                                     shown: "Render visual timeline for review")
        app.chats.open = true
    }

    private func suggestZooms(_ draft: EditTimelineDraft) {
        app.chats.chat(doc.url).send(
            "Call cutmark suggest_auto_zooms for the published edit \(draft.base). This is a read-only "
            + "review: explain proposed regions and kept screen cuts; do not apply_auto_zooms, "
            + "render_edit or publish_edit without my approval.",
            title: doc.meta.title, onStage: video, shown: "Review suggested screen zooms")
        app.chats.open = true
    }

    private func formatTime(_ seconds: Double) -> String {
        let t = max(0, seconds.isFinite ? seconds : 0)
        return String(format: "%01d:%05.2f", Int(t / 60), t.truncatingRemainder(dividingBy: 60))
    }
}

/// The video lane shows actual source frames, not placeholder clip cards. Body-drag moves the
/// clip and the two edge grips trim it; both are disabled as accidental button taps.
private struct TimelineFilmstripBar: View {
    let segment: EditTimelineDraft.Segment
    let number: Int
    let width: CGFloat
    let thumbs: [TimelineThumbnail]
    let selected: Bool
    let envelope: EditTimelineDraft.Segment
    let pixelsPerSecond: Double
    let fps: Double
    let seek: (Double) -> Void
    let trim: (EditTimelineDraft.TrimEdge, CGFloat) -> Void
    let reorder: (Int) -> Void
    @State private var leadingDrag: CGFloat = 0
    @State private var trailingDrag: CGFloat = 0

    var body: some View {
        ZStack(alignment: .topLeading) {
            HStack(spacing: 0) {
                if thumbs.isEmpty {
                    Theme.surface.overlay {
                        Image(systemName: segment.kind == "screen" ? "display" : "video")
                            .font(.system(size: 14)).foregroundStyle(Theme.muted)
                    }
                } else {
                    ForEach(Array(thumbs.enumerated()), id: \.offset) { _, thumb in
                        Image(decorative: thumb.image, scale: 1)
                            .resizable().scaledToFill()
                            .frame(width: width / CGFloat(thumbs.count), height: 74)
                            .clipped()
                    }
                }
            }
            .frame(width: width, height: 74)
            .clipped()
            Text("\(number)")
                .font(Theme.mono(10, .semibold)).foregroundStyle(.white)
                .padding(4).background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 3))
                .padding(.leading, 9).padding(.top, 5)
                .allowsHitTesting(false)
        }
        .frame(width: width, height: 74)
        .overlay(alignment: .leading) {
            Rectangle().fill(.black.opacity(0.58)).frame(width: leadingDrag).allowsHitTesting(false)
        }
        .overlay(alignment: .trailing) {
            Rectangle().fill(.black.opacity(0.58)).frame(width: -trailingDrag).allowsHitTesting(false)
        }
        // Removed frames are always recoverable. Ghost previews show the region being added
        // before mouse-up, while the live player stays on the last committed composition.
        .overlay(alignment: .leading) {
            if leadingDrag < 0 {
                Rectangle().fill(Theme.accent.opacity(0.25))
                    .frame(width: -leadingDrag, height: 74).offset(x: leadingDrag)
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .trailing) {
            if trailingDrag > 0 {
                Rectangle().fill(Theme.accent.opacity(0.25))
                    .frame(width: trailingDrag, height: 74).offset(x: trailingDrag)
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .bottomLeading) {
            if leadingDrag != 0 || trailingDrag != 0 {
                Text(previewTimeLabel)
                    .font(Theme.mono(10, .semibold)).foregroundStyle(.white)
                    .padding(4).background(.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 3))
                    .padding(3).allowsHitTesting(false)
            }
        }
        .overlay(Rectangle().strokeBorder(selected ? Theme.accent : Theme.border,
                                        lineWidth: selected ? 2.5 : 1))
        .contentShape(Rectangle())
        .gesture(SpatialTapGesture().onEnded { event in
            seek(Double(min(1, max(0, event.location.x / max(1, width)))))
        })
        .draggable("cutmark-timeline-clip-\(number - 1)")
        .dropDestination(for: String.self) { ids, _ in
            guard let id = ids.first, id.hasPrefix("cutmark-timeline-clip-"),
                  let from = Int(id.dropFirst("cutmark-timeline-clip-".count)), from != number - 1
            else { return false }
            reorder(from)
            return true
        }
        .overlay(alignment: .leading) { handle(.start) }
        .overlay(alignment: .trailing) { handle(.end) }
        .help("Clip \(number) · drag edges to trim; drag the clip to reorder")
    }

    private func handle(_ edge: EditTimelineDraft.TrimEdge) -> some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(Theme.accent.opacity(0.95))
            .frame(width: 7, height: 50)
            .frame(width: min(18, width / 2), height: 74)
            .offset(x: edge == .start ? leadingDrag : trailingDrag)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 3)
                .onChanged { event in
                    // Live in/out feedback, without decoding video during the drag. The model
                    // snaps on release and the composition then refreshes exactly once.
                    // Reversible in either direction. A drag out and back to zero commits
                    // nothing. Later drags can re-extend up to this occurrence's source bounds.
                    let offset = EditTimelineDraft.trimPreviewOffset(edge: edge,
                        proposedPixels: Double(event.translation.width), segment: segment,
                        bounds: envelope, pixelsPerSecond: pixelsPerSecond, fps: fps)
                    if edge == .start { leadingDrag = CGFloat(offset) }
                    else { trailingDrag = CGFloat(offset) }
                }
                .onEnded { _ in
                    trim(edge, edge == .start ? leadingDrag : trailingDrag)
                    leadingDrag = 0
                    trailingDrag = 0
                })
            .help(edge == .start ? "Drag right to trim or left to recover clip start"
                                   : "Drag left to trim or right to recover clip end")
    }

    private var previewTimeLabel: String {
        let newStart = segment.start + Double(leadingDrag) / pixelsPerSecond
        let newEnd = segment.end + Double(trailingDrag) / pixelsPerSecond
        return String(format: "%.2f – %.2f s", newStart, newEnd)
    }
}

private struct TimelineWaveformBar: View {
    let amplitudes: [CGFloat]
    let tint: Color

    var body: some View {
        Canvas { context, size in
            guard !amplitudes.isEmpty else { return }
            let count = amplitudes.count
            let barWidth = max(1, size.width / CGFloat(count) * 0.68)
            for (i, amplitude) in amplitudes.enumerated() {
                let height = max(1.5, min(size.height - 3, amplitude * size.height))
                context.fill(Path(roundedRect: CGRect(x: CGFloat(i) * size.width / CGFloat(count),
                                                      y: (size.height - height) / 2,
                                                      width: barWidth, height: height), cornerRadius: 1),
                             with: .color(tint.opacity(0.75)))
            }
        }
        .background(tint.opacity(0.07))
        .overlay(Rectangle().strokeBorder(tint.opacity(0.2), lineWidth: 0.5))
        .accessibilityLabel("Audio waveform")
    }
}
