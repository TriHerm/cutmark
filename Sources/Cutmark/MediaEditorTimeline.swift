import SwiftUI
import AppKit

struct MediaEditorTimeline: View {
    @ObservedObject var store: MediaEditorStore
    @Binding var scale: Double
    @Binding var fit: Bool
    @Binding var snapping: Bool
    var reviewRange: StudioCut?
    @State private var viewport: CGFloat = 800
    @FocusState private var focused: Bool
    private let labelWidth: CGFloat = 90
    private var audio: [MediaEditProject.Clip] { store.project.clips.filter { $0.lane == .audio } }
    private var overlays: [MediaEditProject.Clip] { store.project.timelineClips.filter { $0.lane == .overlay } }
    private let emptyTrackHeight: CGFloat = 34
    private var width: CGFloat { max(viewport, CGFloat(max(store.project.duration, 5) * scale) + 90) }
    static func clock(_ time: Double) -> String {
        let t = max(0, time.isFinite ? time : 0)
        return String(format: "%d:%05.2f", Int(t) / 60, t.truncatingRemainder(dividingBy: 60))
    }
    var body: some View {
        VStack(spacing: 0) {
            toolbar
            GeometryReader { geometry in
                ScrollView(.vertical) {
                    HStack(alignment: .top, spacing: 0) {
                        labels.frame(width: labelWidth)
                        ScrollView(.horizontal) {
                            VStack(spacing: 0) {
                                ruler
                                lane(.video, clips: store.project.clips.filter { $0.lane == .video }, height: 82)
                                if overlays.isEmpty { lane(.overlay, clips: [], height: emptyTrackHeight) }
                                else { ForEach(overlays) { lane(.overlay, clips: [$0], height: 56) } }
                                if audio.isEmpty { lane(.audio, clips: [], height: emptyTrackHeight) }
                                else { ForEach(audio) { lane(.audio, clips: [$0], height: 58) } }
                            }
                            .frame(width: width, alignment: .leading)
                            .overlay(alignment: .topLeading) {
                                if let range = reviewRange {
                                    Rectangle()
                                        .fill(Theme.warn.opacity(0.16))
                                        .overlay(alignment: .leading) { Rectangle().fill(Theme.warn).frame(width: 1) }
                                        .overlay(alignment: .trailing) { Rectangle().fill(Theme.warn).frame(width: 1) }
                                        .frame(width: max(1, (range.end - range.start) * scale))
                                        .offset(x: range.start * scale)
                                        .allowsHitTesting(false)
                                }
                            }
                            .overlay(alignment: .topLeading) {
                                VStack(spacing: 0) {
                                    Image(systemName: "arrowtriangle.down.fill").font(.system(size: 11)).foregroundStyle(Theme.danger)
                                    Rectangle().fill(Theme.danger).frame(width: 1.5)
                                }.frame(width: 16).offset(x: CGFloat(store.time * scale) - 8)
                                    .allowsHitTesting(false)
                            }
                        }
                        .onAppear { viewport = max(100, geometry.size.width - labelWidth); if fit { fitScale() } }
                        .onChange(of: geometry.size.width) { _, w in viewport = max(100, w - labelWidth); if fit { fitScale() } }
                    }
                }
            }
            HStack {
                Text("Click the ruler to move the playhead · Space to play · S to split")
                    .font(Theme.sans(10)).foregroundStyle(Theme.muted).lineLimit(1)
                Spacer()
                let count = store.project.timelineClips.count
                Text("\(count) \(count == 1 ? "clip" : "clips") · \(Self.clock(store.project.duration))").font(Theme.mono(10)).foregroundStyle(Theme.muted)
            }.padding(.horizontal, 12).frame(height: 24).background(Theme.paper)
        }
        .background(Theme.canvas)
        .focusable().focused($focused)
        .simultaneousGesture(TapGesture().onEnded { focused = true })
        .onKeyPress(.space) { guard focused else { return .ignored }; store.toggle(); return .handled }
        .onKeyPress("s") { guard focused, store.canCutAtPlayhead else { return .ignored }; store.split(); return .handled }
        .onKeyPress(.delete) { guard focused, store.editable else { return .ignored }; store.remove(); return .handled }
        .onKeyPress(.leftArrow) { guard focused else { return .ignored }; store.seek(store.time - 1 / 30); return .handled }
        .onKeyPress(.rightArrow) { guard focused else { return .ignored }; store.seek(store.time + 1 / 30); return .handled }
        .onKeyPress(characters: ["z", "Z"], phases: .down) { event in
            guard focused, event.modifiers.contains(.command) else { return .ignored }
            store.undo(redo: event.modifiers.contains(.shift)); return .handled
        }
        .onChange(of: store.project.duration) { if fit { fitScale() } }
    }
    private var toolbar: some View {
        ViewThatFits(in: .horizontal) {
            toolbarItems(compact: false)
            toolbarItems(compact: true)
        }
        .buttonStyle(.plain).font(Theme.sans(12, .medium))
        .padding(.horizontal, 14).frame(height: 38).background(Theme.paper)
    }
    private func toolbarItems(compact: Bool) -> some View {
        HStack(spacing: compact ? 9 : 14) {
            Button { store.split() } label: { toolbarLabel("Split", icon: "scissors", compact: compact) }
                .disabled(!store.canCutAtPlayhead).help("Split at the playhead (S)").accessibilityLabel("Split")
            CutmarkMenuButton(help: "Trim at the playhead") {
                toolbarLabel("Trim", icon: "crop", compact: compact)
            } content: {
                MenuButton("Trim start to playhead", icon: "arrow.right.to.line") { store.trimToPlayhead(start: true) }
                MenuButton("Trim end to playhead", icon: "arrow.left.to.line") { store.trimToPlayhead(start: false) }
            }.disabled(!store.canCutAtPlayhead).accessibilityLabel("Trim")
            Button { store.remove() } label: { toolbarLabel("Delete", icon: "trash", compact: compact) }
                .disabled(store.selected == nil || !store.editable).help("Delete the selected clip").accessibilityLabel("Delete clip")
            Divider().frame(height: 18)
            Button { store.undo() } label: { Image(systemName: "arrow.uturn.backward") }.disabled(store.history.isEmpty || !store.editable).help("Undo · ⌘Z")
            Button { store.undo(redo: true) } label: { Image(systemName: "arrow.uturn.forward") }.disabled(store.future.isEmpty || !store.editable).help("Redo · ⇧⌘Z")
            Spacer(minLength: 6)
            Button { snapping.toggle() } label: { toolbarLabel("Snap", icon: snapping ? "magnet.fill" : "magnet", compact: compact) }
                .foregroundStyle(snapping ? Theme.accent : Theme.muted)
                .accessibilityAddTraits(snapping ? .isSelected : []).help("Snap to cuts and the playhead").accessibilityLabel("Snap")
            Button("Fit") { fit = true; fitScale() }.foregroundStyle(fit ? Theme.accent : Theme.muted)
                .help("Fit the whole edit in the timeline")
            Slider(value: Binding(get: { log10(scale) }, set: { fit = false; scale = pow(10, $0) }), in: -1...2.7)
                .frame(width: compact ? 56 : 100).accessibilityLabel("Timeline zoom")
        }
    }
    @ViewBuilder private func toolbarLabel(_ title: String, icon: String, compact: Bool) -> some View {
        if compact { Image(systemName: icon) }
        else { Label(title, systemImage: icon).fixedSize() }
    }
    private var labels: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Tracks").font(Theme.sans(10, .medium)).foregroundStyle(Theme.muted).frame(height: 28)
            label("Video", icon: "film", height: 82)
            ForEach(0..<max(1, overlays.count), id: \.self) { i in
                label(overlays.count > 1 ? "Overlay \(i + 1)" : "Overlay", icon: "rectangle.on.rectangle", height: overlays.isEmpty ? emptyTrackHeight : 56)
            }
            ForEach(0..<max(1, audio.count), id: \.self) { i in
                label(audio.count > 1 ? "Audio \(i + 1)" : "Audio", icon: "waveform", height: audio.isEmpty ? emptyTrackHeight : 58)
            }
        }.padding(.leading, 12).frame(maxWidth: .infinity, alignment: .leading).background(Theme.paper)
    }
    private func label(_ title: String, icon: String, height: CGFloat) -> some View {
        Label(title, systemImage: icon).font(Theme.sans(10, .medium))
            .frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .leading)
    }
    private var ruler: some View {
        Canvas { context, size in
            let step = TimelineCanvasLayout.rulerStep(pixelsPerSecond: scale)
            for i in 0...min(5000, Int(Double(size.width) / scale / step)) {
                let x = Double(i) * step * scale
                var path = Path(); path.move(to: CGPoint(x: x, y: 20)); path.addLine(to: CGPoint(x: x, y: 28))
                context.stroke(path, with: .color(Theme.faint), lineWidth: 0.5)
                context.draw(Text(Self.clock(Double(i) * step)).font(Theme.mono(9)).foregroundStyle(Theme.muted), at: CGPoint(x: x + 4, y: 9), anchor: .leading)
            }
        }.frame(height: 28).contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { store.seek(Double($0.location.x) / scale) })
    }
    private func lane(_ lane: MediaEditProject.Lane, clips: [MediaEditProject.Clip], height: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            Rectangle().fill(lane == .video ? Theme.surface : Theme.canvas)
                .contentShape(Rectangle()).gesture(DragGesture(minimumDistance: 0).onChanged { store.seek(Double($0.location.x) / scale) })
            if clips.isEmpty {
                Text(lane == .video ? "Drop video or images here" : lane == .overlay ? "Drop an image or video overlay" : "Drop music or voiceover here")
                    .font(Theme.sans(11)).foregroundStyle(Theme.muted).padding(.leading, 16).frame(height: height)
                    .allowsHitTesting(false)
            }
            ForEach(clips) { clip in
                MediaTimelineClip(clip: clip, hasCamera: store.project.linkedCamera(for: clip.id) != nil, selected: store.selected == clip.id, scale: scale,
                                  frames: store.strips[clip.id] ?? [], waveform: store.waveforms[clip.id] ?? [],
                                  image: sourceImage(clip), height: height - 8,
                                  select: { store.select(clip.id) }, move: { delta in move(clip, delta: delta) }, trim: { start, delta in trim(clip, start: start, delta: delta) })
                    .offset(x: CGFloat(store.project.position(clip.id) * scale), y: 4)
            }
        }.frame(height: height).overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
            .dropDestination(for: String.self) { values, location in
                guard let value = values.first, value.hasPrefix("asset:"), store.editable,
                      let asset = store.assets.first(where: { $0.url.path == String(value.dropFirst(6)) }),
                      (lane == .audio ? asset.kind == .audio : asset.kind != .audio) else { return false }
                store.seek(Double(location.x) / scale)
                Task { await store.add(asset, overlay: lane == .overlay, at: Double(location.x) / scale) }
                return true
            }
    }
    private func sourceImage(_ clip: MediaEditProject.Clip) -> NSImage? {
        guard let asset = store.assets.first(where: { $0.url.standardizedFileURL.path == store.session.appending(path: clip.file).standardizedFileURL.path }) else { return nil }
        return store.thumbnails[asset.url]
    }
    private func fitScale() { scale = min(500, max(0.1, Double(max(100, viewport - 80)) / max(5, store.project.duration))) }
    private func snap(_ value: Double, excluding id: UUID) -> Double {
        let frame = (max(0, value) * 30).rounded() / 30
        guard snapping else { return frame }
        let targets: [Double] = [0.0, store.time] + store.project.timelineClips.filter { $0.id != id }.flatMap { [store.project.position($0.id), store.project.position($0.id) + $0.duration] }
        return targets.min(by: { abs($0 - frame) < abs($1 - frame) }).flatMap { abs($0 - frame) * scale < 9 ? $0 : nil } ?? frame
    }
    private func move(_ clip: MediaEditProject.Clip, delta: Double) {
        guard store.editable, clip.cameraLink == nil else { return }
        store.selected = clip.id
        let desired = snap(store.project.position(clip.id) + delta, excluding: clip.id)
        if clip.lane == .video {
            let target = store.project.clips.first { $0.lane == .video && $0.id != clip.id && store.project.position($0.id) + $0.duration / 2 > desired }
            store.edit { $0.move(clip.id, before: target?.id) }
        } else { store.update(clip.id) { $0.offset = desired } }
    }
    private func trim(_ clip: MediaEditProject.Clip, start: Bool, delta: Double) {
        guard clip.cameraLink == nil else { return }
        store.selected = clip.id
        let boundary = snap(store.project.position(clip.id) + (start ? 0 : clip.duration) + delta, excluding: clip.id)
        let source = clip.start + (boundary - store.project.position(clip.id)) * clip.speed
        let newStart = start ? min(clip.end - clip.speed / 30, max(0, source)) : clip.start
        let newEnd = start ? clip.end : max(clip.start + clip.speed / 30, min(clip.sourceDuration, source))
        store.edit { $0.trim(clip.id, start: newStart, end: newEnd) }
    }
}

private struct MediaTimelineClip: View {
    let clip: MediaEditProject.Clip
    let hasCamera: Bool
    let selected: Bool
    let scale: Double
    let frames: [TimelineThumbnail]
    let waveform: [CGFloat]
    let image: NSImage?
    let height: CGFloat
    let select: () -> Void
    let move: (Double) -> Void
    let trim: (Bool, Double) -> Void
    @GestureState private var dragging: CGFloat = 0
    @GestureState private var edge: CGSize = .zero
    private var baseWidth: CGFloat { max(2, CGFloat(clip.duration * scale)) }
    private var width: CGFloat { max(2, baseWidth + edge.height - edge.width) }
    private var color: Color { clip.lane == .audio ? Theme.live : clip.lane == .overlay ? Theme.warn : Theme.accent }
    private var title: String { hasCamera ? "\(clip.name) · Screen + Camera" : clip.name }
    var body: some View {
        ZStack(alignment: .topLeading) {
            color.opacity(0.18)
            if clip.kind != .audio {
                HStack(spacing: 1) {
                    if frames.isEmpty, let image { Image(nsImage: image).resizable().scaledToFill().frame(width: width, height: height).clipped() }
                    ForEach(frames.indices, id: \.self) { index in
                        Image(decorative: frames[index].image, scale: 1).resizable().scaledToFill()
                            .frame(width: max(1, width / CGFloat(frames.count)), height: height).clipped()
                    }
                }.opacity(0.7)
            }
            if !waveform.isEmpty {
                TimelineWaveformBar(amplitudes: waveform, tint: color)
                    .frame(width: width, height: clip.kind == .audio ? height - 21 : 18)
                    .frame(maxHeight: .infinity, alignment: .bottom).background(clip.kind == .audio ? Color.clear : Color.black.opacity(0.1))
            }
            if width > 36 {
                HStack(spacing: 4) {
                    if hasCamera { Image(systemName: "video") }
                    Text(title)
                }.font(Theme.sans(10, .medium)).foregroundStyle(clip.kind == .audio ? Theme.ink : .white)
                    .lineLimit(1).padding(.horizontal, 8).padding(.vertical, 3)
                    .frame(maxWidth: .infinity, alignment: .leading).background(clip.kind == .audio ? color.opacity(0.12) : Color.black.opacity(0.65))
            }
        }
        .frame(width: width, height: height).clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(selected ? color : color.opacity(0.4), lineWidth: selected ? 2 : 1))
        .contentShape(Rectangle()).onTapGesture(perform: select)
        .gesture(DragGesture(minimumDistance: 6).updating($dragging) { value, state, _ in if clip.cameraLink == nil { state = value.translation.width } }
            .onEnded { move(Double($0.translation.width) / scale) })
        .overlay(alignment: .leading) { if selected && clip.cameraLink == nil && width > 32 { handle(start: true) } }
        .overlay(alignment: .trailing) { if selected && clip.cameraLink == nil && width > 32 { handle(start: false) } }
        .offset(x: dragging + edge.width).zIndex(dragging == 0 ? 0 : 10)
        .help("\(title) · \(MediaEditorTimeline.clock(clip.duration))")
        .accessibilityLabel("\(title), \(MediaEditorTimeline.clock(clip.duration)), \(clip.lane.rawValue) track")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { select() }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
    private func handle(start: Bool) -> some View {
        ZStack { color; Capsule().fill(.white.opacity(0.9)).frame(width: 2, height: 20) }
            .frame(width: 10, height: height).contentShape(Rectangle())
            .onHover { if $0 { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
            .gesture(DragGesture(minimumDistance: 0).updating($edge) { value, state, _ in
                let raw = Double(value.translation.width) / scale
                if start { state.width = CGFloat(min(clip.duration - 1 / 30, max(-clip.start / clip.speed, raw)) * scale) }
                else { state.height = CGFloat(max(-clip.duration + 1 / 30, min((clip.sourceDuration - clip.end) / clip.speed, raw)) * scale) }
            }
                .onEnded { trim(start, Double($0.translation.width) / scale) })
            .help(start ? "Drag to trim the beginning" : "Drag to trim the end")
    }
}
