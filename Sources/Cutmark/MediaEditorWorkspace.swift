import AppKit
import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

/// The editor begins with media, not a preselected recording. Every control changes the saved composition.
struct MediaEditorWorkspace: View {
    @Environment(AppModel.self) private var app
    @Environment(\.paneShown) private var shown
    let doc: SessionDoc
    var initial: URL? = nil
    @StateObject private var store: MediaEditorStore
    @State private var query = ""
    @State private var filter = MediaFilter.all
    @State private var inspectorOpen = false
    @State private var mediaOpen = false
    @State private var scale = 45.0
    @State private var fit = true
    @State private var snapping = true
    @State private var timelineHeight: CGFloat = 310
    @State private var resizeStart: CGFloat?
    @State private var exportReview: Job?
    init(doc: SessionDoc, initial: URL? = nil, store: MediaEditorStore? = nil) {
        self.doc = doc; self.initial = initial
        _store = StateObject(wrappedValue: store ?? MediaEditorStore(doc: doc))
    }
    enum MediaFilter: String, CaseIterable, Identifiable {
        case all = "All", video = "Video", image = "Images", audio = "Audio"
        var id: String { rawValue }
    }
    private var visibleAssets: [Asset] {
        store.assets.filter { asset in
            (query.isEmpty || asset.url.lastPathComponent.localizedCaseInsensitiveContains(query)) &&
            (filter == .all || filter == .video && asset.kind == .video || filter == .image && asset.kind == .image || filter == .audio && asset.kind == .audio)
        }
    }
    var body: some View {
        GeometryReader { geometry in
            let wide = geometry.size.width >= 1120
            VStack(spacing: 0) {
                header(wide: wide)
                if let problem = store.problem {
                    HStack {
                        Image(systemName: "exclamationmark.circle").foregroundStyle(Theme.warn)
                        Text(problem).font(Theme.sans(12)).textSelection(.enabled)
                        Spacer()
                        if store.loadFailed { Button("Retry") { Task { await store.retryLoad() } } }
                        Button { store.problem = nil } label: { Image(systemName: "xmark") }.help("Dismiss message")
                    }.buttonStyle(.plain).padding(10).background(Theme.warn.opacity(0.1))
                }
                HStack(spacing: 0) {
                    if wide { mediaBrowser.frame(width: 252); Rectangle().fill(Theme.border).frame(width: 1) }
                    preview.frame(maxWidth: .infinity, maxHeight: .infinity)
                    if wide { Rectangle().fill(Theme.border).frame(width: 1); inspector.frame(width: 246) }
                }.frame(maxHeight: .infinity)
                Rectangle().fill(Theme.border).frame(height: 5).contentShape(Rectangle())
                    .onHover { if $0 { NSCursor.resizeUpDown.push() } else { NSCursor.pop() } }
                    .gesture(DragGesture().onChanged { value in
                        if resizeStart == nil { resizeStart = timelineHeight }
                        timelineHeight = min(geometry.size.height * 0.55, max(190, (resizeStart ?? timelineHeight) - value.translation.height))
                    }.onEnded { _ in resizeStart = nil })
                    .help("Drag to resize the timeline")
                MediaEditorTimeline(store: store, scale: $scale, fit: $fit, snapping: $snapping)
                    .frame(height: min(timelineHeight, geometry.size.height * 0.48))
            }
        }
        .background(Theme.canvas).foregroundStyle(Theme.ink)
        .task { await store.open(initial: initial) }
        .onDisappear { store.close() }
        .onChange(of: shown) { _, on in if !on { store.pause(); store.sourcePlayer.pause() } }
        .onReceive(NotificationCenter.default.publisher(for: TimelineEditorWindow.mediaRequested)) { _ in store.requestedPreview() }
        .onReceive(NotificationCenter.default.publisher(for: .cutmarkFilesChanged)) { _ in Task { await store.scan() } }
        .cutmarkPopover(isPresented: $mediaOpen) { mediaBrowser.frame(width: 360, height: 560) }
        .cutmarkPopover(isPresented: $inspectorOpen) { inspector.frame(width: 280, height: 540) }
        .sheet(item: $exportReview) { TimelineResultReview(job: $0).environment(app) }
        .onChange(of: store.exported) { _, url in
            if let url { exportReview = TimelineResultReview.savedJob(video: url, session: doc.url) }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            Task { @MainActor in
                var urls: [URL] = []
                for provider in providers {
                    let url: URL? = await withCheckedContinuation { continuation in
                        _ = provider.loadObject(ofClass: URL.self) { url, _ in continuation.resume(returning: url) }
                    }
                    if let url { urls.append(url) }
                }
                await store.importFiles(urls)
            }
            return !providers.isEmpty
        }
    }
    private func header(wide: Bool) -> some View {
        HStack(spacing: 10) {
            if !wide {
                Button { mediaOpen = true } label: { Label("Media", systemImage: "square.grid.2x2") }
                    .buttonStyle(AccentButtonStyle(kind: .quiet))
                Button { inspectorOpen = true } label: { Label("Clip settings", systemImage: "slider.horizontal.3") }
                    .buttonStyle(AccentButtonStyle(kind: .quiet))
            } else {
                Text("Editor").font(Theme.sans(15, .semibold))
                Text(store.project.clips.isEmpty ? "Choose media to begin" : "Saved on this Mac")
                    .font(Theme.sans(11)).foregroundStyle(Theme.muted)
            }
            Spacer(minLength: 4)
            CutmarkMenuButton(help: "Output format") {
                Label(store.project.format.title, systemImage: "aspectratio").font(Theme.sans(12, .medium))
            } content: {
                for format in MediaEditProject.Format.allCases {
                    MenuButton(format.title, checked: store.project.format == format) { store.edit { $0.format = format } }
                }
            }.disabled(!store.editable)
            if store.exporting {
                Text("\(Int(store.progress * 100))%").font(Theme.mono(12))
                Button("Cancel export") { store.cancelExport() }.buttonStyle(AccentButtonStyle(kind: .quiet))
            } else {
                Button { store.exportVideo() } label: { Label("Export video", systemImage: "square.and.arrow.up") }
                    .buttonStyle(AccentButtonStyle(kind: .solid)).disabled(!store.editable || store.project.duration == 0)
            }
        }.padding(.horizontal, 16).frame(height: 48).background(Theme.paper)
    }
    private var mediaBrowser: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Media library").font(Theme.sans(14, .semibold))
                Spacer()
                Button { store.chooseFiles() } label: { Image(systemName: "plus").frame(width: 28, height: 28) }
                    .buttonStyle(IconButtonStyle()).help("Import videos, images or audio").accessibilityLabel("Import media")
                    .disabled(!store.editable)
            }.padding(.horizontal, 14).padding(.top, 10)
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.muted)
                TextField("Search media", text: $query).textFieldStyle(.plain).font(Theme.sans(12))
            }.padding(9).background(Theme.canvas, in: RoundedRectangle(cornerRadius: 7)).padding(.horizontal, 12).padding(.vertical, 10)
            HStack(spacing: 12) {
                ForEach(MediaFilter.allCases) { f in
                    Button(f.rawValue) { filter = f }.buttonStyle(.plain).font(Theme.sans(11, .medium))
                        .foregroundStyle(filter == f ? Theme.accent : Theme.muted)
                        .accessibilityAddTraits(filter == f ? .isSelected : [])
                }
            }.padding(.horizontal, 14).padding(.bottom, 12)
            Divider()
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 98), spacing: 10)], spacing: 14) {
                    ForEach(visibleAssets) { asset in assetTile(asset) }
                }.padding(12)
                if visibleAssets.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "photo.on.rectangle.angled").font(.system(size: 28)).foregroundStyle(Theme.muted)
                        Text(query.isEmpty ? "Bring your media here" : "No matching media").font(Theme.sans(13, .medium))
                        Text("Preview videos, images and audio before adding them to your edit.").font(Theme.sans(12)).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
                        Button("Import media…") { store.chooseFiles() }.buttonStyle(AccentButtonStyle(kind: .quiet)).disabled(!store.editable)
                    }.padding(20)
                }
            }
            Divider()
            Text("Select to preview · Add when ready")
                .font(Theme.sans(10)).foregroundStyle(Theme.muted).padding(12)
        }.background(Theme.paper)
    }
    private func assetTile(_ asset: Asset) -> some View {
        Button { store.preview(asset); mediaOpen = false } label: {
            VStack(alignment: .leading, spacing: 6) {
                ZStack(alignment: .bottomTrailing) {
                    Rectangle().fill(Theme.surface)
                    if let image = store.thumbnails[asset.url], asset.kind != .audio {
                        GeometryReader { geometry in Image(nsImage: image).resizable().scaledToFill().frame(width: geometry.size.width, height: 70).clipped() }
                    } else {
                        Image(systemName: asset.kind == .audio ? "waveform" : "film").font(.system(size: 24)).foregroundStyle(Theme.muted).frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    if let duration = store.durations[asset.url] {
                        Text(SessionDoc.clock(duration)).font(Theme.mono(9)).foregroundStyle(.white).padding(3).background(.black.opacity(0.7)).padding(4)
                    }
                }.frame(height: 70).clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(store.source?.id == asset.id ? Theme.accent : Theme.border, lineWidth: store.source?.id == asset.id ? 2 : 1))
                Text(asset.url.deletingPathExtension().lastPathComponent).font(Theme.sans(11, .medium)).lineLimit(2).frame(height: 28, alignment: .topLeading)
            }.contentShape(Rectangle())
        }.buttonStyle(.plain).help(asset.name)
            .draggable("asset:" + asset.url.path)
    }
    private var preview: some View {
        VStack(spacing: 0) {
            HStack {
                Text(store.source == nil ? "Timeline preview" : "Source preview").font(Theme.sans(11, .medium)).foregroundStyle(Theme.muted)
                if let source = store.source { Text(source.name).font(Theme.sans(11)).lineLimit(1) }
                Spacer()
                if store.source != nil { Button("Back to edit") { store.showTimeline() }.buttonStyle(.plain).font(Theme.sans(11)).foregroundStyle(Theme.accent) }
            }.padding(.horizontal, 16).frame(height: 30)
            GeometryReader { geometry in
                ZStack {
                    Color.black
                    if let asset = store.source {
                        if asset.kind == .image, let image = store.thumbnails[asset.url] ?? NSImage(contentsOf: asset.url) {
                            Image(nsImage: image).resizable().scaledToFit()
                        } else if asset.kind == .audio {
                            VStack(spacing: 16) {
                                Image(systemName: "waveform").font(.system(size: 50)).foregroundStyle(.white.opacity(0.7))
                                Text(asset.name).font(Theme.sans(14)).foregroundStyle(.white).lineLimit(2)
                                PlayerLayerView(player: store.sourcePlayer, showsControls: true).frame(height: 60)
                            }.padding(24)
                        } else { PlayerLayerView(player: store.sourcePlayer, showsControls: true) }
                    } else if store.project.duration > 0 {
                        PlayerLayerView(player: store.player).allowsHitTesting(false)
                        if !store.playing, let frame = store.previewFrame {
                            Image(decorative: frame, scale: 1).resizable().scaledToFit().allowsHitTesting(false)
                        }
                        if store.building { Text("Updating preview…").font(Theme.sans(12)).padding(8).background(.black.opacity(0.7)).foregroundStyle(.white).frame(maxHeight: .infinity, alignment: .bottom).padding(10) }
                    } else {
                        VStack(spacing: 14) {
                            Image(systemName: "play.rectangle").font(.system(size: 42))
                            Text("Your story starts here").font(Theme.sans(20, .semibold))
                            Text("Preview a file in the media library, then add it to the timeline.")
                                .font(Theme.sans(13)).foregroundStyle(.white.opacity(0.7)).multilineTextAlignment(.center)
                            Button("Choose media") { mediaOpen = true }.buttonStyle(AccentButtonStyle(kind: .quiet))
                        }.foregroundStyle(.white).padding(28)
                    }
                }.frame(width: geometry.size.width, height: geometry.size.height)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }.padding(.horizontal, 14).padding(.bottom, 8)
            if let asset = store.source {
                HStack(spacing: 10) {
                    Button("Previous cuts") { TimelineEditorWindow.shared.openLegacy(video: asset.url, doc: doc, app: app) }
                        .buttonStyle(.plain).font(Theme.sans(11)).foregroundStyle(Theme.accent)
                        .opacity(asset.kind == .video ? 1 : 0).disabled(asset.kind != .video)
                    Text(asset.kind == .audio ? "Listen before adding" : "Preview before adding")
                        .font(Theme.sans(11)).foregroundStyle(Theme.muted)
                    Spacer()
                    if asset.kind != .audio {
                        Button("Add as overlay") { Task { await store.add(asset, overlay: true) } }.buttonStyle(AccentButtonStyle(kind: .quiet)).disabled(!store.editable || store.project.duration == 0)
                    }
                    Button(asset.kind == .audio ? "Add audio" : "Add to video") { Task { await store.add(asset) } }
                        .buttonStyle(AccentButtonStyle(kind: .solid)).disabled(!store.editable)
                }.padding(.horizontal, 14).frame(height: 48)
            } else {
                HStack(spacing: 12) {
                    Button { store.seek(0) } label: { Image(systemName: "backward.end.fill") }.help("Go to start")
                    Button { store.seek(store.time - 1 / 30) } label: { Image(systemName: "backward.frame") }.help("Previous frame")
                    Button { store.toggle() } label: { Image(systemName: store.playing ? "pause.fill" : "play.fill").frame(width: 30, height: 28) }.help("Play or pause")
                    Button { store.seek(store.time + 1 / 30) } label: { Image(systemName: "forward.frame") }.help("Next frame")
                    Text("\(MediaEditorTimeline.clock(store.time)) / \(MediaEditorTimeline.clock(store.project.duration))").font(Theme.mono(11)).monospacedDigit()
                    Spacer()
                }.buttonStyle(.plain).disabled(store.building || store.project.duration == 0)
                    .padding(.horizontal, 16).frame(height: 42)
            }
        }
    }
    private var inspector: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let asset = store.source {
                    Text("Source media").font(Theme.sans(11, .medium)).foregroundStyle(Theme.muted)
                    Text(asset.name).font(Theme.sans(14, .semibold)).textSelection(.enabled)
                    Divider()
                    Label(asset.kind == .image ? "Image" : asset.kind == .audio ? "Audio" : "Video", systemImage: asset.kind == .image ? "photo" : asset.kind == .audio ? "waveform" : "film")
                        .font(Theme.sans(12))
                    if let duration = store.durations[asset.url] {
                        Text("Duration · " + MediaEditorTimeline.clock(duration)).font(Theme.mono(11)).foregroundStyle(Theme.muted)
                    }
                    Text("Preview this file, then add it to your edit. To change an existing clip, return to the timeline.")
                        .font(Theme.sans(12)).foregroundStyle(Theme.muted)
                    Button("Back to edit") { store.showTimeline() }.buttonStyle(AccentButtonStyle(kind: .quiet))
                } else if let clip = store.selectedClip {
                    Text(clip.name).font(Theme.sans(14, .semibold)).lineLimit(2)
                    Text(clip.lane == .video ? "Main video" : clip.lane == .overlay ? "Camera / overlay" : "Audio")
                        .font(Theme.sans(11)).foregroundStyle(Theme.muted)
                    if clip.lane != .video && clip.offset + clip.duration > store.project.duration {
                        Text("Only the part before the end of the video is exported.").font(Theme.sans(11)).foregroundStyle(Theme.warn)
                    }
                    inspectorSection("Timing") {
                        number("Start", value: clip.start, range: (clip.lane == .video ? 0 : max(0, clip.start - clip.offset * clip.speed))...max(0, clip.end - clip.speed / 30)) { value in
                            store.edit { $0.trim(clip.id, start: value, end: clip.end) }
                        }
                        number("End", value: clip.end, range: (clip.start + clip.speed / 30)...clip.sourceDuration) { value in
                            store.edit { $0.trim(clip.id, start: clip.start, end: value) }
                        }
                        if clip.lane != .video { number("Position", value: clip.offset, range: 0...max(1, store.project.duration)) { v in store.update(clip.id) { $0.offset = v } } }
                        if clip.kind != .image {
                            HStack {
                                Text("Speed").font(Theme.sans(12)); Spacer()
                                CutmarkMenuButton(help: "Playback speed") { Text(String(format: "%.2g×", clip.speed)).font(Theme.sans(12, .semibold)) } content: {
                                    for speed in [0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 4.0] {
                                        MenuButton(String(format: "%.2g×", speed), checked: clip.speed == speed) {
                                            store.update(clip.id) { c in c.speed = speed; c.fadeIn = min(c.fadeIn, c.duration / 2); c.fadeOut = min(c.fadeOut, c.duration / 2) }
                                        }
                                    }
                                }
                            }
                        }
                    }
                    if clip.kind != .audio {
                        inspectorSection("Frame") {
                            HStack {
                                Button("Fit") { store.update(clip.id) { $0.fill = false } }.foregroundStyle(!clip.fill ? Theme.accent : Theme.muted)
                                Button("Fill") { store.update(clip.id) { $0.fill = true } }.foregroundStyle(clip.fill ? Theme.accent : Theme.muted)
                                Spacer()
                            }.buttonStyle(AccentButtonStyle(kind: .quiet))
                            setting("Zoom", value: clip.zoom, range: 1...3, format: "%.2f×") { v in store.update(clip.id) { $0.zoom = v } }
                            if clip.zoom > 1 || clip.fill {
                                setting("Horizontal focus", value: clip.focusX, range: 0...1, format: "%.2f") { v in store.update(clip.id) { $0.focusX = v } }
                                setting("Vertical focus", value: clip.focusY, range: 0...1, format: "%.2f") { v in store.update(clip.id) { $0.focusY = v } }
                            }
                            if store.pairedCamera != nil {
                                Button("Add synced camera") { Task { await store.addPairedCamera() } }
                                    .buttonStyle(AccentButtonStyle(kind: .quiet))
                            }
                            if store.hasCaptureEvents {
                                Button { store.update(clip.id) { $0.autoZoom.toggle() } } label: {
                                    Label("Focus on clicks", systemImage: clip.autoZoom ? "checkmark.square.fill" : "square")
                                }.buttonStyle(.plain).font(Theme.sans(12)).foregroundStyle(clip.autoZoom ? Theme.accent : Theme.ink)
                                Text("Uses recorded clicks. The captured cursor stays in the video.").font(Theme.sans(10)).foregroundStyle(Theme.muted)
                            }
                            if clip.lane == .overlay {
                                setting("Overlay size", value: clip.overlaySize, range: 0.15...0.65, format: "%.2f") { v in store.update(clip.id) { $0.overlaySize = v } }
                                HStack {
                                    Button(clip.overlayLeft ? "Left" : "Right") { store.update(clip.id) { $0.overlayLeft.toggle() } }
                                    Button(clip.overlayBottom ? "Bottom" : "Top") { store.update(clip.id) { $0.overlayBottom.toggle() } }
                                }.buttonStyle(AccentButtonStyle(kind: .quiet))
                            }
                        }
                    }
                    if clip.kind != .image {
                        inspectorSection("Sound") {
                            setting("Volume", value: clip.volume, range: 0...1, format: "%.2f×") { v in store.update(clip.id) { $0.volume = v } }
                            Button { store.update(clip.id) { $0.volume = clip.volume == 0 ? 1 : 0 } } label: { Label(clip.volume == 0 ? "Unmute" : "Mute", systemImage: clip.volume == 0 ? "speaker.wave.2" : "speaker.slash") }.buttonStyle(AccentButtonStyle(kind: .quiet))
                            setting("Fade in", value: clip.fadeIn, range: 0...max(0.01, clip.duration / 2), format: "%.1fs") { v in store.update(clip.id) { $0.fadeIn = v } }
                            setting("Fade out", value: clip.fadeOut, range: 0...max(0.01, clip.duration / 2), format: "%.1fs") { v in store.update(clip.id) { $0.fadeOut = v } }
                        }
                    }
                    HStack {
                        Button("Duplicate") { store.duplicate() }
                        Spacer()
                        Button("Remove") { store.remove() }.foregroundStyle(Theme.danger)
                    }.buttonStyle(.plain).font(Theme.sans(12, .medium))
                } else {
                    Image(systemName: "slider.horizontal.3").font(.system(size: 24)).foregroundStyle(Theme.muted)
                    Text("Select a timeline clip").font(Theme.sans(14, .semibold))
                    Text("Adjust its trim, speed, framing and sound here. Select media in the library to preview it first.")
                        .font(Theme.sans(12)).foregroundStyle(Theme.muted)
                }
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading).disabled(!store.editable)
        }.background(Theme.paper).id(store.selected)
    }
    private func inspectorSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider(); Text(title).font(Theme.sans(12, .semibold)); content()
        }
    }
    private func number(_ name: String, value: Double, range: ClosedRange<Double>, change: @escaping (Double) -> Void) -> some View {
        HStack {
            Text(name).font(Theme.sans(12)); Spacer()
            MediaTimeField(value: value, range: range, commit: change).frame(width: 74)
            Text("s").font(Theme.sans(10)).foregroundStyle(Theme.muted)
        }
    }
    private func setting(_ title: String, value: Double, range: ClosedRange<Double>, format: String, change: @escaping (Double) -> Void) -> some View {
        MediaSettingSlider(title: title, value: value, range: range, format: format, commit: change)
    }
}

private struct MediaTimeField: View {
    @FocusState private var focused: Bool
    let value: Double
    let range: ClosedRange<Double>
    let commit: (Double) -> Void
    @State private var text = ""
    var body: some View {
        TextField("Seconds", text: $text).textFieldStyle(.plain).font(Theme.mono(11)).multilineTextAlignment(.trailing)
            .padding(6).background(Theme.canvas, in: RoundedRectangle(cornerRadius: 5))
            .focused($focused).onAppear { refresh() }.onChange(of: value) { if !focused { refresh() } }
            .onSubmit { save() }.onChange(of: focused) { _, isFocused in if !isFocused { save() } }
    }
    private func refresh() { text = String(format: "%.2f", value) }
    private func save() { if let number = Double(text), number.isFinite { commit(min(range.upperBound, max(range.lowerBound, number))) }; refresh() }
}
private struct MediaSettingSlider: View {
    let title: String
    let value: Double
    let range: ClosedRange<Double>
    let format: String
    let commit: (Double) -> Void
    @State private var local = 0.0
    @State private var dragging = false
    var body: some View {
        VStack(spacing: 5) {
            HStack { Text(title); Spacer(); Text(String(format: format, dragging ? local : value)).monospacedDigit().foregroundStyle(Theme.muted) }.font(Theme.sans(11))
            Slider(value: Binding(get: { dragging ? local : min(range.upperBound, max(range.lowerBound, value)) }, set: { local = $0 }), in: range, onEditingChanged: { on in
                if on { local = value }; dragging = on; if !on { commit(local) }
            }).tint(Theme.accent).accessibilityLabel(title)
        }
    }
}
