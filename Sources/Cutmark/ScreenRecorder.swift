import AVFoundation
import AppKit
import ScreenCaptureKit

/// One display into its own .mov (HEVC, 60fps, cursor on, mic included for waveform sync).
/// The Cutmark window itself is excluded, so the script never shows up in the screen file.
final class ScreenRecorder: NSObject, ObservableObject, SCStreamDelegate, SCStreamOutput {
    struct Display: Identifiable, Hashable { let id: CGDirectDisplayID; let name: String }

    @Published var displays: [Display] = []
    @Published var displayID: CGDirectDisplayID? {
        didSet { UserDefaults.standard.set(displayID.map { Int($0) }, forKey: "display") }
    }

    private var stream: SCStream?
    private var movie: ScreenMovieWriter?
    private var startCont: CheckedContinuation<Date, Error>?
    private var stopCont: CheckedContinuation<Void, Never>?
    private let lock = NSLock()
    private let captureQueue = DispatchQueue(label: "cutmark.screen.capture", qos: .userInitiated)
    private var filler: DispatchSourceTimer?

    override init() {
        super.init()
        let saved = UserDefaults.standard.integer(forKey: "display")
        displayID = saved == 0 ? nil : CGDirectDisplayID(saved)
    }

    @MainActor
    func refreshDisplays() {
        let found = NSScreen.screens.compactMap { s -> Display? in
            guard let n = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            return Display(id: CGDirectDisplayID(n.uint32Value), name: s.localizedName)
        }
        // Runs on every ⌘-Tab back: an equal list must not redraw the stage.
        if found != displays { displays = found }
        if !displays.contains(where: { $0.id == displayID }) { displayID = displays.first?.id }
    }

    func startRecording(to url: URL, micID: String?) async throws -> Date {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) ?? content.displays.first
        else { throw RecorderError("No display found.") }
        let me = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: me, exceptingWindows: [])

        let config = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        config.width = Int(filter.contentRect.width * scale)
        config.height = Int(filter.contentRect.height * scale)
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
        startFiller()
        return try await withCheckedThrowingContinuation { cont in
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
        filler?.cancel()
        filler = nil
        self.movie = nil
    }

    /// Gives up on a start that has not begun yet (Record pressed again while "Starting…").
    func cancelStart() { resumeStart(.failure(CancellationError())) }

    private func resumeStart(_ r: Result<Date, Error>) {
        let c = lock.withLock { () -> CheckedContinuation<Date, Error>? in defer { startCont = nil }; return startCont }
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
            guard let movie = self?.movie else { return }
            try? movie.appendFiller(at: CMClockGetTime(CMClockGetHostTimeClock()))
        }
        timer.resume()
        filler = timer
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard let movie else { return }
        do {
            switch type {
            case .screen:
                switch Self.frameStatus(sampleBuffer) {
                case .complete:
                    if let started = try movie.appendScreen(sampleBuffer) { resumeStart(.success(started)) }
                case .idle:
                    try movie.appendFiller(at: sampleBuffer.presentationTimeStamp)
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

    /// Returns the wall-clock start once, when the first real screen frame starts the movie.
    func appendScreen(_ sampleBuffer: CMSampleBuffer) throws -> Date? {
        guard sampleBuffer.isValid, CMSampleBufferDataIsReady(sampleBuffer), let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return nil }
        let pts = sampleBuffer.presentationTimeStamp
        guard pts.isNumeric else { return nil }
        var began: Date?
        if !started {
            guard writer.startWriting() else { throw failure("Screen recording could not start") }
            writer.startSession(atSourceTime: pts)
            startPTS = pts
            started = true
            began = Date()
        }
        guard !isFinishing else { return began }
        // A synthetic filler can run before a delayed SCStream callback. Keep the delayed frame as
        // the picture for future filler, but never feed AVAssetWriter a PTS at or behind one already
        // appended: AVAssetWriter may accept that append and only fail later at finishWriting().
        lastPixelBuffer = pixelBuffer
        guard Self.isNewerVideoPTS(pts, than: lastVideoPTS) else { return began }
        if video.isReadyForMoreMediaData {
            if !videoBuffers.append(pixelBuffer, withPresentationTime: pts), writer.status == .failed {
                throw failure("Screen video encoder stopped")
            }
            lastVideoPTS = pts
        }
        return began
    }

    /// Advance a static screen with the last picture. This keeps the video aligned with the mic and
    /// gives AVAssetWriter samples from which it can close its ~2 s movie fragments.
    func appendFiller(at pts: CMTime) throws {
        guard started, !isFinishing, pts.isNumeric, let lastPixelBuffer else { return }
        if let lastVideoPTS, CMTimeCompare(pts, lastVideoPTS + CMTime(seconds: 0.75, preferredTimescale: 600)) <= 0 { return }
        guard video.isReadyForMoreMediaData else { return }
        if !videoBuffers.append(lastPixelBuffer, withPresentationTime: pts), writer.status == .failed {
            throw failure("Screen video encoder stopped")
        }
        lastVideoPTS = pts
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
