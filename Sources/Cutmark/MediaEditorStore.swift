import AppKit
import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class MediaEditorStore: ObservableObject {
    @Published private(set) var project = MediaEditProject()
    @Published var selected: UUID?
    @Published var source: Asset?
    @Published private(set) var assets: [Asset] = []
    @Published private(set) var thumbnails: [URL: NSImage] = [:]
    @Published private(set) var durations: [URL: Double] = [:]
    @Published private(set) var waveforms: [UUID: [CGFloat]] = [:]
    @Published private(set) var strips: [UUID: [TimelineThumbnail]] = [:]
    @Published private(set) var previewFrame: CGImage?
    @Published private(set) var time = 0.0
    @Published private(set) var playing = false
    @Published private(set) var building = false
    @Published private(set) var busy = false
    @Published private(set) var exporting = false
    @Published private(set) var progress: Float = 0
    @Published var problem: String?
    @Published private(set) var loadFailed = false
    @Published private(set) var exported: URL?
    @Published private(set) var history: [MediaEditProject] = []
    @Published private(set) var future: [MediaEditProject] = []
    let player = AVPlayer()
    let sourcePlayer = AVPlayer()
    let session: URL
    private let doc: SessionDoc
    private var observer: Any?
    private var rebuild: Task<Void, Never>?
    private var thumbnailsTask: Task<Void, Never>?
    private var samplesTask: Task<Void, Never>?
    private var frameTask: Task<Void, Never>?
    private var frameGenerator: AVAssetImageGenerator?
    private var render: AVAssetExportSession?
    private var revision = 0
    private var opened = false
    private var seekGeneration = 0
    private var seeking = false
    private var exportTask: Task<Void, Never>?
    var selectedClip: MediaEditProject.Clip? { project.clips.first { $0.id == selected } }
    var editable: Bool { opened && !loadFailed && !busy && !exporting }
    var hasCaptureEvents: Bool {
        guard let clip = selectedClip, let take = doc.meta.takes.first(where: { $0.file == clip.file && $0.kind == .screen }) else { return false }
        return CaptureEventLog.header(CaptureEventLog.url(in: session, take: take.number)).map { CaptureEventLog.valid($0, take: take.number) } == true
    }
    init(doc: SessionDoc) { self.doc = doc; session = doc.url }
    func open(initial: URL? = nil) async {
        guard !opened else { return }; opened = true
        do { project = try MediaEditProject.load(in: session); loadFailed = false }
        catch { loadFailed = true; problem = "Couldn’t open your saved edit. \(error.localizedDescription)" }
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.05, preferredTimescale: 600), queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, !self.building, !self.seeking else { return }
                let t = self.player.currentTime().seconds
                if t.isFinite { self.time = max(0, min(self.project.duration, t)) }
                self.playing = self.player.rate != 0
            }
        }
        await scan()
        if !loadFailed, project.clips.isEmpty, !FileManager.default.fileExists(atPath: MediaEditProject.file(in: session).path), let initial,
           let asset = assets.first(where: { $0.url.standardizedFileURL == initial.standardizedFileURL }) {
            preview(asset)
            await add(asset)
        } else { refreshPreview() }
        requestedPreview()
    }
    func requestedPreview() {
        guard let url = TimelineEditorWindow.requested.removeValue(forKey: session),
              let asset = assets.first(where: { $0.url.standardizedFileURL == url.standardizedFileURL }) else { return }
        preview(asset)
    }
    func retryLoad() async {
        do { project = try MediaEditProject.load(in: session); loadFailed = false; problem = nil; refreshPreview() }
        catch { problem = error.localizedDescription }
    }
    func scan() async {
        let root = session, takes = Set(doc.meta.takes.map(\.file))
        let found = await Task.detached(priority: .utility) { AssetStore.walk(root, takeFiles: takes).filter { $0.kind != .other } }.value
        guard !Task.isCancelled else { return }
        assets = found
        thumbnailsTask?.cancel()
        thumbnailsTask = Task { [weak self] in
            for asset in found {
                guard let self, !Task.isCancelled else { return }
                if self.thumbnails[asset.url] == nil { self.thumbnails[asset.url] = await Thumbs.shared.image(asset) }
                if asset.kind == .video || asset.kind == .audio {
                    let duration = try? await AVURLAsset(url: asset.url).load(.duration).seconds
                    if let duration, duration.isFinite { self.durations[asset.url] = duration }
                }
            }
        }
    }
    func preview(_ asset: Asset) {
        pause(); sourcePlayer.pause(); source = asset
        sourcePlayer.replaceCurrentItem(with: asset.kind == .image ? nil : AVPlayerItem(url: asset.url))
    }
    func showTimeline() { sourcePlayer.pause(); sourcePlayer.replaceCurrentItem(with: nil); source = nil }
    func select(_ id: UUID) {
        selected = id; showTimeline()
        let start = project.position(id), end = start + (selectedClip?.duration ?? 0)
        if time < start || time >= end { seek(start) }
    }
    func pause() { player.pause(); playing = false; requestFrame(at: time) }
    private func requestFrame(at seconds: Double) {
        frameTask?.cancel(); frameGenerator?.cancelAllCGImageGeneration(); previewFrame = nil
        guard let item = player.currentItem, !building else { return }
        let generator = AVAssetImageGenerator(asset: item.asset)
        generator.videoComposition = item.videoComposition
        generator.maximumSize = CGSize(width: 1440, height: 1440)
        generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
        frameGenerator = generator
        frameTask = Task { [weak self] in
            let frame = try? await generator.image(at: MediaEditComposition.time(min(seconds, max(0, (self?.project.duration ?? 0) - 1 / 30)))).image
            guard !Task.isCancelled else { return }
            self?.previewFrame = frame
        }
    }
    func toggle() {
        guard !building, player.currentItem != nil else { return }
        showTimeline()
        if player.rate == 0 { if time >= project.duration - 0.04 { seek(0) }; player.play(); playing = true }
        else { pause() }
    }
    func seek(_ seconds: Double) {
        guard !building else { return }
        showTimeline(); pause()
        let target = max(0, min(project.duration, seconds)); time = target
        requestFrame(at: target)
        seekGeneration += 1; let generation = seekGeneration; seeking = true
        player.seek(to: MediaEditComposition.time(target), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.seekGeneration == generation else { return }
                self.seeking = false
            }
        }
    }
    func edit(_ change: (inout MediaEditProject) -> Void) {
        guard editable else { return }
        var next = project; change(&next)
        guard next != project else { return }
        do {
            try next.save(in: session)
            history.append(project); if history.count > 80 { history.removeFirst() }; future = []
            project = next; problem = nil; exported = nil
            if !project.clips.contains(where: { $0.id == selected }) { selected = project.clips.first?.id }
            refreshPreview()
        } catch { problem = "Couldn’t save this change. \(error.localizedDescription)" }
    }
    func update(_ id: UUID, _ change: (inout MediaEditProject.Clip) -> Void) {
        edit { project in if let i = project.clips.firstIndex(where: { $0.id == id }) { change(&project.clips[i]) } }
    }
    func undo(redo: Bool = false) {
        guard editable, let next = redo ? future.last : history.last else { return }
        do {
            try next.save(in: session)
            if redo { future.removeLast(); history.append(project) } else { history.removeLast(); future.append(project) }
            project = next; selected = project.clips.first?.id; problem = nil; exported = nil; refreshPreview()
        } catch { problem = error.localizedDescription }
    }
    func split() {
        guard let selected else { return }
        let sample = player.currentTime().seconds
        let at = playing && sample.isFinite && !seeking ? sample : time
        var candidate = project
        guard candidate.split(selected, at: at) else { problem = "Place the playhead inside the selected clip to split it."; return }
        edit { $0 = candidate }
    }
    func remove() { guard let selected else { return }; edit { $0.clips.removeAll { $0.id == selected } } }
    func duplicate() {
        guard var clip = selectedClip else { return }
        clip.id = UUID()
        if clip.lane != .video { clip.offset += clip.duration }
        edit { project in
            let index = project.clips.firstIndex { $0.id == selected } ?? (project.clips.count - 1)
            project.clips.insert(clip, at: index + 1)
        }; selected = clip.id
    }
    func add(_ asset: Asset, overlay: Bool = false, at insertion: Double? = nil) async {
        guard editable else { return }; busy = true; defer { busy = false }
        do {
            let root = session.standardizedFileURL.resolvingSymlinksInPath().path + "/"
            let url = asset.url.standardizedFileURL.resolvingSymlinksInPath()
            guard url.path.hasPrefix(root) else { throw MediaEditProject.Failure.invalid("Import this file into the session first.") }
            let kind: MediaEditProject.Kind = asset.kind == .image ? .image : asset.kind == .audio ? .audio : .video
            let seconds = kind == .image ? 3600 : try await AVURLAsset(url: url).load(.duration).seconds
            guard seconds.isFinite, seconds >= 1 / 30 else { throw MediaEditProject.Failure.invalid("This file has no usable duration.") }
            var clip = MediaEditProject.Clip(file: String(url.path.dropFirst(root.count)), name: url.deletingPathExtension().lastPathComponent,
                kind: kind, lane: kind == .audio ? .audio : overlay ? .overlay : .video, sourceDuration: seconds, end: kind == .image ? 5 : seconds)
            if clip.lane != .video { clip.offset = max(0, insertion ?? time) }
            // A camera overlay should not double the main recording's soundtrack.
            if overlay { clip.volume = 0 }
            busy = false
            edit { project in
                if clip.lane == .video, let insertion,
                   let index = project.clips.firstIndex(where: { $0.lane == .video && project.position($0.id) + $0.duration / 2 > insertion }) {
                    project.clips.insert(clip, at: index)
                } else { project.clips.append(clip) }
            }; selected = clip.id; showTimeline()
        } catch { problem = error.localizedDescription }
    }
    var pairedCamera: Take? {
        guard let clip = selectedClip, clip.lane == .video,
              let screen = doc.meta.takes.first(where: { $0.kind == .screen && $0.file == clip.file }) else { return nil }
        return doc.meta.takes.first { $0.kind == .camera && $0.number == screen.number }
    }
    func addPairedCamera() async {
        guard editable, let clip = selectedClip, let camera = pairedCamera,
              let screen = doc.meta.takes.first(where: { $0.kind == .screen && $0.file == clip.file }) else { return }
        guard let delta = CaptureSync.screenMinusCameraSeconds(camera: camera, screen: screen) else {
            problem = "This recording has no frame timing for automatic sync. Preview the camera in Media, add it as an overlay and adjust its Position."; return
        }
        busy = true; defer { busy = false }
        do {
            let url = try MediaEditProject.source(camera.file, session: session)
            let duration = try await AVURLAsset(url: url).load(.duration).seconds
            let sourceStart = max(0, clip.start + delta), end = min(duration, clip.end + delta)
            guard end - sourceStart >= clip.speed / 30 else { throw MediaEditProject.Failure.invalid("These trimmed recordings do not overlap.") }
            var overlay = MediaEditProject.Clip(file: camera.file, name: "Camera · " + clip.name, kind: .video, lane: .overlay,
                sourceDuration: duration, start: sourceStart, end: end,
                offset: project.position(clip.id) + max(0, -(clip.start + delta)) / clip.speed, speed: clip.speed, volume: 0)
            overlay.overlayBottom = true
            busy = false; edit { $0.clips.append(overlay) }; selected = overlay.id
        } catch { problem = error.localizedDescription }
    }
    func importFiles(_ urls: [URL]) async {
        guard editable else { return }; busy = true; defer { busy = false }
        let directory = session.appending(path: "assets")
        do {
            guard directory.resolvingSymlinksInPath().path.hasPrefix(session.resolvingSymlinksInPath().path + "/") else { throw MediaEditProject.Failure.invalid("The assets folder is outside this session.") }
            _ = try MediaEditProject.directory("assets", in: session)
            for url in urls {
                guard Asset.kind(of: url) != .other, (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
                let granted = url.startAccessingSecurityScopedResource(); defer { if granted { url.stopAccessingSecurityScopedResource() } }
                let target = AssetStore.free(directory.appending(path: url.lastPathComponent))
                try await Task.detached(priority: .utility) { try FileManager.default.copyItem(at: url, to: target) }.value
            }
            await scan()
        } catch { problem = "Some files could not be imported. \(error.localizedDescription)"; await scan() }
    }
    func chooseFiles() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.movie, .image, .audio]; panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.begin { [weak self] response in
            guard response == .OK else { return }
            Task { @MainActor [weak self] in await self?.importFiles(panel.urls) }
        }
    }
    private func refreshPreview() {
        seekGeneration += 1; seeking = false
        revision += 1; let expected = revision, snapshot = project
        rebuild?.cancel(); pause(); player.replaceCurrentItem(with: nil)
        guard !snapshot.clips.isEmpty, snapshot.duration > 0 else { building = false; time = 0; return }
        building = true
        rebuild = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: .milliseconds(120))
                let result = try await MediaEditComposition.build(snapshot, session: self.session)
                try Task.checkCancellation()
                guard expected == self.revision else { return }
                self.player.replaceCurrentItem(with: result.item())
                let at = min(self.time, max(0, snapshot.duration - 1 / 30))
                await self.player.seek(to: MediaEditComposition.time(at), toleranceBefore: .zero, toleranceAfter: .zero)
                guard expected == self.revision else { return }
                self.time = at; self.building = false; self.requestFrame(at: at)
                self.loadSamples(snapshot)
            } catch {
                guard !Task.isCancelled, expected == self.revision else { return }
                self.building = false; self.problem = "Preview unavailable. \(error.localizedDescription)"
            }
        }
    }
    private func loadSamples(_ project: MediaEditProject) {
        samplesTask?.cancel()
        samplesTask = Task { [weak self] in
            guard let self else { return }
            for clip in project.clips {
                guard !Task.isCancelled else { return }
                guard let url = try? MediaEditProject.source(clip.file, session: self.session) else { continue }
                if clip.kind == .video {
                    let frames = try? await TimelineMedia.thumbnails(url: url, start: clip.start, end: clip.end, imageCount: min(8, max(2, 96 / max(1, project.clips.count))))
                    guard !Task.isCancelled else { return }; self.strips[clip.id] = frames ?? []
                }
                if clip.kind != .image {
                    let samples = try? await TimelineMedia.waveform(url: url, start: clip.start, end: clip.end, sampleCount: 192)
                    guard !Task.isCancelled else { return }; self.waveforms[clip.id] = samples ?? []
                }
            }
            let ids = Set(project.clips.map(\.id))
            self.strips = self.strips.filter { ids.contains($0.key) }; self.waveforms = self.waveforms.filter { ids.contains($0.key) }
        }
    }
    func exportVideo() {
        guard editable, project.duration > 0 else { return }
        exporting = true; progress = 0; problem = nil; pause(); sourcePlayer.pause()
        let snapshot = project
        exportTask = Task {
            var progressTask: Task<Void, Never>?
            defer { progressTask?.cancel(); render = nil; exporting = false }
            let folder = session.appending(path: "edits")
            let temporary = session.appending(path: "_edit/studio/export-\(UUID()).mp4")
            defer { try? FileManager.default.removeItem(at: temporary) }
            do {
                let composition = try await MediaEditComposition.build(snapshot, session: session)
                guard let exporter = AVAssetExportSession(asset: composition.asset, presetName: AVAssetExportPresetHighestQuality) else { throw MediaEditProject.Failure.invalid("Export is not available for these files.") }
                try Task.checkCancellation()
                render = exporter; exporter.videoComposition = composition.video; exporter.audioMix = composition.audio
                exporter.timeRange = CMTimeRange(start: .zero, duration: MediaEditComposition.time(snapshot.duration))
                exporter.outputURL = temporary; exporter.outputFileType = .mp4; exporter.shouldOptimizeForNetworkUse = true
                progressTask = Task { [weak self] in
                    while !Task.isCancelled { self?.progress = exporter.progress; try? await Task.sleep(for: .milliseconds(150)) }
                }
                await exporter.export()
                guard exporter.status == .completed else { throw exporter.error ?? MediaEditProject.Failure.invalid(exporter.status == .cancelled ? "Export cancelled. Your edit is saved." : "Export did not finish. Your edit is saved.") }
                guard folder.resolvingSymlinksInPath().path.hasPrefix(session.resolvingSymlinksInPath().path + "/") else { throw MediaEditProject.Failure.invalid("The export folder is outside this session.") }
                _ = try MediaEditProject.directory("edits", in: session)
                let final = AssetStore.free(folder.appending(path: "studio-edit.mp4"))
                try FileManager.default.moveItem(at: temporary, to: final)
                exported = final; progress = 1
                NotificationCenter.default.post(name: .cutmarkFilesChanged, object: session)
                await scan()
            } catch { problem = Task.isCancelled ? "Export cancelled. Your edit is saved." : error.localizedDescription }
        }
    }
    func cancelExport() { exportTask?.cancel(); render?.cancelExport() }
    func close() {
        rebuild?.cancel(); thumbnailsTask?.cancel(); samplesTask?.cancel(); player.pause(); playing = false; sourcePlayer.pause()
        frameTask?.cancel(); frameGenerator?.cancelAllCGImageGeneration(); previewFrame = nil
        if let observer { player.removeTimeObserver(observer) }; observer = nil
        player.replaceCurrentItem(with: nil); sourcePlayer.replaceCurrentItem(with: nil)
        opened = false
    }
}
