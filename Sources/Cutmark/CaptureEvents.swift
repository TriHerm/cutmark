import AppKit
import CoreGraphics
import CoreMedia
import Foundation

/// V1 recording signals for one screen take. `t` is always seconds from the first accepted
/// ScreenCaptureKit frame PTS: the exact source clock used by the screen movie writer. Coordinates
/// use Quartz global display space normalized to [0, 1], top-left origin. Keystrokes are deliberately
/// absent from this schema.
struct CaptureEvent: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case recordingStarted = "recording_started"
        case recordingStopped = "recording_stopped"
        case move
        case down
        case up
        case scroll
        case marker
        case visualActive = "visual_active"
        case visualIdle = "visual_idle"
    }

    var t: Double
    var type: Kind
    var source: TakeKind = .screen
    var x: Double?
    var y: Double?
    /// Mouse button: 0 left, 1 right, 2 other.
    var button: Int?
    /// Click sequence count reported by AppKit.
    var count: Int?
    var dx: Double?
    var dy: Double?
    /// Whether AppKit supplied precise scrolling deltas (trackpad / high-resolution device).
    var precise: Bool?
    var label: String?

    init(t: Double, type: Kind, source: TakeKind = .screen, x: Double? = nil, y: Double? = nil,
         button: Int? = nil, count: Int? = nil, dx: Double? = nil, dy: Double? = nil,
         precise: Bool? = nil, label: String? = nil) {
        self.t = t
        self.type = type
        self.source = source
        self.x = x
        self.y = y
        self.button = button
        self.count = count
        self.dx = dx
        self.dy = dy
        self.precise = precise
        self.label = label
    }
}

struct CaptureMarker: Equatable, Sendable {
    let number: Int
    let t: Double
    let label: String
}

enum CaptureEventLog {
    struct DisplayHeader: Codable, Equatable, Sendable {
        var id: UInt32
        var x: Double
        var y: Double
        var width: Double
        var height: Double
    }

    struct Header: Codable, Equatable, Sendable {
        var v = 1
        var type = "header"
        var take: Int
        var source: TakeKind = .screen
        var clock = "screen_pts"
        var coordinates = "display_normalized_top_left"
        var display: DisplayHeader
    }

    static func directory(in session: URL) -> URL { session.appending(path: ".capture-events") }

    static func url(in session: URL, take: Int) -> URL {
        directory(in: session).appending(path: String(format: "take-%02d-screen.jsonl", take))
    }

    static func remove(in session: URL, take: Int) {
        let file = url(in: session, take: take)
        if FileManager.default.fileExists(atPath: file.path) { try? FileManager.default.removeItem(at: file) }
        removeDirectoryIfEmpty(in: session)
    }

    static func trash(in session: URL, take: Int) {
        let file = url(in: session, take: take)
        if FileManager.default.fileExists(atPath: file.path) {
            try? FileManager.default.trashItem(at: file, resultingItemURL: nil)
        }
        removeDirectoryIfEmpty(in: session)
    }

    private static func removeDirectoryIfEmpty(in session: URL) {
        let dir = directory(in: session)
        if ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).isEmpty {
            try? FileManager.default.removeItem(at: dir)
        }
    }

    /// `take-07-screen.mov` and `take-07-a-named-take-screen.mov` both resolve to take 7.
    static func takeNumber(forScreenFile url: URL) -> Int? {
        let parts = url.deletingPathExtension().lastPathComponent.split(separator: "-")
        guard parts.count >= 3, parts.first == "take", parts.last == "screen" else { return nil }
        return Int(parts[1])
    }

    static func takeNumber(forEventFile url: URL) -> Int? {
        let name = url.deletingPathExtension().lastPathComponent
        let parts = name.split(separator: "-")
        guard parts.count == 3, parts.first == "take", parts.last == "screen" else { return nil }
        return Int(parts[1])
    }

    static func valid(_ header: Header, take: Int? = nil) -> Bool {
        let d = header.display
        return header.v == 1 && header.type == "header" && header.source == .screen
            && header.clock == "screen_pts" && header.coordinates == "display_normalized_top_left"
            && header.take > 0 && take.map { $0 == header.take } ?? true
            && d.x.isFinite && d.y.isFinite && d.width.isFinite && d.height.isFinite
            && d.width > 0 && d.height > 0
    }

    static func valid(_ event: CaptureEvent) -> Bool {
        guard event.source == .screen, event.t.isFinite, event.t >= 0 else { return false }
        if let x = event.x, !x.isFinite || x < 0 || x > 1 { return false }
        if let y = event.y, !y.isFinite || y < 0 || y > 1 { return false }
        if let dx = event.dx, !dx.isFinite { return false }
        if let dy = event.dy, !dy.isFinite { return false }
        if let button = event.button, !(0...2).contains(button) { return false }
        if let count = event.count, count < 1 { return false }
        return true
    }

    static func header(_ url: URL) -> Header? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 8 * 1024),
              let newline = data.firstIndex(of: 0x0A) else { return nil }
        return try? JSONDecoder().decode(Header.self, from: data[..<newline])
    }

    /// Every complete event line survives. A process crash can cut the final write in half; that
    /// line is ignored. `through` bounds a recovered log to the playable screen duration, so events
    /// from an unfinished fragment never leak past the media that actually survived.
    static func read(_ url: URL, through duration: Double? = nil) -> [CaptureEvent] {
        guard let take = takeNumber(forEventFile: url), let h = header(url), valid(h, take: take),
              let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        return data.split(separator: 0x0A).dropFirst().compactMap { line in
            guard let event = try? decoder.decode(CaptureEvent.self, from: Data(line)),
                  valid(event),
                  duration.map({ event.t <= $0 + 0.001 }) ?? true else { return nil }
            return event
        }
    }

    static func markers(in session: URL, screenFile: URL, through duration: Double) -> [CaptureEvent] {
        guard let take = takeNumber(forScreenFile: screenFile) else { return [] }
        let file = url(in: session, take: take)
        guard let h = header(file), valid(h, take: take),
              let handle = try? FileHandle(forReadingFrom: file) else { return [] }
        defer { try? handle.close() }
        let decoder = JSONDecoder()
        var data = Data()
        var out: [CaptureEvent] = []
        while true {
            guard let chunk = try? handle.read(upToCount: 64 * 1024), !chunk.isEmpty else { break }
            data.append(chunk)
            while let newline = data.firstIndex(of: 0x0A) {
                let line = data[..<newline]
                data.removeSubrange(...newline)
                // Pointer events dominate the file. Avoid Codable work unless the flat line says marker.
                guard line.range(of: Data("\"marker\"".utf8)) != nil,
                      let event = try? decoder.decode(CaptureEvent.self, from: Data(line)),
                      valid(event), event.type == .marker, event.t <= duration + 0.001 else { continue }
                out.append(event)
            }
        }
        return out
    }

    final class Writer: @unchecked Sendable {
        private let handle: FileHandle
        private let encoder = JSONEncoder()
        private var lastTime = 0.0

        init(url: URL, header: Header) throws {
            guard let take = CaptureEventLog.takeNumber(forEventFile: url), CaptureEventLog.valid(header, take: take) else {
                throw RecorderError("The take event log metadata is invalid.")
            }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: url.path) {
                guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
                    throw RecorderError("Cutmark could not create the take event log.")
                }
            }
            handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            if (try? handle.offset()) == 0 {
                var data = try encoder.encode(header)
                data.append(0x0A)
                try handle.write(contentsOf: data)
                try handle.synchronize()
            } else if CaptureEventLog.header(url) != header {
                try? handle.close()
                throw RecorderError("The existing take event log has incompatible capture metadata.")
            }
        }

        /// Called only on CaptureEventRecorder's serial queue. `durable` is reserved for sparse
        /// state/marker events; pointer samples never fsync the disk at sampling frequency.
        @discardableResult
        func append(_ event: CaptureEvent, durable: Bool = false) -> Bool {
            var event = event
            event.t = max(lastTime, event.t)
            lastTime = event.t
            guard var data = try? encoder.encode(event) else { return false }
            data.append(0x0A)
            do {
                try handle.write(contentsOf: data)
                if durable { try handle.synchronize() }
                return true
            } catch {
                return false
            }
        }

        func close() {
            try? handle.synchronize()
            try? handle.close()
        }
    }
}

/// Low-cost input signals for a running screen take. It intentionally installs no local monitor:
/// interaction with Cutmark's excluded windows (including the floating strip) must not become fake
/// screen input. Global mouse events need no keystroke/Input Monitoring permission.
final class CaptureEventRecorder: @unchecked Sendable {
    private let writer: CaptureEventLog.Writer
    private let originHost: Double
    private let displayBounds: CGRect
    private let queue = DispatchQueue(label: "cutmark.capture.events", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var monitor: Any?

    private var running = false
    private var lastPoint: CGPoint?
    private var markerCount = 0

    init(session: URL, take: Int, screenOriginHost: Double, displayID: CGDirectDisplayID) throws {
        let bounds = CGDisplayBounds(displayID)
        guard bounds.width > 0, bounds.height > 0 else { throw RecorderError("The recorded display is unavailable.") }
        originHost = screenOriginHost
        displayBounds = bounds
        let display = CaptureEventLog.DisplayHeader(id: displayID, x: bounds.minX, y: bounds.minY,
                                                    width: bounds.width, height: bounds.height)
        writer = try CaptureEventLog.Writer(url: CaptureEventLog.url(in: session, take: take),
                                            header: .init(take: take, display: display))
    }

    static func prepare(session: URL, take: Int, screenOriginHost: Double,
                        displayID: CGDirectDisplayID) async throws -> CaptureEventRecorder {
        try await Task.detached(priority: .utility) {
            try CaptureEventRecorder(session: session, take: take, screenOriginHost: screenOriginHost, displayID: displayID)
        }.value
    }

    @MainActor
    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            running = true
            _ = writer.append(.init(t: 0, type: .recordingStarted), durable: true)
        }

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(33), leeway: .milliseconds(6))
        timer.setEventHandler { [weak self] in self?.samplePointer() }
        timer.resume()
        self.timer = timer

        let mask: NSEvent.EventTypeMask = [
            .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
            .otherMouseDown, .otherMouseUp, .scrollWheel,
        ]
        monitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] e in
            guard let self else { return }
            let location = e.cgEvent?.location ?? CGEvent(source: nil)?.location
            guard let location else { return }
            let button: Int
            switch e.type {
            case .rightMouseDown, .rightMouseUp: button = 1
            case .otherMouseDown, .otherMouseUp: button = 2
            default: button = 0
            }
            let type = e.type
            let clickCount = e.clickCount
            let dx = Double(e.scrollingDeltaX)
            let dy = Double(e.scrollingDeltaY)
            let precise = e.hasPreciseScrollingDeltas
            // NSEvent timestamps and the media host clock advance at the same rate but are not an
            // API-guaranteed shared epoch. Bridge by their age at receipt instead of assuming their
            // absolute values are interchangeable. This preserves the real click/scroll occurrence
            // time even when the global monitor callback arrives a little later.
            let host = Self.hostTime(forEventTimestamp: e.timestamp)
            queue.async { [weak self] in
                self?.record(type: type, point: location, host: host, button: button,
                             count: clickCount, dx: dx, dy: dy, precise: precise)
            }
        }
    }

    @MainActor
    func stop() async {
        timer?.cancel()
        timer = nil
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                guard let self else { continuation.resume(); return }
                if running {
                    _ = writer.append(event(type: .recordingStopped, host: Self.hostNow()), durable: true)
                    running = false
                    writer.close()
                }
                continuation.resume()
            }
        }
    }

    /// Persists before returning so the UI never confirms a marker that only lived in memory.
    func addMarker(_ label: String? = nil) async -> CaptureMarker? {
        await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                guard let self, running else { continuation.resume(returning: nil); return }
                markerCount += 1
                let clean = (label ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let title = clean.isEmpty ? "Marker \(markerCount)" : String(clean.prefix(120))
                var e = event(type: .marker, host: Self.hostNow())
                e.label = clean.isEmpty ? nil : title
                guard writer.append(e, durable: true) else {
                    markerCount -= 1
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: CaptureMarker(number: markerCount, t: e.t, label: title))
            }
        }
    }

    /// ScreenCaptureKit's own content-change signal on the same PTS clock as the movie. Smart-speed
    /// uses these sparse transitions instead of assuming that a quiet mouse means an idle screen.
    func recordVisualState(active: Bool, screenPTS: Double) {
        guard screenPTS.isFinite else { return }
        queue.async { [weak self] in
            guard let self, running else { return }
            let t = max(0, screenPTS - originHost)
            _ = writer.append(.init(t: t, type: active ? .visualActive : .visualIdle), durable: true)
        }
    }

    private func samplePointer() {
        guard running, let point = CGEvent(source: nil)?.location,
              let p = Self.normalized(point, in: displayBounds) else { return }
        if let lastPoint, abs(lastPoint.x - p.x) < 0.0005, abs(lastPoint.y - p.y) < 0.0005 { return }
        lastPoint = p
        var e = event(type: .move, host: Self.hostNow())
        e.x = p.x
        e.y = p.y
        _ = writer.append(e)
    }

    private func record(type: NSEvent.EventType, point: CGPoint, host: Double, button: Int,
                        count: Int, dx: Double, dy: Double, precise: Bool) {
        guard running, let p = Self.normalized(point, in: displayBounds) else { return }
        let kind: CaptureEvent.Kind
        switch type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown: kind = .down
        case .leftMouseUp, .rightMouseUp, .otherMouseUp: kind = .up
        case .scrollWheel: kind = .scroll
        default: return
        }
        var e = event(type: kind, host: host)
        e.x = p.x
        e.y = p.y
        if kind == .scroll {
            e.dx = Self.round2(dx)
            e.dy = Self.round2(dy)
            e.precise = precise
        } else {
            e.button = button
            e.count = max(1, count)
        }
        _ = writer.append(e)
    }

    private func event(type: CaptureEvent.Kind, host: Double) -> CaptureEvent {
        CaptureEvent(t: Self.round4(max(0, host - originHost)), type: type)
    }

    private static func hostNow() -> Double { CMClockGetTime(CMClockGetHostTimeClock()).seconds }

    static func hostTime(forEventTimestamp event: Double, uptimeNow: Double = ProcessInfo.processInfo.systemUptime,
                         hostNow: Double = hostNow()) -> Double {
        let age = event - uptimeNow
        return abs(age) < 2 ? hostNow + age : hostNow
    }

    /// CoreGraphics pointer locations and display bounds share Quartz's top-left global space.
    /// Dropping points outside the selected display avoids collecting activity from another monitor.
    static func normalized(_ point: CGPoint, in bounds: CGRect?) -> CGPoint? {
        guard let bounds, bounds.width > 0, bounds.height > 0,
              point.x >= bounds.minX, point.x <= bounds.maxX,
              point.y >= bounds.minY, point.y <= bounds.maxY else { return nil }
        return CGPoint(x: (point.x - bounds.minX) / bounds.width,
                       y: (point.y - bounds.minY) / bounds.height)
    }

    private static func round4(_ x: Double) -> Double { (x * 10_000).rounded() / 10_000 }
    private static func round2(_ x: Double) -> Double { (x * 100).rounded() / 100 }
}

extension EditTimeMap {
    struct MappedCaptureEvent: Equatable {
        let event: CaptureEvent
        let outputTime: Double
    }

    /// V1 signals have one identity: the screen source of this take. Reused source ranges
    /// intentionally produce more than one output occurrence; events in removed ranges produce none.
    func outputEvents(_ events: [CaptureEvent], take: Int) -> [MappedCaptureEvent] {
        let source = Source(take: take, kind: .screen)
        return events.flatMap { event in
            outputTimes(source: source, time: event.t).map { MappedCaptureEvent(event: event, outputTime: $0) }
        }
    }
}
