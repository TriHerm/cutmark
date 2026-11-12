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
    @Published private(set) var loading = false
    @Published private(set) var exported: URL?
    @Published private(set) var exportDestination: URL?
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
    private var gifPreviewTask: Task<Void, Never>?
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
        loading = true
        defer { loading = false }
        do { project = try MediaEditProject.load(in: session); selected = project.timelineClips.first?.id; loadFailed = false }
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
        guard opened, !Task.isCancelled else { return }
        refreshPreview()
        let latest = project.clips.isEmpty && !loadFailed
            ? SessionJourney.latestPlayableTake(doc.meta.takes, session: session)?.url : nil
        await openRequestedMedia(fallback: initial ?? latest)
    }

    func openRequestedMedia(fallback: URL? = nil) async {
        guard opened else { return }
        let request = TimelineEditorWindow.requested[session]
        guard let url = request?.video ?? fallback else { return }
        var requestedAsset = assets.first { $0.url.standardizedFileURL == url.standardizedFileURL }
        if requestedAsset == nil {
            await scan()
            guard opened, !Task.isCancelled else { return }
            requestedAsset = assets.first { $0.url.standardizedFileURL == url.standardizedFileURL }
        }
        if let request {
            guard TimelineEditorWindow.requested[session] == request else { return }
            TimelineEditorWindow.requested.removeValue(forKey: session)
        }
        guard let found = requestedAsset else {
            problem = "This recording is no longer available. Choose a video from Media."
            return
        }
        let asset = request?.startEdit == false ? found : pairedScreen(forCameraFile: found.rel) ?? found
        if request?.startEdit != false, asset.kind == .video, editable {
            if let clip = project.visibleClips.first(where: { $0.lane == .video && $0.file == asset.rel }) {
                select(clip.id)
                return
            }
            if project.clips.isEmpty, !FileManager.default.fileExists(atPath: MediaEditProject.file(in: session).path) {
                await add(asset, startDraft: true)
                return
            }
        }
        if request != nil || fallback != nil && !project.clips.isEmpty { preview(asset) }
    }
    func retryLoad() async {
        do {
            project = try MediaEditProject.load(in: session)
            selected = project.timelineClips.first?.id
            loadFailed = false; problem = nil; refreshPreview()
        }
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
        pause(); showTimeline(); source = asset
        if asset.isGIF {
            gifPreviewTask = Task {
                do {
                    let original = try MediaEditProject.source(asset.rel, session: session)
                    let movie = try await MediaEditComposition.imageMovie(original, session: session, animated: true)
                    guard !Task.isCancelled, source?.url == asset.url else { return }
                    sourcePlayer.replaceCurrentItem(with: AVPlayerItem(url: movie))
                    sourcePlayer.play()
                } catch {
                    if !Task.isCancelled { problem = error.localizedDescription }
                }
            }
        } else if asset.kind != .image {
            sourcePlayer.replaceCurrentItem(with: AVPlayerItem(url: asset.url))
        }
    }
    func showTimeline() {
        gifPreviewTask?.cancel()
        sourcePlayer.pause()
        sourcePlayer.replaceCurrentItem(with: nil)
        source = nil
    }
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
        showTimeline(); player.pause(); playing = false
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
        next.alignLinkedCameras()
        guard next != project else { return }
        do {
            try next.save(in: session)
            history.append(project); if history.count > 80 { history.removeFirst() }; future = []
            project = next; problem = nil; exported = nil; exportDestination = nil
            if !project.timelineClips.contains(where: { $0.id == selected }) { selected = project.timelineClips.first?.id }
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
            project = next; selected = project.timelineClips.first?.id
            problem = nil; exported = nil; exportDestination = nil; refreshPreview()
        } catch { problem = error.localizedDescription }
    }
    private var cutTime: Double {
        let sample = player.currentTime().seconds
        return playing && sample.isFinite && !seeking ? sample : time
    }
    private func clipToCut(at time: Double) -> MediaEditProject.Clip? {
        func containsCut(_ clip: MediaEditProject.Clip) -> Bool {
            let local = time - project.position(clip.id)
            return clip.cameraLink == nil && local >= 1 / 30 && clip.duration - local >= 1 / 30
        }
        if let clip = selectedClip, containsCut(clip) { return clip }
        return project.clips.first { $0.lane == .video && containsCut($0) }
    }
    var canCutAtPlayhead: Bool {
        editable && !building && source == nil && clipToCut(at: cutTime) != nil
    }
    func split() {
        guard editable, !building, source == nil else { return }
        let at = cutTime
        guard let clip = clipToCut(at: at) else { return }
        var candidate = project
        guard candidate.split(clip.id, at: at) else { return }
        edit { $0 = candidate }
    }
    func trimToPlayhead(start: Bool) {
        guard editable, !building, source == nil else { return }
        let at = cutTime
        guard let clip = clipToCut(at: at) else { return }
        let position = project.position(clip.id)
        let boundary = clip.start + (at - position) * clip.speed
        let previous = project
        edit { $0.trim(clip.id, start: start ? boundary : clip.start, end: start ? clip.end : boundary) }
        guard previous != project else { return }
        if selected != clip.id { selected = clip.id }
        if start && clip.lane == .video { time = position }
    }
    func remove() { guard let selected else { return }; edit { $0.clips.removeAll { $0.id == selected } } }
    func duplicate() {
        guard var clip = selectedClip, clip.cameraLink == nil else { return }
        let source = clip.id
        clip.id = UUID()
        if clip.lane != .video { clip.offset += clip.duration }
        edit { project in
            let index = project.clips.firstIndex { $0.id == selected } ?? (project.clips.count - 1)
            project.clips.insert(clip, at: index + 1)
            project.copyCamera(from: source, to: clip.id)
        }
        if project.clips.contains(where: { $0.id == clip.id }) { selected = clip.id }
    }
    func add(_ asset: Asset, overlay: Bool = false, at insertion: Double? = nil, startDraft: Bool = false) async {
        guard editable else { return }; busy = true; defer { busy = false }
        do {
            let root = session.standardizedFileURL.resolvingSymlinksInPath().path + "/"
            let url = asset.url.standardizedFileURL.resolvingSymlinksInPath()
            guard url.path.hasPrefix(root) else { throw MediaEditProject.Failure.invalid("Import this file into the session first.") }
            let kind: MediaEditProject.Kind
            let seconds: Double
            if asset.isGIF {
                kind = .gif
                seconds = try GIFTiming(url: url).duration
            } else if asset.kind == .image {
                kind = .image
                seconds = 3600
            } else {
                kind = asset.kind == .audio ? .audio : .video
                seconds = try await AVURLAsset(url: url).load(.duration).seconds
            }
            guard seconds.isFinite, seconds >= 1 / 30 else { throw MediaEditProject.Failure.invalid("This file has no usable duration.") }
            var clip = MediaEditProject.Clip(file: String(url.path.dropFirst(root.count)), name: url.deletingPathExtension().lastPathComponent,
                kind: kind, lane: kind == .audio ? .audio : overlay ? .overlay : .video, sourceDuration: seconds, end: kind == .image ? 5 : seconds)
            if clip.lane != .video { clip.offset = max(0, insertion ?? time) }
            // A camera overlay should not double the main recording's soundtrack.
            if overlay { clip.volume = 0 }
            var cameraOverlay: MediaEditProject.Clip?
            var cameraProblem: String?
            if let pair = pairedSources(screenFile: clip.file), clip.lane == .video {
                do {
                    let pairing = try await syncedOverlay(for: clip, camera: pair.camera, screen: pair.screen)
                    cameraOverlay = pairing.clip
                    if !pairing.measured { cameraProblem = "Camera timing is estimated. You can adjust it in Tools → Camera." }
                }
                catch { cameraProblem = error.localizedDescription }
            }
            guard opened, !Task.isCancelled else { return }
            if startDraft, FileManager.default.fileExists(atPath: MediaEditProject.file(in: session).path) {
                preview(asset)
                return
            }
            busy = false
            edit { project in
                if clip.lane == .video, let insertion,
                   let index = project.clips.firstIndex(where: { $0.lane == .video && project.position($0.id) + $0.duration / 2 > insertion }) {
                    project.clips.insert(clip, at: index)
                } else { project.clips.append(clip) }
                if let cameraOverlay { project.clips.append(cameraOverlay) }
            }
            if project.clips.contains(where: { $0.id == clip.id }) {
                select(clip.id)
                if let cameraProblem { problem = cameraProblem }
            }
        } catch { problem = error.localizedDescription }
    }
    var canAddPairedCamera: Bool {
        guard let clip = selectedClip, clip.lane == .video, isPairedScreen(clip.file) else { return false }
        return project.linkedCamera(for: clip.id) == nil
    }

    private func existingCamera(for clip: MediaEditProject.Clip, file: String) -> MediaEditProject.Clip? {
        let start = project.position(clip.id), end = start + clip.duration
        return project.clips.first {
            $0.cameraLink == nil && $0.lane == .overlay && $0.kind == .video && $0.file == file &&
            $0.offset < end && $0.offset + $0.duration > start
        }
    }

    func isPairedScreen(_ file: String) -> Bool {
        guard let pair = pairedSources(screenFile: file) else { return false }
        return assets.contains { $0.rel == pair.camera.file }
    }

    func pairedScreen(forCameraFile file: String) -> Asset? {
        guard let camera = doc.meta.takes.first(where: { $0.kind == .camera && $0.file == file }),
              let screen = doc.meta.takes.first(where: { $0.kind == .screen && $0.number == camera.number })
        else { return nil }
        return assets.first { $0.rel == screen.file }
    }

    private func pairedSources(screenFile: String) -> (camera: Take, screen: Take)? {
        guard let screen = doc.meta.takes.first(where: { $0.kind == .screen && $0.file == screenFile }),
              let camera = doc.meta.takes.first(where: { $0.kind == .camera && $0.number == screen.number })
        else { return nil }
        return (camera, screen)
    }

    private func syncedOverlay(for clip: MediaEditProject.Clip, camera: Take, screen: Take) async throws -> (clip: MediaEditProject.Clip, measured: Bool) {
        let cameraURL = try MediaEditProject.source(camera.file, session: session)
        let screenURL = try MediaEditProject.source(screen.file, session: session)
        let cameraAsset = AVURLAsset(url: cameraURL), screenAsset = AVURLAsset(url: screenURL)
        let duration = try await cameraAsset.load(.duration).seconds
        guard duration.isFinite, duration >= 1 / 30, try await !cameraAsset.loadTracks(withMediaType: .video).isEmpty else {
            throw MediaEditProject.Failure.invalid("The camera file has no usable video.")
        }
        async let screenAudio = screenAsset.loadTracks(withMediaType: .audio)
        async let cameraAudio = cameraAsset.loadTracks(withMediaType: .audio)
        let (screenTracks, cameraTracks) = try await (screenAudio, cameraAudio)
        let frameOffset = CaptureSync.screenMinusCameraSeconds(camera: camera, screen: screen)
        let startEstimate = screen.startedAt.timeIntervalSince(camera.startedAt)
        let estimate = abs(startEstimate) <= 15 ? startEstimate : 0
        var microphoneOffset: Double?
        if !screenTracks.isEmpty, !cameraTracks.isEmpty {
            microphoneOffset = try? await CaptureSync.microphoneOffset(camera: cameraURL, cameraDuration: duration,
                screen: screenURL, screenDuration: clip.sourceDuration, near: frameOffset)
        }
        let delta = microphoneOffset ?? frameOffset ?? estimate
        let useCameraAudio = screenTracks.isEmpty && !cameraTracks.isEmpty
        var overlay = MediaEditProject.Clip(file: camera.file, name: "Camera · " + clip.name, kind: .video, lane: .overlay,
            sourceDuration: duration, end: duration, volume: useCameraAudio ? 1 : 0)
        overlay.cameraLink = .init(screen: clip.id, screenMinusCamera: delta)
        overlay.overlayBottom = true
        return (overlay, microphoneOffset != nil || frameOffset != nil)
    }

    func addPairedCamera() async {
        guard editable, let clip = selectedClip, clip.lane == .video,
              let pair = pairedSources(screenFile: clip.file), project.linkedCamera(for: clip.id) == nil else { return }
        busy = true; defer { busy = false }
        do {
            let pairing = try await syncedOverlay(for: clip, camera: pair.camera, screen: pair.screen)
            guard opened, !Task.isCancelled else { return }
            busy = false
            if let existing = existingCamera(for: clip, file: pair.camera.file) {
                update(existing.id) { $0.cameraLink = pairing.clip.cameraLink; $0.volume = pairing.clip.volume }
            } else {
                edit { $0.clips.append(pairing.clip) }
            }
            if project.linkedCamera(for: clip.id) != nil, !pairing.measured {
                problem = "Camera timing is estimated. You can adjust it in Tools → Camera."
            }
        } catch { problem = error.localizedDescription }
    }

    func alignCameraByMicrophone() async {
        guard editable, let screen = selectedClip, let camera = project.linkedCamera(for: screen.id) else { return }
        busy = true; defer { busy = false }
        do {
            let cameraURL = try MediaEditProject.source(camera.file, session: session)
            let screenURL = try MediaEditProject.source(screen.file, session: session)
            let frameOffset = pairedSources(screenFile: screen.file).flatMap {
                CaptureSync.screenMinusCameraSeconds(camera: $0.camera, screen: $0.screen)
            }
            let offset = try await CaptureSync.microphoneOffset(camera: cameraURL, cameraDuration: camera.sourceDuration,
                screen: screenURL, screenDuration: screen.sourceDuration, near: frameOffset)
            guard opened, !Task.isCancelled else { return }
            guard let offset else {
                problem = "The recordings don’t have a clear shared microphone signal. Adjust the camera offset to line them up."
                return
            }
            busy = false
            setCameraOffset(offset, screen: screen, camera: camera)
        } catch { if !Task.isCancelled { problem = error.localizedDescription } }
    }

    func setCameraOffset(_ offset: Double, screen: MediaEditProject.Clip, camera: MediaEditProject.Clip) {
        guard offset.isFinite, abs(offset) <= 15 else { return }
        edit { project in
            let screens = Set(project.clips.filter { $0.lane == .video && $0.file == screen.file }.map(\.id))
            for index in project.clips.indices {
                guard let link = project.clips[index].cameraLink, screens.contains(link.screen),
                      project.clips[index].file == camera.file else { continue }
                project.clips[index].cameraLink?.screenMinusCamera = offset
            }
        }
    }

    func applyCuts(_ cuts: [StudioCut], revision: String) {
        guard editable else { return }
        do {
            guard try StudioCutProposal.revision(of: project, in: session) == revision else {
                throw MediaEditProject.Failure.invalid("The timeline changed. Review a new proposal.")
            }
            let result = try project.removing(cuts)
            showTimeline()
            edit { $0 = result }
        } catch { problem = error.localizedDescription }
    }
    func removePhrase(_ phrase: StudioCut, from snapshot: MediaEditProject) {
        guard project == snapshot, editable else { return }
        do {
            let cut = StudioCut(start: phrase.start, end: phrase.end, reason: "Transcript cut")
            let result = try project.removing([cut])
            showTimeline()
            edit { $0 = result }
        } catch { problem = error.localizedDescription }
    }

    func importFiles(_ urls: [URL], startsTimeline: Bool = false) async {
        guard editable else { return }; busy = true; defer { busy = false }
        let directory = session.appending(path: "assets")
        var firstVisual: URL?
        do {
            guard directory.resolvingSymlinksInPath().path.hasPrefix(session.resolvingSymlinksInPath().path + "/") else { throw MediaEditProject.Failure.invalid("The assets folder is outside this session.") }
            _ = try MediaEditProject.directory("assets", in: session)
            for url in urls {
                guard Asset.kind(of: url) != .other, (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
                let granted = url.startAccessingSecurityScopedResource(); defer { if granted { url.stopAccessingSecurityScopedResource() } }
                let target = AssetStore.free(directory.appending(path: url.lastPathComponent))
                try await Task.detached(priority: .utility) { try FileManager.default.copyItem(at: url, to: target) }.value
                if Asset.kind(of: target) != .audio { firstVisual = firstVisual ?? target }
            }
            await scan()
            if startsTimeline, !Task.isCancelled, urls.count == 1, project.duration == 0, let firstVisual,
               let asset = assets.first(where: { $0.url.standardizedFileURL == firstVisual.standardizedFileURL }) {
                busy = false
                await add(asset)
            }
        } catch { problem = "Some files could not be imported. \(error.localizedDescription)"; await scan() }
    }
    func chooseFiles(allowed: [UTType] = [.movie, .image, .audio], startsTimeline: Bool = false) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = allowed
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.begin { [weak self] response in
            guard response == .OK else { return }
            Task { @MainActor [weak self] in await self?.importFiles(panel.urls, startsTimeline: startsTimeline) }
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
            let clips = project.timelineClips
            for clip in clips {
                guard !Task.isCancelled else { return }
                guard let url = try? MediaEditProject.source(clip.file, session: self.session) else { continue }
                if clip.kind == .video {
                    let frames = try? await TimelineMedia.thumbnails(url: url, start: clip.start, end: clip.end, imageCount: min(8, max(2, 96 / max(1, clips.count))))
                    guard !Task.isCancelled else { return }; self.strips[clip.id] = frames ?? []
                }
                if clip.kind == .video || clip.kind == .audio {
                    let samples = try? await TimelineMedia.waveform(url: url, start: clip.start, end: clip.end, sampleCount: 192)
                    guard !Task.isCancelled else { return }; self.waveforms[clip.id] = samples ?? []
                }
            }
            let ids = Set(clips.map(\.id))
            self.strips = self.strips.filter { ids.contains($0.key) }; self.waveforms = self.waveforms.filter { ids.contains($0.key) }
        }
    }
    func exportVideo(to destination: URL? = nil) {
        guard editable, project.duration > 0 else { return }
        if let destination {
            do { _ = try VideoExport.destinationURL(destination, session: session) }
            catch { problem = error.localizedDescription; return }
        }
        exported = nil; exportDestination = nil
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
                try Task.checkCancellation()
                guard folder.resolvingSymlinksInPath().path.hasPrefix(session.resolvingSymlinksInPath().path + "/") else { throw MediaEditProject.Failure.invalid("The export folder is outside this session.") }
                _ = try MediaEditProject.directory("edits", in: session)
                let final = AssetStore.free(folder.appending(path: "studio-edit.mp4"))
                try FileManager.default.moveItem(at: temporary, to: final)
                exported = final; progress = 1
                progressTask?.cancel()
                NotificationCenter.default.post(name: .cutmarkFilesChanged, object: session)
                if let destination {
                    try await Task.detached(priority: .userInitiated) { [session] in
                        try VideoExport.copy(final, to: destination, session: session)
                    }.value
                    exportDestination = destination
                }
                await scan()
            } catch { problem = Task.isCancelled ? "Export cancelled. Your edit is saved." : error.localizedDescription }
        }
    }
    func cancelExport() { exportTask?.cancel(); render?.cancelExport() }
    func close() {
        gifPreviewTask?.cancel()
        rebuild?.cancel(); thumbnailsTask?.cancel(); samplesTask?.cancel(); player.pause(); playing = false; sourcePlayer.pause()
        frameTask?.cancel(); frameGenerator?.cancelAllCGImageGeneration(); previewFrame = nil
        if let observer { player.removeTimeObserver(observer) }; observer = nil
        player.replaceCurrentItem(with: nil); sourcePlayer.replaceCurrentItem(with: nil)
        opened = false
    }
}
