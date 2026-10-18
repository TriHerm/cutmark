import AVFoundation
import Combine

/// Mic level in its own object: views that watch the camera do not redraw 12 times a second.
final class MicMeter: ObservableObject {
    @Published var level: Float = 0  // 0...1
}

enum Orientation: String, CaseIterable, Identifiable {
    case horizontal = "16:9", vertical = "9:16"
    var id: String { rawValue }
}

/// Camera + mic into one .mov (HEVC). Owns the preview session.
///
/// Vertical: if the camera has a native portrait format (MacBook camera does), use it. The iPhone
/// (Continuity Camera) only sends landscape frames. Held upright, its frames lie on their side:
/// the take is turned upright (a transform in the file) and keeps 1080 real pixels across. Held
/// sideways, the encoder center-crops the tallest landscape format to 1080x1920 (about 810 real
/// pixels across, scaled up). No extra CPU pass either way.
///
/// Video is HEVC at a set bitrate: the encoder's default (about 7 Mbit/s at 1080p) lost detail
/// that each edit then lost again (2026-10-01).
final class CameraRecorder: NSObject, ObservableObject, AVCaptureFileOutputRecordingDelegate {
    struct Start: Sendable {
        enum Timing: Sendable { case videoFrame, callback }
        let date: Date
        /// Host-clock time established according to `timing`.
        let hostTime: Double
        let timing: Timing
    }

    /// Pairs the movie's first-written-buffer PTS with the first camera video sample at or after it.
    /// VideoDataOutput and MovieFileOutput timestamps share AVCaptureSession.synchronizationClock.
    struct VideoStartGate {
        private(set) var activationPTS: CMTime?
        private(set) var movieStartPTS: CMTime?
        private var videoPTS: [CMTime] = []

        var isArmed: Bool { activationPTS != nil }

        mutating func arm(at activationPTS: CMTime) {
            reset()
            guard activationPTS.isNumeric else { return }
            self.activationPTS = activationPTS
        }

        mutating func noteVideo(_ pts: CMTime) -> CMTime? {
            guard let activationPTS, pts.isNumeric,
                  CMTimeCompare(pts, activationPTS) >= 0 else { return nil }
            videoPTS.append(pts)
            return resolve()
        }

        mutating func noteMovieStart(_ pts: CMTime) -> CMTime? {
            guard isArmed, pts.isNumeric else { return nil }
            movieStartPTS = pts
            return resolve()
        }

        mutating func reset() {
            activationPTS = nil
            movieStartPTS = nil
            videoPTS.removeAll(keepingCapacity: true)
        }

        private mutating func resolve() -> CMTime? {
            guard let activationPTS, let movieStartPTS else { return nil }
            let threshold = CMTimeCompare(activationPTS, movieStartPTS) >= 0 ? activationPTS : movieStartPTS
            guard let first = videoPTS.filter({ CMTimeCompare($0, threshold) >= 0 })
                .min(by: { CMTimeCompare($0, $1) < 0 }) else { return nil }
            reset()
            return first
        }
    }

    /// Keeps VideoDataOutput's callback off the camera/session queue. It copies only the timestamp;
    /// no pixel buffer survives the callback, so observing start timing cannot build a frame backlog.
    private final class VideoPTSProbe: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
        let receive: (CMTime) -> Void
        init(receive: @escaping (CMTime) -> Void) { self.receive = receive }
        func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                           from connection: AVCaptureConnection) {
            let pts = sampleBuffer.presentationTimeStamp
            if pts.isNumeric { receive(pts) }
        }
    }
    let session = AVCaptureSession()
    @Published var videoDevices: [AVCaptureDevice] = []
    @Published var audioDevices: [AVCaptureDevice] = []
    /// What is active now. Set through chooseVideo/chooseAudio from the UI so the choice is remembered.
    @Published private(set) var videoID: String? { didSet { if videoID != oldValue { persistAndConfigure() } } }
    @Published private(set) var audioID: String? { didSet { if audioID != oldValue { persistAndConfigure() } } }
    /// What you picked last. Kept even while that device is unplugged, and switched back to when it
    /// reappears (the iPhone and wireless mics often connect a few seconds after launch).
    private var preferredVideo = UserDefaults.standard.string(forKey: "video")
    private var preferredAudio = UserDefaults.standard.string(forKey: "audio")
    @Published var orientation: Orientation = .horizontal {
        didSet { if orientation != oldValue { persistAndConfigure() } }
    }
    let meter = MicMeter()
    @Published var permissionProblem: String?
    /// True when the device frames are landscape but we record vertical (preview must crop too).
    @Published private(set) var previewCropsToVertical = false
    /// Degrees the preview turns so an upright iPhone shows upright (0, 90 or 270).
    @Published private(set) var previewRotation: CGFloat = 0
    @Published private(set) var formatDescription = ""
    /// Camera and mic off (light off) until you turn them back on or hit Record.
    /// The app opens this way: the camera costs the most, and you often open it only to review.
    @Published private(set) var paused = true
    /// Off because nothing shows it: a file plays over it, or the window is hidden. Not your choice,
    /// so the UI still says "live". It comes back by itself.
    private(set) var held = false
    /// Whether the session runs now (main thread's view of it).
    private var live = false

    /// Every session call runs here. A preview layer also lets go of the session here (see PreviewView).
    static let queue = DispatchQueue(label: "cutmark.camera")
    private var queue: DispatchQueue { Self.queue }
    private let timingQueue = DispatchQueue(label: "cutmark.camera.video-timing", qos: .userInitiated)
    private let output = AVCaptureMovieFileOutput()
    /// Timestamp-only tap. It never writes another file and drops late frames rather than buffering.
    private let timingOutput = AVCaptureVideoDataOutput()
    private var videoInput: AVCaptureDeviceInput?
    private var audioInput: AVCaptureDeviceInput?
    private var startCont: CheckedContinuation<Start, Error>?
    private var stopCont: CheckedContinuation<Void, Never>?
    private var videoStartGate = VideoStartGate()
    private var videoTimingGeneration = 0
    private var videoTimingProbe: VideoPTSProbe?
    private var levelTimer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var ready = false
    /// Which way up the camera is (an iPhone can be turned while Cutmark runs).
    private var rotation: AVCaptureDevice.RotationCoordinator?
    private var rotationWatch: NSKeyValueObservation?

    /// HEVC bitrate for a 1080p take (bits per second). Scaled by pixel count for other sizes.
    static let bitrate1080 = 20_000_000
    /// Keep the movie recoverable in short pieces if Cutmark or macOS stops during a take. The
    /// AVCaptureMovieFileOutput default is much longer; two seconds bounds the unfinished tail while
    /// preserving the same final .mov file and the existing prompter/camera pipeline.
    static let fragmentSeconds: Double = 2

    override init() {
        super.init()
        output.movieFragmentInterval = CMTime(seconds: Self.fragmentSeconds, preferredTimescale: 600)
        timingOutput.alwaysDiscardsLateVideoFrames = true
        let d = UserDefaults.standard
        orientation = Orientation(rawValue: d.string(forKey: "orientation") ?? "") ?? .horizontal
        for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) {
                [weak self] _ in self?.refreshDevices()
            })
        }
    }

    func boot() async {
        let cam = await AVCaptureDevice.requestAccess(for: .video)
        let mic = await AVCaptureDevice.requestAccess(for: .audio)
        await MainActor.run {
            if !cam || !mic {
                permissionProblem = "Allow \(!cam ? "Camera" : "")\(!cam && !mic ? " and " : "")\(!mic ? "Microphone" : "") in System Settings → Privacy & Security."
            }
            ready = true
            refreshDevices()
            configure()
            apply()
        }
    }

    func refreshDevices() {
        videoDevices = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .continuityCamera, .external, .deskViewCamera],
            mediaType: .video, position: .unspecified).devices
        audioDevices = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified).devices
        if output.isRecording { return }
        if let p = preferredVideo, videoDevices.contains(where: { $0.uniqueID == p }) {
            videoID = p
        } else if !videoDevices.contains(where: { $0.uniqueID == videoID }) {
            videoID = AVCaptureDevice.default(for: .video)?.uniqueID ?? videoDevices.first?.uniqueID
        }
        if let p = preferredAudio, audioDevices.contains(where: { $0.uniqueID == p }) {
            audioID = p
        } else if !audioDevices.contains(where: { $0.uniqueID == audioID }) {
            audioID = AVCaptureDevice.default(for: .audio)?.uniqueID ?? audioDevices.first?.uniqueID
        }
    }

    func chooseVideo(_ id: String?) {
        preferredVideo = id
        UserDefaults.standard.set(id, forKey: "video")
        videoID = id
    }

    func chooseAudio(_ id: String?) {
        preferredAudio = id
        UserDefaults.standard.set(id, forKey: "audio")
        audioID = id
    }

    private func persistAndConfigure() {
        UserDefaults.standard.set(orientation.rawValue, forKey: "orientation")
        if ready { configure() }
    }

    struct Plan {
        let format: AVCaptureDevice.Format
        /// The size the encoder writes, in the camera's frame (before `rotate`). Nil: the format's.
        let size: CMVideoDimensions?
        /// Degrees the take is turned in the file (0, 90 or 270).
        let rotate: CGFloat
        let label: String
    }

    /// `upright`: the angle that turns the camera's frames upright (90 or 270 for an iPhone held
    /// upright, 0 when held sideways).
    static func plan(for device: AVCaptureDevice, _ o: Orientation, upright: CGFloat = 0) -> Plan? {
        plan(formats: device.formats, o, upright: upright)
    }

    static func plan(formats all: [AVCaptureDevice.Format], _ o: Orientation, upright: CGFloat) -> Plan? {
        func dims(_ f: AVCaptureDevice.Format) -> CMVideoDimensions {
            CMVideoFormatDescriptionGetDimensions(f.formatDescription)
        }
        let formats = all.filter { f in
            f.videoSupportedFrameRateRanges.contains { $0.maxFrameRate >= 29 }
        }
        let landscape = formats.filter { dims($0).width > dims($0).height }
        switch o {
        case .vertical:
            if let native = formats.filter({ dims($0).height > dims($0).width })
                .max(by: { dims($0).height < dims($1).height }) {
                let d = dims(native)
                return Plan(format: native, size: nil, rotate: 0, label: "\(d.width)×\(d.height) native")
            }
            guard let tall = landscape.max(by: { dims($0).height < dims($1).height }) else { return nil }
            let d = dims(tall)
            if upright == 90 || upright == 270 {
                // Frames on their side: the long side is his height. Crop the short side to 9:16.
                let across = min(d.height, Int32((Double(d.width) * 9 / 16).rounded()) & ~1)
                return Plan(format: tall, size: CMVideoDimensions(width: d.width, height: across), rotate: upright,
                            label: "\(across)×\(d.width), iPhone upright")
            }
            return Plan(format: tall, size: CMVideoDimensions(width: 1080, height: 1920), rotate: 0,
                        label: "1080×1920, cropped from \(d.width)×\(d.height)")
        case .horizontal:
            let wide = landscape.filter { abs(Double(dims($0).width) / Double(dims($0).height) - 16.0 / 9) < 0.02 }
            guard let best = (wide.isEmpty ? landscape : wide).max(by: { dims($0).width < dims($1).width })
            else { return nil }
            let d = dims(best)
            return Plan(format: best, size: nil, rotate: 0, label: "\(d.width)×\(d.height)")
        }
    }

    private func configure() {
        let vID = videoID, aID = audioID, o = orientation
        queue.async { [self] in
            guard !output.isRecording else { return }
            session.beginConfiguration()
            if let i = videoInput { session.removeInput(i); videoInput = nil }
            if let i = audioInput { session.removeInput(i); audioInput = nil }
            var plan: Plan?
            var device: AVCaptureDevice?
            if let id = vID, let dev = AVCaptureDevice(uniqueID: id),
               let input = try? AVCaptureDeviceInput(device: dev), session.canAddInput(input) {
                session.addInput(input); videoInput = input
                watchRotation(of: dev)
                plan = Self.plan(for: dev, o, upright: rotation?.videoRotationAngleForHorizonLevelCapture ?? 0)
                device = dev
            }
            if let id = aID, let dev = AVCaptureDevice(uniqueID: id),
               let input = try? AVCaptureDeviceInput(device: dev), session.canAddInput(input) {
                session.addInput(input); audioInput = input
            }
            if !session.outputs.contains(output), session.canAddOutput(output) { session.addOutput(output) }
            if #available(macOS 15.2, *),
               !session.outputs.contains(where: { $0 === timingOutput }), session.canAddOutput(timingOutput) {
                session.addOutput(timingOutput)
            }
            if let conn = output.connection(with: .video) {
                var settings: [String: Any] = [AVVideoCodecKey: AVVideoCodecType.hevc]
                if let size = plan?.size {
                    settings[AVVideoWidthKey] = size.width
                    settings[AVVideoHeightKey] = size.height
                    settings[AVVideoScalingModeKey] = AVVideoScalingModeResizeAspectFill
                }
                if let plan {
                    let d = plan.size ?? CMVideoFormatDescriptionGetDimensions(plan.format.formatDescription)
                    settings[AVVideoCompressionPropertiesKey] = [AVVideoAverageBitRateKey: Self.bitrate(d)]
                }
                output.setOutputSettings(settings, for: conn)
                // The file output writes the turn as a transform; the frames stay as the camera sent them.
                let turn = plan?.rotate ?? 0
                if conn.isVideoRotationAngleSupported(turn) { conn.videoRotationAngle = turn }
            }
            session.commitConfiguration()
            // On macOS, setting activeFormat after the session is configured wins over the preset.
            if let dev = device, let plan, (try? dev.lockForConfiguration()) != nil {
                dev.activeFormat = plan.format
                if plan.format.videoSupportedFrameRateRanges.contains(where: { $0.minFrameRate <= 30 && $0.maxFrameRate >= 30 }) {
                    let thirty = CMTime(value: 1, timescale: 30)
                    dev.activeVideoMinFrameDuration = thirty
                    dev.activeVideoMaxFrameDuration = thirty
                }
                dev.unlockForConfiguration()
            }
            let crop = plan?.size != nil, label = plan?.label ?? "", turn = plan?.rotate ?? 0
            DispatchQueue.main.async {
                if self.previewRotation != turn { self.previewRotation = turn }
                if self.previewCropsToVertical != crop { self.previewCropsToVertical = crop }
                if self.formatDescription != label { self.formatDescription = label }
            }
        }
    }

    static func bitrate(_ d: CMVideoDimensions) -> Int {
        Int(Double(bitrate1080) * Double(d.width) * Double(d.height) / (1920 * 1080))
    }

    /// Follows which way up the camera is. Turning an iPhone between upright and sideways sets the
    /// take up again (not during a take). Runs on the camera queue.
    private func watchRotation(of device: AVCaptureDevice) {
        if rotation?.device == device { return }
        rotationWatch = nil
        let r = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: nil)
        rotation = r
        rotationWatch = r.observe(\.videoRotationAngleForHorizonLevelCapture, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.configure() }
        }
    }

    func setPaused(_ on: Bool) {
        guard on != paused, !output.isRecording else { return }
        paused = on
        apply()
    }

    /// Stops the camera while nothing shows it, and starts it again when something does.
    func hold(_ on: Bool) {
        guard on != held else { return }
        if on && output.isRecording { return }
        held = on
        apply()
    }

    /// Runs the session (and the 12 Hz mic level) only when you want it and it is on screen.
    private func apply() {
        guard ready else { return }
        let run = !paused && !held
        guard run != live else { return }
        live = run
        levelTimer?.invalidate()
        levelTimer = nil
        meter.level = 0
        if run {
            let t = Timer(timeInterval: 0.08, repeats: true) { [weak self] _ in self?.pollLevel() }
            t.tolerance = 0.02
            RunLoop.main.add(t, forMode: .common)
            levelTimer = t
        }
        queue.async { [self] in run ? session.startRunning() : session.stopRunning() }
    }

    /// Turns the camera back on and waits until it delivers frames, so a take never starts black.
    /// True when it was off. startRunning blocks the camera queue until the session runs, so a hop
    /// through the queue waits as long as the camera needs: an iPhone can take longer than the
    /// 2 seconds the old poll gave it.
    @discardableResult
    func resume() async -> Bool {
        guard paused || held else { return false }
        paused = false
        held = false
        apply()
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in queue.async { c.resume() } }
        try? await Task.sleep(for: .milliseconds(400))  // exposure settles
        return true
    }

    private func pollLevel() {
        if !live { return }
        // averagePowerLevel is dB (-160...0). Map roughly -50dB...0dB to 0...1.
        let db = output.connection(with: .audio)?.audioChannels.first?.averagePowerLevel ?? -160
        let v = max(0, min(1, (db + 50) / 50))
        let next = meter.level * 0.5 + v * 0.5
        if abs(next - meter.level) > 0.005 { meter.level = next }
    }

    /// How long a start may take before it counts as failed. The first frame normally comes in
    /// well under a second; a camera or mic that stopped sending (AirPods switching, iPhone
    /// dropping) never sends it, and without a limit the app would wait forever.
    static let startLimit: TimeInterval = 8

    /// Starts writing. On macOS 15.2+ a supported timing tap returns the first actual camera video
    /// sample at or after the movie begins. Otherwise the result explicitly uses callback timing.
    func startRecording(to url: URL) async throws -> Start {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Start, Error>) in
                queue.async { [self] in
                    guard videoInput != nil else {
                        cont.resume(throwing: RecorderError("No camera selected.")); return
                    }
                    startCont = cont
                    armVideoStartTiming()
                    output.startRecording(to: url, recordingDelegate: self)
                    queue.asyncAfter(deadline: .now() + Self.startLimit) { [self] in
                        failStart(RecorderError("The camera or mic sent nothing, so the take did not start. "
                                                + "Check the camera and mic, then record again."))
                    }
                }
            }
        }, onCancel: {
            self.cancelStart()
        })
    }

    /// Gives up on a start that has not begun yet (Record pressed again, or the time limit).
    func cancelStart() {
        queue.async { [self] in failStart(CancellationError()) }
    }

    /// On `queue`. Ends a waiting start with an error; does nothing once the take has begun.
    private func failStart(_ error: Error) {
        guard let c = startCont else { return }
        startCont = nil
        clearVideoStartTiming()
        if output.isRecording { output.stopRecording() }
        c.resume(throwing: error)
    }

    func stopRecording() async {
        await withCheckedContinuation { cont in
            queue.async { [self] in
                clearVideoStartTiming()
                guard output.isRecording else { cont.resume(); return }
                stopCont = cont
                output.stopRecording()
            }
        }
    }

    /// Arms the video sample tap only when MovieFileOutput can also tell us its session-clock start.
    /// A frame delivered late from before Record was pressed is rejected by the activation threshold.
    private func armVideoStartTiming() {
        clearVideoStartTiming()
        guard #available(macOS 15.2, *), timingOutput.connection(with: .video) != nil,
              let syncClock = session.synchronizationClock else { return }
        let generation = videoTimingGeneration
        let probe = VideoPTSProbe { [weak self] pts in
            self?.queue.async { [weak self] in
                guard let self, self.videoTimingGeneration == generation, self.startCont != nil else { return }
                if let first = self.videoStartGate.noteVideo(pts) { self.completeVideoStart(first) }
            }
        }
        videoTimingProbe = probe
        timingOutput.setSampleBufferDelegate(probe, queue: timingQueue)
        let hostClock = CMClockGetHostTimeClock()
        let activation = CMSyncConvertTime(CMClockGetTime(hostClock), from: hostClock, to: syncClock)
        guard activation.isNumeric else { clearVideoStartTiming(); return }
        videoStartGate.arm(at: activation)
    }

    private func clearVideoStartTiming() {
        videoTimingGeneration &+= 1
        videoStartGate.reset()
        timingOutput.setSampleBufferDelegate(nil, queue: nil)
        videoTimingProbe = nil
    }

    private func completeApproximateStart() {
        guard let c = startCont else { clearVideoStartTiming(); return }
        let host = CMClockGetTime(CMClockGetHostTimeClock()).seconds
        startCont = nil
        clearVideoStartTiming()
        c.resume(returning: Start(date: CaptureClock.date(hostTime: host) ?? Date(), hostTime: host, timing: .callback))
    }

    private func completeVideoStart(_ sessionPTS: CMTime) {
        guard let c = startCont, let syncClock = session.synchronizationClock else {
            completeApproximateStart(); return
        }
        let hostClock = CMClockGetHostTimeClock()
        let hostPTS = CMSyncConvertTime(sessionPTS, from: syncClock, to: hostClock)
        guard hostPTS.isNumeric, let date = CaptureClock.date(hostTime: hostPTS.seconds) else {
            completeApproximateStart(); return
        }
        startCont = nil
        clearVideoStartTiming()
        c.resume(returning: Start(date: date, hostTime: hostPTS.seconds, timing: .videoFrame))
    }

    func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo fileURL: URL,
                    from connections: [AVCaptureConnection]) {
        queue.async { [self] in
            guard startCont != nil else { return }
            // macOS 15.0/15.1 cannot correlate the movie with a session-clock start PTS.
            // Keep recording there, but explicitly retain callback-time (not exact-frame) semantics.
            completeApproximateStart()
        }
    }

    @available(macOS 15.2, *)
    func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo fileURL: URL, startPTS: CMTime,
                    from connections: [AVCaptureConnection]) {
        queue.async { [self] in
            guard startCont != nil else { return }
            guard videoStartGate.isArmed, startPTS.isNumeric else {
                completeApproximateStart(); return
            }
            // startPTS may be audio. It is only a lower bound for the first camera video frame.
            if let first = videoStartGate.noteMovieStart(startPTS) { completeVideoStart(first) }
        }
    }

    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL,
                    from connections: [AVCaptureConnection], error: Error?) {
        queue.async { [self] in
            clearVideoStartTiming()
            if let c = startCont { c.resume(throwing: error ?? RecorderError("Camera failed to start.")); startCont = nil }
            stopCont?.resume(); stopCont = nil
        }
    }
}

struct RecorderError: LocalizedError {
    let message: String
    init(_ m: String) { message = m }
    var errorDescription: String? { message }
}
