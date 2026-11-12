import AppKit
import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

/// One workspace for recording edits, media assembly and cut review.
struct MediaEditorWorkspace: View {
    @Environment(AppModel.self) private var app
    @Environment(\.paneShown) private var shown
    let doc: SessionDoc
    let showingExport: Bool
    var initial: URL? = nil
    @StateObject private var store: MediaEditorStore
    @State private var query = ""
    @State private var filter = MediaFilter.all
    @State private var inspectorOpen = false
    @State private var mediaOpen = false
    @State private var gifBrowserOpen = false
    @State private var showMediaSidebar: Bool
    @State private var showInspector = false
    @State private var panel: StudioEditTools.Panel
    @State private var reviewRange: StudioCut?
    @State private var scale = 45.0
    @State private var fit = true
    @State private var snapping = true
    @State private var timelineHeight: CGFloat = 260
    @State private var resizeStart: CGFloat?
    @State private var exportReview: Job?
    @State private var versionsOpen = false
    init(doc: SessionDoc, initial: URL? = nil, store: MediaEditorStore? = nil, panel: StudioEditTools.Panel = .clip,
         showsMedia: Bool = false, showingExport: Bool = false) {
        self.doc = doc; self.initial = initial; self.showingExport = showingExport
        _panel = State(initialValue: panel)
        _showMediaSidebar = State(initialValue: showsMedia)
        _store = StateObject(wrappedValue: store ?? MediaEditorStore(doc: doc))
    }
    enum MediaFilter: String, CaseIterable, Identifiable {
        case all = "All", video = "Video", image = "Images", audio = "Audio"
        var id: String { rawValue }
    }
    private var visibleAssets: [Asset] {
        store.assets.filter { asset in
            store.pairedScreen(forCameraFile: asset.rel) == nil &&
            (query.isEmpty || asset.url.lastPathComponent.localizedCaseInsensitiveContains(query)) &&
            (filter == .all || filter == .video && asset.kind == .video || filter == .image && asset.kind == .image || filter == .audio && asset.kind == .audio)
        }
    }
    var body: some View {
        GeometryReader { geometry in
            let wide = geometry.size.width >= 850
            VStack(spacing: 0) {
                if showingExport { exportHeader } else { header(wide: wide) }
                if let problem = store.problem {
                    HStack {
                        Image(systemName: "exclamationmark.circle").foregroundStyle(Theme.warn)
                        Text(problem).font(Theme.sans(12)).textSelection(.enabled)
                        Spacer()
                        if store.loadFailed { Button("Retry") { Task { await store.retryLoad() } } }
                        Button { store.problem = nil } label: { Image(systemName: "xmark") }.help("Dismiss message")
                    }.buttonStyle(.plain).padding(10).background(Theme.warn.opacity(0.1))
                }
                if showingExport {
                    exportWorkspace(wide: geometry.size.width >= 720)
                } else {
                    HStack(spacing: 0) {
                        if wide && showMediaSidebar {
                            mediaBrowser.frame(width: 212)
                            Rectangle().fill(Theme.border).frame(width: 1)
                        }
                        preview.frame(maxWidth: .infinity, maxHeight: .infinity)
                        if wide && showInspector {
                            Rectangle().fill(Theme.border).frame(width: 1)
                            tools.frame(width: 268)
                        }
                    }.frame(maxHeight: .infinity)
                    if store.project.duration > 0 {
                        timelineDivider(height: geometry.size.height)
                        MediaEditorTimeline(store: store, scale: $scale, fit: $fit, snapping: $snapping, reviewRange: reviewRange)
                            .frame(height: min(timelineHeight, geometry.size.height * 0.48))
                    }
                }
            }
        }
        .background(Theme.canvas).foregroundStyle(Theme.ink)
        .task { await store.open(initial: initial) }
        .onDisappear { store.close() }
        .onChange(of: store.project) { reviewRange = nil }
        .onChange(of: panel) { reviewRange = nil }
        .onChange(of: showingExport) { _, on in
            mediaOpen = false; inspectorOpen = false; versionsOpen = false
            if on { store.pause(); store.showTimeline() }
        }
        .onChange(of: shown) { _, on in
            if on, store.project.clips.isEmpty {
                let latest = SessionJourney.latestPlayableTake(doc.meta.takes, session: doc.url)?.url
                Task { await store.openRequestedMedia(fallback: latest) }
            } else if !on {
                store.pause(); store.sourcePlayer.pause()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: TimelineEditorWindow.mediaRequested)) { notification in
            guard notification.object as? URL == doc.url else { return }
            Task { await store.openRequestedMedia() }
        }
        .onFilesChanged(in: doc.url) { Task { await store.scan() } }
        .cutmarkPopover(isPresented: $mediaOpen) { mediaBrowser.frame(width: 360, height: 560) }
        .cutmarkPopover(isPresented: $inspectorOpen) { tools.frame(width: 310, height: 495) }
        .cutmarkPopover(isPresented: $versionsOpen) { savedVideos.frame(width: 490, height: 370) }
        .sheet(item: $exportReview) { TimelineResultReview(job: $0).environment(app) }
        .sheet(isPresented: $gifBrowserOpen) {
            GIFBrowser { item, data in try await store.addCatalogGIF(item, data: data) }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            guard !showingExport else { return false }
            Task { @MainActor in
                var urls: [URL] = []
                for provider in providers {
                    let url: URL? = await withCheckedContinuation { continuation in
                        _ = provider.loadObject(ofClass: URL.self) { url, _ in continuation.resume(returning: url) }
                    }
                    if let url { urls.append(url) }
                }
                await store.importFiles(urls, startsTimeline: store.project.duration == 0)
            }
            return !providers.isEmpty
        }
    }
    private func timelineDivider(height: CGFloat) -> some View {
        Rectangle().fill(Theme.border).frame(height: 5).contentShape(Rectangle())
            .onHover { if $0 { NSCursor.resizeUpDown.push() } else { NSCursor.pop() } }
            .gesture(DragGesture().onChanged { value in
                if resizeStart == nil { resizeStart = timelineHeight }
                timelineHeight = min(height * 0.48, max(190, (resizeStart ?? timelineHeight) - value.translation.height))
            }.onEnded { _ in resizeStart = nil })
            .help("Drag to resize the timeline")
    }

    private func header(wide: Bool) -> some View {
        HStack(spacing: 10) {
            Button {
                if wide { showMediaSidebar.toggle() }
                else { mediaOpen.toggle() }
            } label: {
                Label("Media", systemImage: "square.grid.2x2")
            }
            .buttonStyle(AccentButtonStyle(kind: .quiet))
            .help("Show videos, images and audio")

            Button {
                if wide { showInspector.toggle() }
                else { inspectorOpen.toggle() }
            } label: {
                Label("Tools", systemImage: "slider.horizontal.3")
            }
            .buttonStyle(AccentButtonStyle(kind: .quiet))
            .help("Clip settings, transcript and suggested cuts")
            Spacer(minLength: 4)
            formatMenu
            Button { SessionMode.set(.export) } label: {
                Label(store.exporting ? "Exporting…" : "Export…", systemImage: "square.and.arrow.up")
            }.buttonStyle(AccentButtonStyle(kind: .solid)).disabled(store.project.duration == 0)
        }.padding(.horizontal, 16).frame(height: 48).background(Theme.paper)
    }
    private var formatMenu: some View {
        CutmarkMenuButton(help: "Aspect ratio") {
            Label(store.project.format.title, systemImage: "aspectratio").font(Theme.sans(12, .medium))
        } content: {
            for format in MediaEditProject.Format.allCases {
                MenuButton(format.title, checked: store.project.format == format) { store.edit { $0.format = format } }
            }
        }.disabled(!store.editable || store.project.duration == 0)
    }

    private var exportHeader: some View {
        HStack {
            Button { SessionMode.set(.edit) } label: { Label("Back to Edit", systemImage: "chevron.left") }
                .buttonStyle(AccentButtonStyle(kind: .quiet))
            Spacer()
            if store.project.duration > 0 {
                Button { versionsOpen.toggle() } label: { Label("Saved videos", systemImage: "film.stack") }
                    .buttonStyle(AccentButtonStyle(kind: .quiet))
            }
        }.padding(.horizontal, 16).frame(height: 48).background(Theme.paper)
    }

    @ViewBuilder private func exportWorkspace(wide: Bool) -> some View {
        if store.project.duration > 0 {
            let layout = wide ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
            layout {
                preview.frame(maxWidth: .infinity, maxHeight: .infinity)
                if wide {
                    Rule(vertical: true)
                    ScrollView { exportSettings }
                        .frame(width: 290).background(Theme.paper)
                } else {
                    Rule()
                    exportSettings.background(Theme.paper)
                }
            }
        } else if store.loading {
            ProgressView("Opening edit…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            savedVideos
        }
    }
    private var savedVideos: some View {
        SessionStudio(doc: doc, exporting: true, onReview: { job in
            versionsOpen = false
            exportReview = job
        })
    }

    private var exportSettings: some View {
        let size = MediaEditComposition.size(store.project.format)
        return VStack(alignment: .leading, spacing: 12) {
            Text("Export video").font(Theme.display(22))
            HStack(spacing: 8) {
                formatMenu
                Text("MP4 · \(Int(size.width)) × \(Int(size.height))")
                    .font(Theme.sans(12)).foregroundStyle(Theme.muted)
            }
            if store.exporting {
                ProgressView(value: store.progress) {
                    Text(store.progress == 1 ? "Saving MP4…" : "Rendering MP4…")
                }.font(Theme.sans(12))
                Button("Cancel export") { store.cancelExport() }
                    .buttonStyle(AccentButtonStyle(kind: .quiet)).disabled(store.progress == 1)
            } else {
                Button {
                    let name = doc.url.lastPathComponent + ".mp4"
                    if let destination = VideoExport.chooseDestination(name: name, type: .mpeg4Movie) {
                        store.exportVideo(to: destination)
                    }
                } label: { Label("Export MP4…", systemImage: "square.and.arrow.up") }
                .buttonStyle(AccentButtonStyle(kind: .solid)).disabled(!store.editable)
                if let url = store.exportDestination {
                    Label(url.lastPathComponent, systemImage: "checkmark.circle")
                        .font(Theme.sans(12, .medium)).lineLimit(1).help(url.path)
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                        .buttonStyle(AccentButtonStyle(kind: .quiet))
                }
                if let video = store.exported {
                    Button("Review saved video") { exportReview = TimelineResultReview.savedJob(video: video, session: doc.url) }
                        .buttonStyle(AccentButtonStyle(kind: .quiet))
                }
            }
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
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
                        Text("Preview videos, GIFs, images and audio before adding them to your edit.").font(Theme.sans(12)).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
                        Button("Import media…") { store.chooseFiles() }.buttonStyle(AccentButtonStyle(kind: .quiet)).disabled(!store.editable)
                    }.padding(20)
                }
            }
            Divider()
            HStack {
                Button {
                    mediaOpen = false
                    store.pause(); store.showTimeline()
                    gifBrowserOpen = true
                } label: {
                    Label("Find GIFs", systemImage: "film")
                }.buttonStyle(.plain).disabled(!store.editable)
                    .help("Browse animated GIFs and add them to the timeline")
                Spacer(minLength: 4)
                Button("Import GIF…") { store.chooseFiles(allowed: [.gif]) }
                    .buttonStyle(.plain).disabled(!store.editable)
            }.font(Theme.sans(11, .medium)).foregroundStyle(Theme.accent).padding(12)
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
                Text(asset.isGIF ? "GIF · " + asset.url.deletingPathExtension().lastPathComponent : asset.url.deletingPathExtension().lastPathComponent).font(Theme.sans(11, .medium)).lineLimit(2).frame(height: 28, alignment: .topLeading)
                if store.isPairedScreen(asset.rel) {
                    Label("Screen + Camera", systemImage: "video").font(Theme.sans(10)).foregroundStyle(Theme.muted)
                }
            }.contentShape(Rectangle())
        }.buttonStyle(.plain).help(asset.name)
            .draggable("asset:" + asset.url.path)
    }
    private var preview: some View {
        VStack(spacing: 0) {
            HStack {
                Text(store.source == nil ? "Preview" : "Source preview").font(Theme.sans(11, .medium)).foregroundStyle(Theme.muted)
                if let source = store.source { Text(source.name).font(Theme.sans(11)).lineLimit(1) }
                Spacer()
                if store.source != nil { Button("Back to edit") { store.showTimeline() }.buttonStyle(.plain).font(Theme.sans(11)).foregroundStyle(Theme.accent) }
            }.padding(.horizontal, 16).frame(height: 30)
            GeometryReader { geometry in
                ZStack {
                    Color.black
                    if let asset = store.source {
                        if asset.kind == .image, !asset.isGIF, let image = store.thumbnails[asset.url] ?? NSImage(contentsOf: asset.url) {
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
                    } else if store.loading || store.busy {
                        ProgressView(store.loading ? "Opening edit…" : "Preparing media…")
                            .tint(.white).foregroundStyle(.white)
                    } else {
                        VStack(spacing: 14) {
                            Image(systemName: "film").font(.system(size: 30))
                            Text("Start your edit").font(Theme.sans(20, .semibold))
                            Text("Import a video or record a take to start your timeline.")
                                .font(Theme.sans(13)).foregroundStyle(.white.opacity(0.7)).multilineTextAlignment(.center)
                            ViewThatFits(in: .horizontal) {
                                HStack(spacing: 8) { startActions }
                                VStack(spacing: 8) { startActions }
                            }
                        }.foregroundStyle(.white).padding(28)
                    }
                }.frame(width: geometry.size.width, height: geometry.size.height)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }.padding(.horizontal, 14).padding(.bottom, 8)
            if let asset = store.source {
                HStack(spacing: 10) {
                    let paired = store.isPairedScreen(asset.rel)
                    if asset.kind == .video, !paired {
                        Button("Previous cuts") { TimelineEditorWindow.shared.openLegacy(video: asset.url, doc: doc, app: app) }
                            .buttonStyle(.plain).font(Theme.sans(11)).foregroundStyle(Theme.accent)
                    }
                    Text(paired ? "Screen preview · includes camera when added" : asset.kind == .audio ? "Listen before adding" : "Preview before adding")
                        .font(Theme.sans(11)).foregroundStyle(Theme.muted)
                    Spacer()
                    if asset.kind != .audio, !paired {
                        Button("Add as overlay") { Task { await store.add(asset, overlay: true) } }.buttonStyle(AccentButtonStyle(kind: .quiet)).disabled(!store.editable || store.project.duration == 0)
                    }
                    Button(paired ? "Add take" : asset.kind == .audio ? "Add audio" : "Add to video") { Task { await store.add(asset) } }
                        .buttonStyle(AccentButtonStyle(kind: .solid)).disabled(!store.editable)
                }.padding(.horizontal, 14).frame(height: 48)
            } else if store.project.duration > 0 {
                HStack(spacing: 12) {
                    Button { store.seek(0) } label: { Image(systemName: "backward.end.fill") }
                        .help("Go to start").accessibilityLabel("Go to start")
                    Button { store.seek(store.time - 1 / 30) } label: { Image(systemName: "backward.frame") }
                        .help("Previous frame").accessibilityLabel("Previous frame")
                    Button { store.toggle() } label: { Image(systemName: store.playing ? "pause.fill" : "play.fill").frame(width: 30, height: 28) }
                        .help("Play or pause").accessibilityLabel(store.playing ? "Pause" : "Play")
                    Button { store.seek(store.time + 1 / 30) } label: { Image(systemName: "forward.frame") }
                        .help("Next frame").accessibilityLabel("Next frame")
                    Text("\(MediaEditorTimeline.clock(store.time)) / \(MediaEditorTimeline.clock(store.project.duration))").font(Theme.mono(11)).monospacedDigit()
                    if showingExport {
                        Slider(value: Binding(get: { store.time }, set: { store.seek($0) }), in: 0...store.project.duration)
                            .accessibilityLabel("Preview position")
                            .accessibilityValue(MediaEditorTimeline.clock(store.time))
                    } else {
                        Spacer()
                    }
                }.buttonStyle(.plain).disabled(store.building || store.project.duration == 0)
                    .padding(.horizontal, 16).frame(height: 42)
            }
        }
    }
    @ViewBuilder private var startActions: some View {
        if store.assets.contains(where: { $0.kind == .video || $0.kind == .image }) {
            Button("Choose media") { mediaOpen = true }
                .buttonStyle(AccentButtonStyle(kind: .solid)).disabled(!store.editable)
        } else {
            Button("Import media…") { store.chooseFiles(allowed: [.movie, .image], startsTimeline: true) }
                .buttonStyle(AccentButtonStyle(kind: .solid)).disabled(!store.editable)
        }
        Button("Go to Record") { SessionMode.set(.record) }.buttonStyle(AccentButtonStyle(kind: .quiet))
    }
    private var tools: some View {
        VStack(spacing: 0) {
            CutmarkSwitch(selection: $panel, options: StudioEditTools.Panel.allCases.map { ($0, $0.rawValue) }, fill: true)
                .padding(10)
            Rule()
            if panel == .clip { inspector }
            else { StudioEditTools(store: store, doc: doc, panel: panel, reviewRange: $reviewRange) }
        }.frame(maxHeight: .infinity).background(Theme.paper)
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
                    let camera = store.project.linkedCamera(for: clip.id)
                    Text(camera != nil ? "Screen + Camera" : clip.lane == .video ? "Main video" : clip.lane == .overlay ? "Overlay" : "Audio")
                        .font(Theme.sans(11)).foregroundStyle(Theme.muted)
                    if let camera, let link = camera.cameraLink {
                        inspectorSection("Camera") {
                            overlayLayout(camera)
                            number("Camera offset", value: link.screenMinusCamera, range: -15...15) {
                                store.setCameraOffset($0, screen: clip, camera: camera)
                            }.help("Increase the offset to show later camera frames at the same screen time.")
                            Button("Sync by microphone") { Task { await store.alignCameraByMicrophone() } }
                                .buttonStyle(AccentButtonStyle(kind: .quiet))
                        }
                    } else if store.canAddPairedCamera {
                        Button("Link camera") { Task { await store.addPairedCamera() } }
                            .buttonStyle(AccentButtonStyle(kind: .quiet))
                    }
                    if clip.lane != .video && clip.offset + clip.duration > store.project.duration {
                        Text("Only the part before the end of the video is exported.").font(Theme.sans(11)).foregroundStyle(Theme.warn)
                    }
                    if clip.cameraLink != nil {
                        Label("Synced to screen", systemImage: "link")
                            .font(Theme.sans(12)).foregroundStyle(Theme.muted)
                    } else {
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
                            if store.hasCaptureEvents {
                                Button { store.update(clip.id) { $0.autoZoom.toggle() } } label: {
                                    Label("Focus on clicks", systemImage: clip.autoZoom ? "checkmark.square.fill" : "square")
                                }.buttonStyle(.plain).font(Theme.sans(12)).foregroundStyle(clip.autoZoom ? Theme.accent : Theme.ink)
                                Text("Uses recorded clicks. The captured cursor stays in the video.").font(Theme.sans(10)).foregroundStyle(Theme.muted)
                            }
                            if clip.lane == .overlay {
                                overlayLayout(clip)
                            }
                        }
                    }
                    if clip.kind == .video || clip.kind == .audio {
                        inspectorSection("Sound") {
                            setting("Volume", value: clip.volume, range: 0...1, format: "%.2f×") { v in store.update(clip.id) { $0.volume = v } }
                            Button { store.update(clip.id) { $0.volume = clip.volume == 0 ? 1 : 0 } } label: { Label(clip.volume == 0 ? "Unmute" : "Mute", systemImage: clip.volume == 0 ? "speaker.wave.2" : "speaker.slash") }.buttonStyle(AccentButtonStyle(kind: .quiet))
                            setting("Fade in", value: clip.fadeIn, range: 0...max(0.01, clip.duration / 2), format: "%.1fs") { v in store.update(clip.id) { $0.fadeIn = v } }
                            setting("Fade out", value: clip.fadeOut, range: 0...max(0.01, clip.duration / 2), format: "%.1fs") { v in store.update(clip.id) { $0.fadeOut = v } }
                        }
                    }
                    HStack {
                        Button("Duplicate") { store.duplicate() }.disabled(clip.cameraLink != nil)
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
    @ViewBuilder private func overlayLayout(_ clip: MediaEditProject.Clip) -> some View {
        setting("Size", value: clip.overlaySize, range: 0.15...0.65, format: "%.2f") { v in store.update(clip.id) { $0.overlaySize = v } }
        HStack {
            Button(clip.overlayLeft ? "Left" : "Right") { store.update(clip.id) { $0.overlayLeft.toggle() } }
            Button(clip.overlayBottom ? "Bottom" : "Top") { store.update(clip.id) { $0.overlayBottom.toggle() } }
        }.buttonStyle(AccentButtonStyle(kind: .quiet))
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
