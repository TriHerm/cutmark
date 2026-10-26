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
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1080, height: 680),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "Edit — \(video.deletingPathExtension().lastPathComponent)"
        window.minSize = NSSize(width: 780, height: 520)
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
    private var seekGeneration = 0
    private var seekInFlight = false
    private var seekTask: Task<Void, Never>?

    init() {
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.08, preferredTimescale: 600),
                                                  queue: .main) { [weak self] _ in
            // AVPlayer's callback is Sendable even when queue=.main; enter actor isolation
            // explicitly rather than mutating @Published UI state from that callback. Never
            // publish the callback's captured point while an exact seek is still settling: that
            // point may predate the user's frame-step command by one observer interval.
            Task { @MainActor [weak self] in
                guard let self, !self.loading, !self.seekInFlight else { return }
                let current = self.player.currentTime().seconds
                if current.isFinite { self.time = max(0, current) }
                self.playing = self.player.rate != 0
            }
        }
    }

    func close() {
        seekGeneration += 1
        seekInFlight = false
        seekTask?.cancel()
        seekTask = nil
        if let observer { player.removeTimeObserver(observer) }
        observer = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
    }

    func load(draft: EditTimelineDraft, session: URL) async {
        seekGeneration += 1
        seekInFlight = false
        seekTask?.cancel()
        seekTask = nil
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
        let target = max(0, min(duration, seconds))
        seekGeneration += 1
        let generation = seekGeneration
        seekInFlight = true
        time = target
        seekTask?.cancel()
        seekTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.player.seek(to: CMTime(seconds: target, preferredTimescale: 600),
                                   toleranceBefore: .zero, toleranceAfter: .zero)
            guard !Task.isCancelled, self.seekGeneration == generation else { return }
            self.seekInFlight = false
            let current = self.player.currentTime().seconds
            if current.isFinite { self.time = max(0, min(duration, current)) }
            self.playing = self.player.rate != 0
            self.seekTask = nil
        }
    }

    func toggle() {
        guard !loading, player.currentItem != nil else { return }
        if player.rate == 0 { player.play(); playing = true }
        else { player.pause(); playing = false }
    }

    func stop() { player.pause(); playing = false }

    /// Editing commands use AVPlayer's clock at the moment of the key press. `time` is only an
    /// 80 ms UI snapshot and is intentionally not authoritative for split/step/shuttle actions.
    func commandTime(duration: Double, pause: Bool = false) async -> Double? {
        guard !loading, player.currentItem != nil else { return nil }
        // Scrubbing/frame stepping can leave an exact seek in flight. Wait for the latest seek to
        // settle before sampling the player clock; otherwise an immediate S/J/arrow command can
        // act on the position from before the user's scrub. If another seek supersedes it while
        // we await, loop once more and sample only after the latest generation has settled.
        while seekInFlight {
            let generation = seekGeneration
            let pending = seekTask
            await pending?.value
            guard !loading, player.currentItem != nil else { return nil }
            if generation == seekGeneration, !seekInFlight { break }
        }
        if pause {
            player.pause()
            playing = false
        }
        let sampled = player.currentTime().seconds
        guard sampled.isFinite else { return nil }
        let current = max(0, min(duration, sampled))
        time = current
        return current
    }

    func playForward() {
        guard !loading, player.currentItem != nil else { return }
        player.playImmediately(atRate: 1)
        playing = true
    }

    func shuttleBackward(duration: Double, fps: Double) async {
        guard !loading, let item = player.currentItem else { return }
        guard let current = await commandTime(duration: duration) else { return }
        if item.canPlayReverse, current > 0 {
            player.rate = -1
            playing = true
        } else {
            stop()
            seek(TimelineCanvasLayout.nudgedTime(current, frames: -max(1, Int(fps.rounded())),
                                                 fps: fps, outputDuration: duration),
                 duration: duration)
        }
    }

    func step(frames: Int, fps: Double, duration: Double) async {
        guard let current = await commandTime(duration: duration) else { return }
        stop()
        seek(TimelineCanvasLayout.nudgedTime(current, frames: frames, fps: fps,
                                             outputDuration: duration), duration: duration)
    }
}

/// No false editing preview: the player is an AVMutableComposition built from the current draft,
/// and its time ruler, selection and cuts use the exact same output timeline clock.
struct TimelineEditorWorkspace: View {
    @Environment(AppModel.self) private var app
    let video: URL
    let doc: SessionDoc
    @StateObject private var playback = TimelineEditorPlayback()
    @StateObject private var media = TimelineMediaCache()
    @StateObject private var markers = TimelineMarkerCache()
    @State private var draft: EditTimelineDraft?
    @State private var selected = 0
    @State private var revision = 0
    @State private var pixelsPerSecond: Double = TimelineCanvasLayout.defaultScale
    @State private var timelineViewportWidth: CGFloat = 900
    @State private var zoomToFit = true
    @State private var problem: String?
    @State private var renderJob: String?
    @State private var renderedRevision: Int?
    @State private var rendering = false
    @State private var history = TimelineUndoHistory()
    @State private var more = false
    @State private var changes = false
    @State private var review: Job?
    @State private var playheadDragStart: Double?
    @FocusState private var keyboardFocus: Bool

    private var duration: Double { draft?.duration ?? 0 }
    private var currentRenderIsLive: Bool {
        guard let renderJob else { return false }
        return app.jobs.bySession[doc.url.standardizedFileURL]?.contains { $0.id == renderJob && $0.status.live } == true
    }

    var body: some View {
        GeometryReader { window in
            VStack(spacing: 0) {
                header
                Divider()
                preview
                clipContext
                renderStatus
                Divider()
                editor.frame(height: TimelineCanvasLayout.editorHeight(windowHeight: window.size.height))
            }
        }
        .background(Theme.canvas)
        .frame(minWidth: 780, minHeight: 520)
        .focusable()
        .focusEffectDisabled()
        .focused($keyboardFocus)
        // The hosting view is installed before its NSWindow becomes key; request focus on the next
        // main-actor turn so Space/S/J/K/L belong to this editor window as soon as it opens.
        .onAppear { Task { @MainActor in keyboardFocus = true } }
        .onKeyPress(.space, phases: .down) { press in
            guard plainTransportKey(press.modifiers) else { return .ignored }
            playback.toggle(); return .handled
        }
        .onKeyPress(.leftArrow, phases: .down) { press in
            guard plainTransportKey(press.modifiers) else { return .ignored }
            Task { await stepFrame(-1) }; return .handled
        }
        .onKeyPress(.rightArrow, phases: .down) { press in
            guard plainTransportKey(press.modifiers) else { return .ignored }
            Task { await stepFrame(1) }; return .handled
        }
        .onKeyPress(.home, phases: .down) { press in
            guard plainTransportKey(press.modifiers) else { return .ignored }
            playback.seek(0, duration: duration); return .handled
        }
        .onKeyPress(.end, phases: .down) { press in
            guard plainTransportKey(press.modifiers) else { return .ignored }
            playback.seek(duration, duration: duration); return .handled
        }
        .onKeyPress("s", phases: .down) { press in
            guard !press.modifiers.contains(.command), !press.modifiers.contains(.control),
                  !press.modifiers.contains(.option) else { return .ignored }
            Task { await split() }; return .handled
        }
        .onKeyPress("j", phases: .down) { press in
            guard !press.modifiers.contains(.command), !press.modifiers.contains(.control),
                  !press.modifiers.contains(.option) else { return .ignored }
            Task { await shuttleBackward() }; return .handled
        }
        .onKeyPress("k", phases: .down) { press in
            guard !press.modifiers.contains(.command), !press.modifiers.contains(.control),
                  !press.modifiers.contains(.option) else { return .ignored }
            playback.stop(); return .handled
        }
        .onKeyPress("l", phases: .down) { press in
            guard !press.modifiers.contains(.command), !press.modifiers.contains(.control),
                  !press.modifiers.contains(.option) else { return .ignored }
            playback.playForward(); return .handled
        }
        .onKeyPress(characters: ["=", "-", "z", "e"], phases: .down) { press in
            guard press.modifiers.contains(.command) else { return .ignored }
            switch press.characters {
            case "=": adjustZoom(1.18)
            case "-": adjustZoom(1 / 1.18)
            case "z": if press.modifiers.contains(.shift) { redo() } else { undo() }
            case "e": render()
            default: return .ignored
            }
            return .handled
        }
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
        .task(id: revision) {
            guard let draft else { return }
            await markers.load(draft: draft, session: doc.url)
        }
        .onChange(of: duration) { _, _ in if zoomToFit { fitTimeline() } }
        .onDisappear { playback.close(); media.cancel(); markers.clear() }
        .sheet(item: $review) { job in TimelineResultReview(job: job).environment(app) }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "film.stack").foregroundStyle(Theme.accent)
            Text(video.deletingPathExtension().lastPathComponent)
                .font(Theme.sans(13, .semibold)).lineLimit(1).truncationMode(.middle)
            // Smoke builds use a distinct bundle ID; surface their actual CI checkout stamp so
            // a retained editor window from an older test cannot be mistaken for this candidate.
            if Bundle.main.bundleIdentifier?.contains(".smoke.") == true,
               let stamp = Bundle.main.infoDictionary?["BuildStamp"] as? String {
                Text("SMOKE · \(stamp.prefix(7))")
                    .font(Theme.mono(10)).foregroundStyle(Theme.muted)
                    .help("This is a separate test build, not the installed Cutmark.app")
            }
            Spacer()
            if let draft {
                Text("\(draft.segments.count) section\(draft.segments.count == 1 ? "" : "s") · \(SessionDoc.clock(draft.duration))")
                    .font(Theme.mono(11)).foregroundStyle(Theme.muted)
            }
            Button { changes = true } label: {
                Label("Changes", systemImage: "clock.arrow.circlepath")
            }
            .buttonStyle(AccentButtonStyle(kind: .quiet))
            .cutmarkPopover(isPresented: $changes) { changeList }
            Button(rendering ? "Preparing…" : "Create video") { render() }
                .disabled(rendering || currentRenderIsLive || draft == nil || (!((draft?.isRawTake) ?? false) && (draft?.actions.isEmpty ?? true)))
                .buttonStyle(AccentButtonStyle(kind: .solid))
        }
        .padding(.horizontal, 14).frame(height: 50)
    }

    private var preview: some View {
        VStack(spacing: 0) {
            if let draft, TimelinePlayback.limitation(draft: draft, session: doc.url) != nil {
                Text("This preview shows your cuts. Effects and framing appear in the created video.")
                    .font(Theme.sans(11)).foregroundStyle(Theme.muted).padding(.top, 8)
            }
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
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack(spacing: 10) {
                Button { playback.seek(0, duration: duration) } label: {
                    Image(systemName: "backward.end.fill")
                }
                Button { playback.seek(max(0, playback.time - 1), duration: duration) } label: {
                    Image(systemName: "gobackward.1")
                }
                Button { playback.toggle() } label: {
                    Image(systemName: playback.playing ? "pause.fill" : "play.fill")
                        .frame(width: 22, height: 24)
                }
                Button { playback.seek(min(duration, playback.time + 1), duration: duration) } label: {
                    Image(systemName: "goforward.1")
                }
                Text("\(formatTime(playback.time)) / \(formatTime(duration))")
                    .font(Theme.mono(11)).monospacedDigit()
                Slider(value: Binding(get: { min(duration, playback.time) },
                                      set: { playback.seek($0, duration: duration) }),
                       in: 0...max(0.001, duration))
                    .accessibilityLabel("Playhead position")
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 14)
            .frame(height: 44)
            .foregroundStyle(Theme.ink)
            .background(Theme.paper)
        }
    }

    private var clipContext: some View {
        HStack(spacing: 12) {
            if let draft, draft.segments.indices.contains(selected) {
                let segment = draft.segments[selected]
                Label("Section \(selected + 1)", systemImage: segment.kind == "screen" ? "display" : "video")
                    .font(Theme.sans(11, .semibold))
                Text("Take \(segment.take)").font(Theme.sans(11)).foregroundStyle(Theme.muted)
                Text("\(formatTime(segment.start))–\(formatTime(segment.end))")
                    .font(Theme.mono(10.5)).foregroundStyle(Theme.muted)
                Text("\(formatTime(segment.duration))")
                    .font(Theme.mono(10.5, .semibold)).foregroundStyle(Theme.ink)
                if let warning = TimelinePlayback.limitation(draft: draft, session: doc.url) {
                    Image(systemName: "info.circle").foregroundStyle(Theme.muted).help(warning)
                }
                Spacer(minLength: 8)
                if !draft.isRawTake && draft.segments.contains(where: { $0.kind == "screen" }) {
                    Button { suggestZooms(draft) } label: {
                        Label("Auto zoom", systemImage: "scope").font(Theme.sans(10.5, .medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.muted)
                    .help("Inspect possible zooms; do not apply or publish them")
                }
                if !draft.actions.isEmpty {
                    Label("Saved", systemImage: "checkmark.circle")
                        .font(Theme.sans(10.5)).foregroundStyle(Theme.muted)
                        .help("Draft saved automatically. Source files are untouched.")
                }
            } else {
                Text("Select a clip to edit it.").font(Theme.sans(11)).foregroundStyle(Theme.muted)
                Spacer()
            }
            if let problem {
                Text(problem).font(Theme.sans(10.5)).foregroundStyle(Theme.danger).lineLimit(1)
                    .help(problem)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 34)
        .background(Theme.paper)
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                editorTool("scissors", "Split") { Task { await split() } }
                    .help("Split at the red playhead · S")
                editorTool("minus.circle", "Remove") { apply(.init(op: "remove", index: selected)) }
                    .disabled((draft?.segments.count ?? 0) < 2)
                    .help("Remove the selected section. Undo brings it back.")
                Divider().frame(height: 18)
                editorTool("arrow.uturn.backward", "Undo") { undo() }
                    .disabled(draft?.actions.isEmpty ?? true)
                editorTool("arrow.uturn.forward", "Redo") { redo() }
                    .disabled(history.redoActions.isEmpty)
                Button { more = true } label: { Label("More", systemImage: "ellipsis") }
                    .buttonStyle(.plain).font(Theme.sans(11))
                    .cutmarkPopover(isPresented: $more) {
                        VStack(alignment: .leading, spacing: 12) {
                            Button("Move section earlier") { move(-1); more = false }.disabled(selected == 0)
                            Button("Move section later") { move(1); more = false }
                                .disabled(selected >= (draft?.segments.count ?? 0) - 1)
                            Button("Duplicate section") { apply(.init(op: "duplicate", index: selected)); more = false }
                            Text("Space to play · S to split · ⌘Z to undo")
                                .font(Theme.sans(10)).foregroundStyle(Theme.muted)
                        }.buttonStyle(.plain).font(Theme.sans(12)).padding(16)
                    }
                Spacer(minLength: 4)
                Button("Fit") { fitTimeline() }
                    .buttonStyle(.plain)
                    .font(Theme.sans(10.5, .semibold))
                    .foregroundStyle(zoomToFit ? Theme.accent : Theme.muted)
                    .help("Fit the complete output in the visible timeline")
                Image(systemName: "minus.magnifyingglass").font(.system(size: 10)).foregroundStyle(Theme.muted)
                Slider(value: Binding(get: {
                    TimelineCanvasLayout.zoomSliderValue(pixelsPerSecond: pixelsPerSecond)
                }, set: { value in
                    zoomToFit = false
                    pixelsPerSecond = TimelineCanvasLayout.pixelsPerSecond(zoomSliderValue: value)
                }), in: 0...1)
                    .frame(width: 108)
                    .accessibilityLabel("Timeline zoom")
                Image(systemName: "plus.magnifyingglass").font(.system(size: 10)).foregroundStyle(Theme.muted)
            }
            .padding(.horizontal, 12).frame(height: 40)
            .background(Theme.paper)
            Text("Drag the ends to trim. Move the red line to Split, then select a section to Remove.")
                .font(Theme.sans(11)).foregroundStyle(Theme.muted)
                .padding(.horizontal, 14).padding(.vertical, 7)
            Divider()
            if let draft {
                GeometryReader { viewport in
                    let canvasWidth = TimelineCanvasLayout.width(
                        outputDuration: draft.duration, pixelsPerSecond: pixelsPerSecond,
                        viewportWidth: viewport.size.width)
                    let tracksHeight = max(
                        TimelineCanvasLayout.filmstripHeight + TimelineCanvasLayout.waveformHeight,
                        viewport.size.height - TimelineCanvasLayout.rulerHeight)
                    ScrollView(.horizontal) {
                        VStack(alignment: .leading, spacing: 0) {
                            ruler
                            ZStack(alignment: .topLeading) {
                                VStack(spacing: 0) {
                                    HStack(spacing: 0) {
                                        ForEach(Array(draft.segments.enumerated()), id: \.offset) { index, clip in
                                            clipView(clip, index: index)
                                        }
                                        // Only the free tail gets this gesture. Clip bodies still
                                        // receive selection/reorder; edge grips still receive trim.
                                        Rectangle().fill(Theme.surface.opacity(0.5))
                                            .contentShape(Rectangle())
                                            .frame(maxWidth: .infinity)
                                            .gesture(DragGesture(minimumDistance: 0).onChanged { event in
                                                let clipPixels = CGFloat(draft.duration * pixelsPerSecond)
                                                scrubTimeline(at: clipPixels + event.location.x)
                                            })
                                    }
                                    .frame(height: TimelineCanvasLayout.filmstripHeight)
                                    HStack(spacing: 0) {
                                        ForEach(Array(draft.segments.enumerated()), id: \.offset) { index, clip in
                                            TimelineWaveformBar(amplitudes: media.waveform[index] ?? [],
                                                                tint: Theme.accent)
                                                .frame(width: width(for: clip),
                                                       height: TimelineCanvasLayout.waveformHeight)
                                        }
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .frame(height: TimelineCanvasLayout.waveformHeight)
                                    .background(Theme.paper)
                                    .contentShape(Rectangle())
                                    .gesture(DragGesture(minimumDistance: 0).onChanged { event in
                                        scrubTimeline(at: event.location.x)
                                    })
                                    .help("Click or drag the audio lane to move the playhead")
                                    Rectangle()
                                        .fill(Theme.canvas)
                                        .contentShape(Rectangle())
                                        .frame(height: max(0, tracksHeight - TimelineCanvasLayout.filmstripHeight
                                                                - TimelineCanvasLayout.waveformHeight))
                                        .gesture(DragGesture(minimumDistance: 0).onChanged { event in
                                            scrubTimeline(at: event.location.x)
                                        })
                                        .help("Drag in the empty workspace to scrub the recording")
                                }
                                .frame(height: tracksHeight, alignment: .top)
                                // This boundary marks the render end; the remainder is only
                                // empty workspace for scrolling/zooming, never exported media.
                                Rectangle().fill(Theme.muted.opacity(0.65))
                                    .frame(width: 1, height: tracksHeight)
                                    .offset(x: CGFloat(draft.duration * pixelsPerSecond))
                                    .allowsHitTesting(false)
                                Text("End of output")
                                    .font(Theme.sans(10, .medium))
                                    .foregroundStyle(Theme.muted)
                                    .offset(x: CGFloat(draft.duration * pixelsPerSecond) + 9,
                                            y: TimelineCanvasLayout.filmstripHeight + 6)
                                    .allowsHitTesting(false)
                                // A bright full-height cursor stays visible above the media,
                                // including at time zero; trim handles remain independently hit-testable.
                                Rectangle().fill(Theme.danger)
                                    .frame(width: 2.5, height: tracksHeight)
                                    .offset(x: CGFloat(playback.time * pixelsPerSecond))
                                    .shadow(color: Theme.danger.opacity(0.5), radius: 2)
                                    .allowsHitTesting(false)
                            }
                            .frame(height: tracksHeight, alignment: .top)
                        }
                        .frame(width: canvasWidth, alignment: .leading)
                        // Use stable content coordinates while the handle repositions itself
                        // after every AVPlayer seek; view-local coordinates would jump.
                        .coordinateSpace(name: "cutmark-timeline")
                        .overlay(alignment: .topLeading) {
                            // Only the ruler receives the wide grab target. Clip trim handles
                            // below remain independently hit-testable.
                            playheadGrabber
                        }
                    }
                    .scrollIndicators(.visible)
                    .onAppear { updateTimelineViewport(viewport.size.width) }
                    .onChange(of: viewport.size.width) { _, width in updateTimelineViewport(width) }
                }
            } else {
                Text(problem ?? "Opening source video…")
                    .font(Theme.sans(12)).foregroundStyle(Theme.muted).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var ruler: some View {
        TimelineMarkerRuler(pins: markers.pins, pixelsPerSecond: pixelsPerSecond,
                            duration: duration, onSeek: { pin in
            playback.stop()
            selected = pin.index
            // A marker is already on the renderer's source clock. Preserve its exact timestamp,
            // even when draft.fps differs from the first source's output frame rate.
            playback.seek(pin.outputTime, duration: duration)
        }, onScrub: { scrubTimeline(at: $0) })
    }

    /// The red handle is deliberately wider than the 2px cursor, so it can be grabbed at
    /// any zoom level. Its position is taken from AVPlayer (via the active scrub's target),
    /// not from any clip/source timestamp after a trim or reorder.
    private var playheadGrabber: some View {
        let x = CGFloat(playback.time * pixelsPerSecond)
        return ZStack {
            RoundedRectangle(cornerRadius: 3)
                .fill(Theme.danger)
                .frame(width: 21, height: 23)
                .overlay {
                    Image(systemName: "arrow.left.and.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                }
        }
        .frame(width: 34, height: TimelineCanvasLayout.rulerHeight)
        .contentShape(Rectangle())
        .offset(x: max(0, x - 17), y: 0)
        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("cutmark-timeline"))
            .onChanged { gesture in
                if playheadDragStart == nil {
                    playheadDragStart = playback.time
                    playback.stop()
                }
                let target = TimelineCanvasLayout.draggedPlayheadTime(
                    start: playheadDragStart ?? playback.time,
                    translation: gesture.translation.width,
                    pixelsPerSecond: pixelsPerSecond, outputDuration: duration)
                seekAndSelect(target)
            }
            .onEnded { gesture in
                let target = TimelineCanvasLayout.draggedPlayheadTime(
                    start: playheadDragStart ?? playback.time,
                    translation: gesture.translation.width,
                    pixelsPerSecond: pixelsPerSecond, outputDuration: duration)
                playheadDragStart = nil
                seekAndSelect(target)
            })
        .accessibilityLabel("Timeline playhead")
        .help("Drag the red handle left or right to scrub the recording")
    }

    private func scrubTimeline(at x: CGFloat) {
        playback.stop()
        seekAndSelect(TimelineCanvasLayout.seekTime(
            at: x, pixelsPerSecond: pixelsPerSecond, outputDuration: duration))
    }

    private func seekAndSelect(_ time: Double) {
        let snapped = TimelineCanvasLayout.snappedTime(
            time, fps: draft?.fps ?? 30, outputDuration: duration)
        if let draft, let index = TimelineCanvasLayout.clipIndex(
            at: snapped, durations: draft.segments.map(\.duration)) {
            selected = index
        }
        playback.seek(snapped, duration: duration)
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
                                playback.stop()
                                seekAndSelect(start + segment.duration * fraction)
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
        // Never pad individual clips: summed visual width must stay on the exact output clock.
        // Tiny clips can become sub-pixel at Fit and are made editable by zooming in.
        CGFloat(max(0, clip.duration * pixelsPerSecond))
    }

    private func editorTool(_ symbol: String, _ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol).font(Theme.sans(11, .medium)).frame(height: 28)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.ink)
        .help(title)
    }

    private func restore() async {
        let asset = AVURLAsset(url: video)
        let duration = try? await asset.load(.duration)
        let videoTrack = try? await asset.loadTracks(withMediaType: .video).first
        let sourceRate: Double?
        if let videoTrack,
           let clock = try? await videoTrack.load(.nominalFrameRate, .minFrameDuration) {
            sourceRate = EditTimelineDraft.rendererFPS(
                nominalFrameRate: Double(clock.0), minFrameDuration: clock.1)
        } else {
            sourceRate = nil
        }
        guard !Task.isCancelled else { return }
        let raw = doc.meta.takes.first { $0.file == video.lastPathComponent }
            .flatMap { take -> EditTimelineDraft? in
                let seconds = duration?.seconds ?? take.duration ?? 0
                return EditTimelineDraft.fromTake(take, duration: seconds,
                                                   fps: take.kind == .screen ? Double(ScreenMovieWriter.frameRate) : 30,
                                                   sourceFPS: sourceRate)
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
        var nextHistory = history
        guard var next = draft, nextHistory.apply(action, to: &next) else {
            problem = "Invalid edit. Each clip must keep at least two frames."
            return
        }
        do {
            try next.save(video: video, session: doc.url)
            draft = next
            history = nextHistory
            selected = min(selected, next.segments.count - 1)
            problem = nil
            revision += 1
        } catch { problem = "Could not save the draft: \(error.localizedDescription)" }
    }

    private func split() async {
        guard let draft else { return }
        let capturedRevision = revision
        guard let commandTime = await playback.commandTime(duration: draft.duration, pause: true) else {
            problem = "Move the playhead inside a clip to split it."
            return
        }
        // Waiting for the latest precise seek yields the main actor. Another trim/reorder/undo
        // can replace the draft during that wait; never apply a cut indexed into a stale draft.
        guard revision == capturedRevision else { return }
        guard let source = draft.sourcePoint(atOutput: commandTime) else {
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

    private func stepFrame(_ frames: Int) async {
        let fps = draft?.fps ?? 30
        await playback.step(frames: frames, fps: fps, duration: duration)
    }

    private func plainTransportKey(_ modifiers: EventModifiers) -> Bool {
        !modifiers.contains(.command) && !modifiers.contains(.control) && !modifiers.contains(.option)
    }

    private func shuttleBackward() async {
        await playback.shuttleBackward(duration: duration, fps: draft?.fps ?? 30)
    }

    private func updateTimelineViewport(_ width: CGFloat) {
        guard width.isFinite, width > 0 else { return }
        timelineViewportWidth = width
        if zoomToFit { pixelsPerSecond = TimelineCanvasLayout.fitPixelsPerSecond(outputDuration: duration,
                                                                                 viewportWidth: width) }
    }

    private func fitTimeline() {
        zoomToFit = true
        pixelsPerSecond = TimelineCanvasLayout.fitPixelsPerSecond(outputDuration: duration,
                                                                  viewportWidth: timelineViewportWidth)
    }

    private func adjustZoom(_ factor: Double) {
        guard factor.isFinite, factor > 0 else { return }
        zoomToFit = false
        pixelsPerSecond = min(TimelineCanvasLayout.maximumScale,
                              max(TimelineCanvasLayout.minimumScale, pixelsPerSecond * factor))
    }

    private func undo() { changeHistory(redo: false) }
    private func redo() { changeHistory(redo: true) }

    private func changeHistory(redo: Bool) {
        guard var next = draft else { return }
        var nextHistory = history
        guard redo ? nextHistory.redo(&next) : nextHistory.undo(&next) else { return }
        do {
            try next.save(video: video, session: doc.url)
            draft = next; history = nextHistory
            selected = min(selected, next.segments.count - 1)
            problem = nil
            revision += 1
        } catch { problem = "Could not save this change: \(error.localizedDescription)" }
    }

    private var changeList: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Your changes").font(Theme.sans(14, .semibold))
            Text("The original recording stays saved. Undo restores the last change, including removed sections.")
                .font(Theme.sans(12)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            if let draft, !draft.actions.isEmpty {
                ForEach(Array(draft.actions.suffix(6).enumerated()), id: \.offset) { _, action in
                    Label(TimelineUndoHistory.title(action), systemImage: "checkmark").font(Theme.sans(12))
                }
                Button("Undo last change") { undo() }.buttonStyle(AccentButtonStyle(kind: .quiet))
            } else {
                Text("Drag a section’s ends to trim. Move the red line and choose Split, then Remove a section you don’t need.")
                    .font(Theme.sans(12)).fixedSize(horizontal: false, vertical: true)
            }
        }.padding(18).frame(width: 300)
    }

    @ViewBuilder private var renderStatus: some View {
        if let renderJob {
            if let job = app.jobs.bySession[doc.url.standardizedFileURL]?.first(where: { $0.id == renderJob }) {
                HStack(spacing: 10) {
                    if job.status.live { ProgressView().controlSize(.small) }
                    Text((renderedRevision == revision ? "" : "Earlier cut · ") + SessionJourney.jobTitle(job)).font(Theme.sans(12, .medium)).lineLimit(1)
                    Spacer()
                    if job.status == .done {
                        Button("Review video") { playback.stop(); review = job }
                            .buttonStyle(AccentButtonStyle(kind: .solid))
                    } else if !job.status.live {
                        Button("Try again") { render() }.buttonStyle(AccentButtonStyle(kind: .quiet))
                    }
                }.padding(.horizontal, 14).padding(.vertical, 8).background(Theme.paper)
            } else {
                Text("Preparing your video… You can keep editing while it runs.")
                    .font(Theme.sans(12)).padding(10)
            }
        }
    }

    private func render() {
        guard let draft, !rendering else { return }
        rendering = true
        renderedRevision = revision
        renderJob = nil
        problem = nil
        Task {
            defer { rendering = false }
            do {
                renderJob = try await TimelineRender.start(draft: draft, session: doc.url)
                app.jobs.reload(doc.url)
            } catch {
                problem = error.localizedDescription
            }
        }
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
                            .frame(width: width / CGFloat(thumbs.count),
                                   height: TimelineCanvasLayout.filmstripHeight)
                            .clipped()
                    }
                }
            }
            .frame(width: width, height: TimelineCanvasLayout.filmstripHeight)
            .clipped()
            Text("\(number)")
                .font(Theme.mono(10, .semibold)).foregroundStyle(.white)
                .padding(4).background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 3))
                .padding(.leading, 9).padding(.top, 5)
                .allowsHitTesting(false)
        }
        .frame(width: width, height: TimelineCanvasLayout.filmstripHeight)
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
                    .frame(width: -leadingDrag, height: TimelineCanvasLayout.filmstripHeight)
                    .offset(x: leadingDrag)
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .trailing) {
            if trailingDrag > 0 {
                Rectangle().fill(Theme.accent.opacity(0.25))
                    .frame(width: trailingDrag, height: TimelineCanvasLayout.filmstripHeight)
                    .offset(x: trailingDrag)
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
            .frame(width: 7, height: TimelineCanvasLayout.filmstripHeight - 24)
            .frame(width: min(18, width / 2), height: TimelineCanvasLayout.filmstripHeight)
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
