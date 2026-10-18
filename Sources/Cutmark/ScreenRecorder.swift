import AVFoundation
import AppKit
import CoreGraphics
import ScreenCaptureKit

/// Converts capture host timestamps to the wall clock stored in Take.startedAt. Camera and screen
/// use this same mapping so their offset reflects media timing instead of callback latency.
enum CaptureClock {
    static func date(hostTime: Double, now: Date = Date(),
                     currentHostTime: Double = CMClockGetTime(CMClockGetHostTimeClock()).seconds) -> Date? {
        guard hostTime.isFinite, currentHostTime.isFinite else { return nil }
        return now.addingTimeInterval(hostTime - currentHostTime)
    }
}

/// A low-rate screen preview has its own observable object so new frames redraw only the thumbnail,
/// not every Record view that already observes ScreenRecorder for devices and selection.
final class ScreenPreviewFeed: ObservableObject {
    @Published fileprivate(set) var image: CGImage?
    @Published fileprivate(set) var message = "Starting screen preview…"
}

/// One selected display or app window into its own .mov (HEVC, 60fps, cursor on, mic included for waveform sync).
/// Display capture excludes Cutmark itself, so the script never shows up in the screen file.
final class ScreenRecorder: NSObject, ObservableObject, SCStreamDelegate, SCStreamOutput {
    struct Display: Identifiable, Hashable { let id: CGDirectDisplayID; let name: String }
    struct WindowIdentity: Hashable, Sendable {
        let id: CGWindowID
        let bundleIdentifier: String
        let processID: pid_t
        let title: String

        /// Titles change when a browser navigates or a document is renamed. The stable window
        /// identity is its system ID plus owner; retaining the title is useful for the picker,
        /// but comparing it would reject an otherwise valid capture after any title update.
        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.id == rhs.id && lhs.processID == rhs.processID
                && lhs.bundleIdentifier == rhs.bundleIdentifier
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(id)
            hasher.combine(processID)
            hasher.combine(bundleIdentifier)
        }
    }
    enum CaptureSource: Hashable, Sendable {
        case display(CGDirectDisplayID)
        case window(WindowIdentity)
    }
    struct Window: Identifiable, Hashable {
        let identity: WindowIdentity
        let applicationName: String
        let displayID: CGDirectDisplayID

        var id: WindowIdentity { identity }
        var source: CaptureSource { .window(identity) }
        var title: String { identity.title }
        var name: String { title.isEmpty ? applicationName : "\(applicationName) — \(title)" }
    }
    struct Start: Sendable {
        let date: Date
        /// First accepted screen-frame PTS on ScreenCaptureKit's host clock.
        let hostTime: Double
        let displayID: CGDirectDisplayID
    }

    @Published var displays: [Display] = []
    @Published private(set) var windows: [Window] = []
    @Published private(set) var selectedSource: CaptureSource?
    var selectedSourceName: String {
        switch selectedSource {
        case .display(let id):
            return displays.first(where: { $0.id == id })?.name ?? "Display"
        case .window(let identity):
            return windows.first(where: { $0.identity == identity })?.name
                ?? (identity.title.isEmpty ? "Window" : identity.title)
        case nil:
            return displays.first(where: { $0.id == displayID })?.name ?? "Display"
        }
    }
    @Published var displayID: CGDirectDisplayID? {
        didSet {
            UserDefaults.standard.set(displayID.map { Int($0) }, forKey: "display")
            guard !syncingSource else { return }
            selectedSource = displayID.map(CaptureSource.display)
            persistSelectedSource()
        }
    }
    let preview = ScreenPreviewFeed()

    private var stream: SCStream?
    private var movie: ScreenMovieWriter?
    private var startCont: CheckedContinuation<Start, Error>?
    private var stopCont: CheckedContinuation<Void, Never>?
    private let lock = NSLock()
    private let captureQueue = DispatchQueue(label: "cutmark.screen.capture", qos: .userInitiated)
    private var filler: DispatchSourceTimer?
    private var recordingDisplayID: CGDirectDisplayID?
    private var visualOriginHost: Double?
    private var lastVisualActive: Bool?
    private var visualStateSink: (@Sendable (Bool, Double) -> Void)?
    private var pendingVisualStates: [(Bool, Double)] = []
    private var previewTask: Task<Void, Never>?
    private var previewSource: CaptureSource?
    private var previewGeneration = UUID()
    private var syncingSource = false

    private static let sourceKindKey = "screenCaptureSourceKind"
    private static let sourceIDKey = "screenCaptureSourceID"
    private static let sourceBundleKey = "screenCaptureSourceBundle"
    private static let sourceProcessKey = "screenCaptureSourceProcess"
    private static let sourceTitleKey = "screenCaptureSourceTitle"

    /// A window ID and PID can both be reused after app/OS restart. Window intent survives,
    /// but never a cross-launch grant to capture that numerical ID without reselection.
    static let unconfirmedWindow = WindowIdentity(id: 0, bundleIdentifier: "", processID: 0,
                                                 title: "Choose a window")

    /// Pointer sidecars use display-global coordinates today; these must never be treated as
    /// window-local auto-zoom coordinates until the dedicated geometry mapping exists.
    static func supportsPointerEventMapping(source: CaptureSource?) -> Bool {
        if case .window? = source { return false }
        return true
    }

    override init() {
        let defaults = UserDefaults.standard
        let savedDisplay = defaults.integer(forKey: "display")
        let legacyDisplay = savedDisplay == 0 ? nil : CGDirectDisplayID(savedDisplay)
        displayID = legacyDisplay
        switch defaults.string(forKey: Self.sourceKindKey) {
        case "display":
            let raw = defaults.integer(forKey: Self.sourceIDKey)
            selectedSource = raw == 0 ? legacyDisplay.map(CaptureSource.display) : .display(CGDirectDisplayID(raw))
        case "window":
            // Never restore a capture-capable window ID across launches; make the prior intent
            // explicit instead of falling back to a whole-display recording.
            selectedSource = .window(Self.unconfirmedWindow)
        default:
            selectedSource = legacyDisplay.map(CaptureSource.display)
        }
        super.init()
    }

    /// Ask for Screen Recording permission before the camera wakes up or the countdown begins.
    /// Without this preflight, a denied permission only surfaced after "3, 2, 1", which made a
    /// failed take look like a recorder failure instead of a macOS privacy setting.
    @MainActor
    static func ensureCapturePermission() -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        return CGRequestScreenCaptureAccess()
    }

    @MainActor
    func selectSource(_ source: CaptureSource) {
        selectedSource = source
        syncingSource = true
        switch source {
        case .display(let id):
            displayID = id
        case .window(let identity):
            displayID = windows.first(where: { $0.identity == identity })?.displayID
        }
        syncingSource = false
        persistSelectedSource()
    }

    @MainActor
    func refreshCaptureSources(requestPermission: Bool = false) async {
        refreshDisplays()
        let allowed = CGPreflightScreenCaptureAccess() || (requestPermission && CGRequestScreenCaptureAccess())
        guard allowed else {
            windows = []
            return
        }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            windows = Self.captureWindows(from: content)
            if case .window(let identity) = selectedSource,
               let window = windows.first(where: { $0.identity == identity }) {
                syncingSource = true
                displayID = window.displayID
                syncingSource = false
            }
        } catch {
            windows = []
        }
    }

    private func persistSelectedSource() {
        let defaults = UserDefaults.standard
        switch selectedSource {
        case .display(let id):
            defaults.set("display", forKey: Self.sourceKindKey)
            defaults.set(Int(id), forKey: Self.sourceIDKey)
            defaults.removeObject(forKey: Self.sourceBundleKey)
            defaults.removeObject(forKey: Self.sourceProcessKey)
            defaults.removeObject(forKey: Self.sourceTitleKey)
        case .window:
            defaults.set("window", forKey: Self.sourceKindKey)
            // A window selection is valid only for this process lifetime. Persist type, never
            // its reusable numeric identity; the picker will ask for a new window next launch.
            defaults.removeObject(forKey: Self.sourceIDKey)
            defaults.removeObject(forKey: Self.sourceBundleKey)
            defaults.removeObject(forKey: Self.sourceProcessKey)
            defaults.removeObject(forKey: Self.sourceTitleKey)
        case nil:
            defaults.removeObject(forKey: Self.sourceKindKey)
            defaults.removeObject(forKey: Self.sourceIDKey)
            defaults.removeObject(forKey: Self.sourceBundleKey)
            defaults.removeObject(forKey: Self.sourceProcessKey)
            defaults.removeObject(forKey: Self.sourceTitleKey)
        }
    }

    @MainActor
    func refreshDisplays() {
        let found = NSScreen.screens.compactMap { s -> Display? in
            guard let n = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            return Display(id: CGDirectDisplayID(n.uint32Value), name: s.localizedName)
        }
        // Runs on every ⌘-Tab back: an equal list must not redraw the stage.
        if found != displays { displays = found }
        // A disconnected selected display is not permission to record a different one.
        // Only choose the first display if the user has never selected one.
        if selectedSource == nil, displayID == nil, let first = displays.first {
            selectSource(.display(first.id))
        }
    }

    /// A one-shot viewfinder while Record is idle. It uses the same source/filter as the real
    /// recording, then releases capture resources. Record also cancels an in-flight preview before
    /// capture starts, so a screenshot request never competes with the take.
    @MainActor
    func setPreviewing(_ on: Bool, requestPermission: Bool = false) {
        guard on else {
            previewTask?.cancel()
            previewTask = nil
            previewSource = nil
            previewGeneration = UUID()
            preview.image = nil
            preview.message = "Starting screen preview…"
            return
        }

        let allowed = CGPreflightScreenCaptureAccess() || (requestPermission && CGRequestScreenCaptureAccess())
        guard allowed else {
            previewTask?.cancel()
            previewTask = nil
            previewSource = nil
            previewGeneration = UUID()
            preview.image = nil
            preview.message = "Allow Screen Recording to see the preview."
            return
        }

        let wantedSource = selectedSource ?? displayID.map(CaptureSource.display)
        // A normal view update can ask again while the one-shot preview is still being captured.
        if previewTask != nil, previewSource == wantedSource { return }
        previewTask?.cancel()
        previewGeneration = UUID()
        let generation = previewGeneration
        previewSource = wantedSource
        preview.image = nil
        preview.message = "Starting screen preview…"
        previewTask = Task { @MainActor [weak self] in
            await self?.runPreview(source: wantedSource, generation: generation)
        }
    }

    static func previewSize(contentRect: CGRect, scale: CGFloat, maxWidth: Int = 640) -> (width: Int, height: Int) {
        let pixelWidth = max(1, contentRect.width * max(0.1, scale))
        let pixelHeight = max(1, contentRect.height * max(0.1, scale))
        let width = min(pixelWidth, CGFloat(max(1, maxWidth)))
        let ratio = width / pixelWidth
        return (max(1, Int(width.rounded())), max(1, Int((pixelHeight * ratio).rounded())))
    }

    /// An explicit source can disappear between refresh and capture. Never substitute another
    /// display/window for that choice; an unset source may use the primary available display.
    static func captureDisplayID(selected: CGDirectDisplayID?, available: [CGDirectDisplayID]) -> CGDirectDisplayID? {
        guard let selected else { return available.first }
        return available.contains(selected) ? selected : nil
    }

    static func captureSource(selected: CaptureSource?, availableDisplays: [CGDirectDisplayID],
                              availableWindows: [WindowIdentity]) -> CaptureSource? {
        guard let selected else { return availableDisplays.first.map(CaptureSource.display) }
        switch selected {
        case .display(let id):
            return availableDisplays.contains(id) ? selected : nil
        case .window(let identity):
            return availableWindows.contains(identity) ? selected : nil
        }
    }

    static func hostDisplayID(windowFrame: CGRect,
                              displayFrames: [(CGDirectDisplayID, CGRect)]) -> CGDirectDisplayID? {
        var best: (id: CGDirectDisplayID, area: CGFloat)?
        for (id, frame) in displayFrames {
            let overlap = windowFrame.intersection(frame)
            guard !overlap.isNull, !overlap.isEmpty else { continue }
            let area = overlap.width * overlap.height
            if best == nil || area > best!.area { best = (id, area) }
        }
        return best?.id
    }

    private struct ResolvedCapture {
        let filter: SCContentFilter
        let displayID: CGDirectDisplayID
    }

    private static func windowIdentity(_ window: SCWindow) -> WindowIdentity? {
        guard let app = window.owningApplication else { return nil }
        return WindowIdentity(id: window.windowID,
                              bundleIdentifier: app.bundleIdentifier,
                              processID: app.processID,
                              title: window.title ?? "")
    }

    private static func captureWindows(from content: SCShareableContent) -> [Window] {
        let ownProcess = pid_t(ProcessInfo.processInfo.processIdentifier)
        // SCWindow.frame and SCDisplay.frame share ScreenCaptureKit's global coordinate space.
        // CGDisplayBounds uses a different origin for some rotated/stacked displays.
        let displayFrames = content.displays.map { ($0.displayID, $0.frame) }
        return content.windows.compactMap { window -> Window? in
            guard window.windowLayer == 0, window.frame.width > 1, window.frame.height > 1,
                  let app = window.owningApplication, app.processID != ownProcess,
                  let identity = windowIdentity(window),
                  let displayID = hostDisplayID(windowFrame: window.frame, displayFrames: displayFrames)
            else { return nil }
            return Window(identity: identity, applicationName: app.applicationName, displayID: displayID)
        }.sorted {
            if $0.applicationName != $1.applicationName { return $0.applicationName.localizedCaseInsensitiveCompare($1.applicationName) == .orderedAscending }
            if $0.title != $1.title { return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
            return $0.identity.id < $1.identity.id
        }
    }

    private static func resolveCapture(source: CaptureSource?, content: SCShareableContent) throws -> ResolvedCapture {
        let listedWindows = captureWindows(from: content)
        let selected = captureSource(selected: source,
                                     availableDisplays: content.displays.map(\.displayID),
                                     availableWindows: listedWindows.map(\.identity))
        guard let selected else {
            switch source {
            case .display:
                throw RecorderError("Selected display is unavailable. Choose another screen.")
            case .window:
                throw RecorderError("Selected window is unavailable. Choose it again.")
            case nil:
                throw RecorderError("No display found.")
            }
        }

        switch selected {
        case .display(let id):
            guard let display = content.displays.first(where: { $0.displayID == id }) else {
                throw RecorderError("Selected display is unavailable. Choose another screen.")
            }
            let ownProcess = pid_t(ProcessInfo.processInfo.processIdentifier)
            let me = content.applications.filter { $0.processID == ownProcess }
            return ResolvedCapture(filter: SCContentFilter(display: display, excludingApplications: me, exceptingWindows: []),
                                   displayID: id)
        case .window(let identity):
            guard let window = content.windows.first(where: { windowIdentity($0) == identity }),
                  let listed = listedWindows.first(where: { $0.identity == identity }) else {
                throw RecorderError("Selected window is unavailable. Choose it again.")
            }
            return ResolvedCapture(filter: SCContentFilter(desktopIndependentWindow: window),
                                   displayID: listed.displayID)
        }
    }

    @MainActor
    private func runPreview(source: CaptureSource?, generation: UUID) async {
        defer {
            // An older cancelled request must not clear its replacement's task.
            if previewGeneration == generation {
                previewTask = nil
                previewSource = nil
            }
        }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard !Task.isCancelled else { return }
            windows = Self.captureWindows(from: content)
            let resolved = try Self.resolveCapture(source: source, content: content)
            let filter = resolved.filter
            let size = Self.previewSize(contentRect: filter.contentRect, scale: CGFloat(filter.pointPixelScale))
            let config = SCStreamConfiguration()
            config.width = size.width
            config.height = size.height
            config.showsCursor = true
            config.pixelFormat = kCVPixelFormatType_32BGRA
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            guard !Task.isCancelled else { return }
            preview.image = image
            preview.message = ""
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            preview.image = nil
            preview.message = (error as? LocalizedError)?.errorDescription ?? "Screen preview unavailable."
        }
    }

    func startRecording(to url: URL, micID: String?) async throws -> Start {
        try Task.checkCancellation()
        // AppModel normally stops the viewfinder when phase leaves idle. Also stop it here so a
        // delayed SwiftUI update can never leave a screenshot request overlapping the real stream.
        await MainActor.run { self.setPreviewing(false) }
        let source = selectedSource ?? displayID.map(CaptureSource.display)
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let resolved = try Self.resolveCapture(source: source, content: content)
        let filter = resolved.filter

        let config = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        config.width = max(2, Int((filter.contentRect.width * scale).rounded()))
        config.height = max(2, Int((filter.contentRect.height * scale).rounded()))
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.showsCursor = true
        config.queueDepth = 6
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.capturesAudio = false
        if let micID {
            config.captureMicrophone = true
            config.microphoneCaptureDeviceID = micID
        }

        let movie = try ScreenMovieWriter(url: url, width: config.width, height: config.height, microphone: micID != nil)
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: captureQueue)
        if micID != nil { try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: captureQueue) }
        self.movie = movie
        self.stream = stream
        recordingDisplayID = resolved.displayID
        visualOriginHost = nil
        lastVisualActive = nil
        pendingVisualStates.removeAll(keepingCapacity: true)
        visualStateSink = nil
        startFiller()
        try Task.checkCancellation()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Start, Error>) in
                lock.withLock { startCont = cont }
                stream.startCapture { [weak self] error in
                    if let error {
                        self?.captureQueue.async { [weak self] in self?.movie?.cancel() }
                        self?.resumeStart(.failure(error))
                        return
                    }
                    // A stream that starts without producing a frame is not a recording. Do not invent a
                    // start time: AppModel will stop both recorders and keep the recovery claim coherent.
                    DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
                        self?.resumeStart(.failure(RecorderError("Screen recording did not receive a frame.")))
                    }
                }
            }
        }, onCancel: {
            self.cancelStart()
        })
    }

    func stopRecording() async {
        guard let stream else { return }
        await withCheckedContinuation { cont in
            lock.withLock { stopCont = cont }
            stream.stopCapture { [weak self] _ in
                self?.finishMovie()
            }
            // Same safety net the old SCRecordingOutput path had: a stuck ScreenCaptureKit stop must
            // not strand the camera/propmter in Finishing. ScreenMovieWriter.finish is idempotent.
            DispatchQueue.global().asyncAfter(deadline: .now() + 6) { [weak self] in self?.finishMovie() }
        }
        self.stream = nil
        recordingDisplayID = nil
        filler?.cancel()
        filler = nil
        self.movie = nil
        visualOriginHost = nil
        lastVisualActive = nil
        pendingVisualStates.removeAll(keepingCapacity: false)
        visualStateSink = nil
    }

    /// Attach the current take's event recorder after the first real screen frame establishes the media
    /// clock. Transitions seen in the short setup gap are buffered and flushed in order.
    func setVisualStateSink(_ sink: (@Sendable (Bool, Double) -> Void)?) {
        captureQueue.async { [weak self] in
            guard let self else { return }
            visualStateSink = sink
            guard let sink else {
                pendingVisualStates.removeAll(keepingCapacity: false)
                return
            }
            for (active, pts) in pendingVisualStates { sink(active, pts) }
            pendingVisualStates.removeAll(keepingCapacity: true)
        }
    }

    /// Gives up on a start that has not begun yet (Record pressed again while "Starting…").
    func cancelStart() { resumeStart(.failure(CancellationError())) }

    private func resumeStart(_ r: Result<Start, Error>) {
        let c = lock.withLock { () -> CheckedContinuation<Start, Error>? in defer { startCont = nil }; return startCont }
        c?.resume(with: r)
    }

    private func resumeStop() {
        let c = lock.withLock { () -> CheckedContinuation<Void, Never>? in defer { stopCont = nil }; return stopCont }
        c?.resume()
    }

    private func finishMovie() {
        // Both SCStream outputs use this serial queue. Enqueuing finish here means every
        // screen/microphone sample already delivered before stop is appended first.
        captureQueue.async { [weak self] in
            guard let self else { return }
            guard let movie = self.movie else { self.resumeStop(); return }
            movie.finish { [weak self] in self?.resumeStop() }
        }
    }

    private func startFiller() {
        filler?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: captureQueue)
        timer.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(50))
        timer.setEventHandler { [weak self] in
            guard let self, let movie = self.movie else { return }
            if let started = try? movie.appendFiller(at: CMClockGetTime(CMClockGetHostTimeClock())) {
                self.noteStarted(started)
            }
        }
        timer.resume()
        filler = timer
    }

    private func noteStarted(_ started: (date: Date, hostTime: Double)?) {
        guard let started else { return }
        visualOriginHost = started.hostTime
        if let displayID = recordingDisplayID {
            resumeStart(.success(Start(date: started.date, hostTime: started.hostTime, displayID: displayID)))
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard let movie else { return }
        do {
            switch type {
            case .screen:
                switch Self.frameStatus(sampleBuffer) {
                case .complete:
                    let started = try movie.appendScreen(sampleBuffer)
                    noteStarted(started)
                    noteVisualState(active: true, at: sampleBuffer.presentationTimeStamp)
                case .idle:
                    noteStarted(try movie.appendFiller(at: sampleBuffer.presentationTimeStamp))
                    noteVisualState(active: false, at: sampleBuffer.presentationTimeStamp)
                default:
                    break
                }
            case .microphone:
                try movie.appendMicrophone(sampleBuffer)
            default:
                break
            }
        } catch {
            resumeStart(.failure(error))
        }
    }

    static func frameStatus(_ sampleBuffer: CMSampleBuffer) -> SCFrameStatus? {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int else { return nil }
        return SCFrameStatus(rawValue: raw)
    }

    private func noteVisualState(active: Bool, at pts: CMTime) {
        guard visualOriginHost != nil, pts.isNumeric, lastVisualActive != active else { return }
        lastVisualActive = active
        let seconds = pts.seconds
        if let visualStateSink {
            visualStateSink(active, seconds)
        } else {
            pendingVisualStates.append((active, seconds))
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        resumeStart(.failure(error))
        // Keep the last completed movie fragments. A spontaneous stream failure must finalize the
        // writer before stopRecording can tell AppModel the screen side is finished.
        finishMovie()
    }
}

/// Writes ScreenCaptureKit's screen and microphone sample buffers straight into the same fragmented
/// QuickTime movie Cutmark has always used. AVFoundation documents that a partially written fragmented
/// movie remains playable through its last completed fragment after an unexpected interruption.
/// Nothing here changes the session/take format: the result is still take-XX-screen.mov.
final class ScreenMovieWriter {
    static let fragmentSeconds: Double = 2
    static let frameRate = 60

    static func videoSettings(width: Int, height: Int) -> [String: Any] {
        [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoExpectedSourceFrameRateKey: frameRate,
                // A fragment is useful for crash recovery once a sync frame starts the next one.
                // Keep a sync frame available at least every fragment interval.
                AVVideoMaxKeyFrameIntervalDurationKey: fragmentSeconds,
            ],
        ]
    }

    static let microphoneSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: 48_000,
        AVNumberOfChannelsKey: 1,
        AVEncoderBitRateKey: 128_000,
    ]

    static func isNewerVideoPTS(_ pts: CMTime, than last: CMTime?) -> Bool {
        guard pts.isNumeric else { return false }
        guard let last else { return true }
        return CMTimeCompare(pts, last) > 0
    }

    private let writer: AVAssetWriter
    private let video: AVAssetWriterInput
    private let videoBuffers: AVAssetWriterInputPixelBufferAdaptor
    private let microphone: AVAssetWriterInput?
    private let finishLock = NSLock()
    private var started = false
    private var finishing = false
    private var finished = false
    private var finishCallbacks: [() -> Void] = []
    private var startPTS: CMTime?
    private var lastVideoPTS: CMTime?
    private var lastPixelBuffer: CVPixelBuffer?

    init(url: URL, width: Int, height: Int, microphone: Bool) throws {
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        writer.movieFragmentInterval = CMTime(seconds: Self.fragmentSeconds, preferredTimescale: 600)

        let video = AVAssetWriterInput(mediaType: .video, outputSettings: Self.videoSettings(width: width, height: height))
        video.expectsMediaDataInRealTime = true
        guard writer.canAdd(video) else { throw RecorderError("Screen video encoder is unavailable.") }
        writer.add(video)
        self.video = video
        videoBuffers = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: nil)

        if microphone {
            let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: Self.microphoneSettings)
            audio.expectsMediaDataInRealTime = true
            guard writer.canAdd(audio) else { throw RecorderError("Screen microphone encoder is unavailable.") }
            writer.add(audio)
            self.microphone = audio
        } else {
            self.microphone = nil
        }
    }

    /// Returns both clocks once, for the first screen buffer that actually enters the movie. The PTS
    /// is the canonical source origin for input events; Date remains metadata for camera/screen sync.
    func appendScreen(_ sampleBuffer: CMSampleBuffer) throws -> (date: Date, hostTime: Double)? {
        guard sampleBuffer.isValid, CMSampleBufferDataIsReady(sampleBuffer), let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return nil }
        let pts = sampleBuffer.presentationTimeStamp
        guard pts.isNumeric else { return nil }
        if !started {
            guard writer.startWriting() else { throw failure("Screen recording could not start") }
            writer.startSession(atSourceTime: pts)
            startPTS = pts
            started = true
        }
        guard !isFinishing else { return nil }
        // A synthetic filler can run before a delayed SCStream callback. Keep the delayed frame as
        // the picture for future filler, but never feed AVAssetWriter a PTS at or behind one already
        // appended: AVAssetWriter may accept that append and only fail later at finishWriting().
        lastPixelBuffer = pixelBuffer
        guard Self.isNewerVideoPTS(pts, than: lastVideoPTS), video.isReadyForMoreMediaData else { return nil }
        guard videoBuffers.append(pixelBuffer, withPresentationTime: pts) else {
            if writer.status == .failed { throw failure("Screen video encoder stopped") }
            return nil
        }
        let first = lastVideoPTS == nil
        lastVideoPTS = pts
        guard first, let date = CaptureClock.date(hostTime: pts.seconds) else { return nil }
        return (date, pts.seconds)
    }

    /// Advance a static screen with the last picture. This keeps the video aligned with the mic and
    /// gives AVAssetWriter samples from which it can close its ~2 s movie fragments.
    func appendFiller(at pts: CMTime) throws -> (date: Date, hostTime: Double)? {
        guard started, !isFinishing, pts.isNumeric, let lastPixelBuffer else { return nil }
        if let lastVideoPTS, CMTimeCompare(pts, lastVideoPTS + CMTime(seconds: 0.75, preferredTimescale: 600)) <= 0 { return nil }
        guard video.isReadyForMoreMediaData else { return nil }
        guard videoBuffers.append(lastPixelBuffer, withPresentationTime: pts) else {
            if writer.status == .failed { throw failure("Screen video encoder stopped") }
            return nil
        }
        let first = lastVideoPTS == nil
        lastVideoPTS = pts
        guard first, let date = CaptureClock.date(hostTime: pts.seconds) else { return nil }
        return (date, pts.seconds)
    }

    func appendMicrophone(_ sampleBuffer: CMSampleBuffer) throws {
        guard started, !isFinishing, let microphone,
              sampleBuffer.isValid, CMSampleBufferDataIsReady(sampleBuffer) else { return }
        let pts = sampleBuffer.presentationTimeStamp
        guard pts.isNumeric, let startPTS, pts >= startPTS else { return }
        if microphone.isReadyForMoreMediaData, !microphone.append(sampleBuffer), writer.status == .failed {
            throw failure("Screen microphone encoder stopped")
        }
    }

    func finish(_ done: @escaping () -> Void) {
        let state = finishLock.withLock { () -> Int in
            if finished { return 0 }
            finishCallbacks.append(done)
            guard !finishing else { return 1 }
            finishing = true
            return 2
        }
        if state == 0 { done(); return }
        guard state == 2 else { return }
        guard started else { writer.cancelWriting(); completeFinish(); return }
        // A static screen may not have emitted a complete frame near Stop. Extend its last picture to
        // the current host time before closing, matching the microphone's real recording duration.
        try? appendFillerBeforeFinish(at: CMClockGetTime(CMClockGetHostTimeClock()))
        video.markAsFinished()
        microphone?.markAsFinished()
        writer.finishWriting { [weak self] in self?.completeFinish() }
    }

    func cancel() {
        let shouldCancel = finishLock.withLock { () -> Bool in
            guard !finishing else { return false }
            finishing = true
            return true
        }
        guard shouldCancel else { return }
        writer.cancelWriting()
        completeFinish()
    }

    private var isFinishing: Bool { finishLock.withLock { finishing } }

    private func appendFillerBeforeFinish(at pts: CMTime) throws {
        guard pts.isNumeric, let lastPixelBuffer, video.isReadyForMoreMediaData else { return }
        if let lastVideoPTS, CMTimeCompare(pts, lastVideoPTS) <= 0 { return }
        if !videoBuffers.append(lastPixelBuffer, withPresentationTime: pts), writer.status == .failed {
            throw failure("Screen video encoder stopped")
        }
        lastVideoPTS = pts
    }

    private func completeFinish() {
        let callbacks = finishLock.withLock { () -> [() -> Void] in
            finished = true
            defer { finishCallbacks.removeAll() }
            return finishCallbacks
        }
        callbacks.forEach { $0() }
    }

    private func failure(_ prefix: String) -> RecorderError {
        RecorderError("\(prefix): \(writer.error?.localizedDescription ?? "unknown error").")
    }
}
