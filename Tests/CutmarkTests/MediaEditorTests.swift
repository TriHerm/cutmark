import Testing
import AppKit
import SwiftUI
import AVFoundation
@testable import Cutmark

@Suite(.serialized) @MainActor
struct MediaEditorTests {
    init() { _ = NSApplication.shared }
    func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "media-editor-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    func clip(_ file: String = "test.mov", lane: MediaEditProject.Lane = .video) -> MediaEditProject.Clip {
        .init(file: file, name: file, kind: lane == .audio ? .audio : .video, lane: lane, sourceDuration: 10, start: 2, end: 8, speed: 2)
    }
    @Test func splitUsesSourceSpeedAndRetainsAbsoluteOverlayPosition() throws {
        let a = clip(), b = clip("overlay.mov", lane: .overlay)
        var project = MediaEditProject(clips: [a, b])
        let splitA = project.split(a.id, at: 1); #expect(splitA)
        #expect(project.clips[0].end == 4)
        #expect(project.clips[1].start == 4)
        #expect(project.duration == 3)
        let splitB = project.split(b.id, at: 2); #expect(splitB)
        #expect(project.clips.last?.offset == 2)
        #expect(project.clips.last?.start == 6)
        try project.validate()
        let edge = project.split(a.id, at: 0); #expect(!edge)
    }
    @Test func overlayTrimKeepsTheUntrimmedRightEdgeInPlace() throws {
        var overlay = clip("overlay.mov", lane: .overlay); overlay.offset = 2
        var project = MediaEditProject(clips: [clip(), overlay])
        let oldEnd = overlay.offset + overlay.duration
        project.trim(overlay.id, start: 4, end: overlay.end)
        let trimmed = project.clips[1]
        #expect(trimmed.offset == 3)
        #expect(trimmed.offset + trimmed.duration == oldEnd)
        try project.validate()
    }
    @Test func trimReorderAndPersistencePreserveMedia() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let a = clip(), b = clip("second.mov")
        var project = MediaEditProject(clips: [a, b])
        project.trim(a.id, start: 3, end: 7)
        project.move(b.id, before: a.id)
        #expect(project.position(a.id) == 3)
        try project.save(in: root)
        #expect(try MediaEditProject.load(in: root) == project)
        let bytes = try Data(contentsOf: MediaEditProject.file(in: root))
        project.clips[0].speed = .nan
        #expect(throws: (any Error).self) { try project.save(in: root) }
        #expect(try Data(contentsOf: MediaEditProject.file(in: root)) == bytes)
        try Data("broken".utf8).write(to: MediaEditProject.file(in: root))
        #expect(throws: (any Error).self) { try MediaEditProject.load(in: root) }
    }
    @Test func escapingSourcesAndEditFoldersAreRejected() throws {
        let root = try folder(), outside = try folder()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside) }
        let source = outside.appending(path: "secret.mov"); try Data([1]).write(to: source)
        try FileManager.default.createSymbolicLink(at: root.appending(path: "test.mov"), withDestinationURL: source)
        #expect(throws: (any Error).self) { try MediaEditProject.source("test.mov", session: root) }
        #expect(throws: (any Error).self) { try MediaEditProject.source("../secret.mov", session: root) }
        try FileManager.default.createSymbolicLink(at: root.appending(path: "_edit"), withDestinationURL: outside)
        #expect(throws: (any Error).self) { try MediaEditProject(clips: [clip()]).save(in: root) }
        #expect(!FileManager.default.fileExists(atPath: outside.appending(path: "studio/project.json").path))
    }
    @Test func compositionExportsStillsSpeedOverlayAndMixedAudio() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        try await makeVideo(root.appending(path: "source.mov"), size: CGSize(width: 96, height: 64), seconds: 2)
        try image(.red, at: root.appending(path: "red.png"))
        try image(.blue, at: root.appending(path: "blue.png"))
        let movie = MediaEditProject.Clip(file: "source.mov", name: "Screen", kind: .video, lane: .video, sourceDuration: 2, end: 2, speed: 2, volume: 0)
        let still = MediaEditProject.Clip(file: "red.png", name: "Card", kind: .image, lane: .video, sourceDuration: 3600, end: 2)
        let overlay = MediaEditProject.Clip(file: "blue.png", name: "Overlay", kind: .image, lane: .overlay, sourceDuration: 3600, end: 1, offset: 1, fill: true)
        let sound = MediaEditProject.Clip(file: "source.mov", name: "Sound", kind: .audio, lane: .audio, sourceDuration: 2, end: 2, offset: 0.5, volume: 0.6, fadeIn: 0.2, fadeOut: 0.2)
        let project = MediaEditProject(clips: [movie, still, overlay, sound])
        let result = try await MediaEditComposition.build(project, session: root)
        #expect(result.duration == 3)
        #expect(result.item().videoComposition?.renderSize == result.video.renderSize)
        #expect(result.item().audioMix?.inputParameters.count == result.audio.inputParameters.count)
        let output = root.appending(path: "result.mp4")
        let exporter = try #require(AVAssetExportSession(asset: result.asset, presetName: AVAssetExportPresetHighestQuality))
        exporter.videoComposition = result.video; exporter.audioMix = result.audio
        exporter.outputURL = output; exporter.outputFileType = .mp4
        await exporter.export()
        #expect(exporter.status == .completed, "\(String(describing: exporter.error))")
        let asset = AVURLAsset(url: output)
        #expect(abs(try await asset.load(.duration).seconds - 3) < 0.05)
        #expect(try await asset.loadTracks(withMediaType: .audio).count == 1)
        let peaks = try await TimelineMedia.waveform(url: output, start: 0, end: 3, sampleCount: 90)
        #expect((peaks.max() ?? 0) > 0.6)
        #expect((peaks.prefix(10).max() ?? 0) < 0.1)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
        let frame = try await generator.image(at: MediaEditComposition.time(1.5)).image
        let bitmap = NSBitmapImageRep(cgImage: frame)
        let center = try #require(bitmap.colorAt(x: 960, y: 540)?.usingColorSpace(.deviceRGB))
        let corner = try #require(bitmap.colorAt(x: 1600, y: 200)?.usingColorSpace(.deviceRGB))
        #expect(center.redComponent > 0.8 && center.blueComponent < 0.15)
        #expect(corner.blueComponent > 0.8 && corner.redComponent < 0.15)
        let later = NSBitmapImageRep(cgImage: try await generator.image(at: MediaEditComposition.time(2.5)).image)
        #expect(try #require(later.colorAt(x: 1600, y: 200)?.usingColorSpace(.deviceRGB)).redComponent > 0.8)
    }
    @Test func storeUndoReopenAndPendingSeekSplit() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let app = AppModel(); app.library.setRoot(root)
        let doc = try #require(app.library.createSession())
        try await makeVideo(doc.url.appending(path: "source.mov"), size: CGSize(width: 96, height: 64), seconds: 2)
        let store = MediaEditorStore(doc: doc); await store.open(); defer { store.close() }
        await store.add(try #require(store.assets.first))
        let deadline = Date().addingTimeInterval(20)
        while store.building && Date() < deadline { await Task.yield() }
        #expect(store.problem == nil)
        store.seek(1); store.split()
        #expect(store.project.clips.count == 2)
        #expect(abs(store.project.clips[0].end - 1) < 0.01)
        store.undo(); #expect(store.project.clips.count == 1)
        store.undo(redo: true); #expect(store.project.clips.count == 2)
        #expect(try MediaEditProject.load(in: doc.url) == store.project)
    }
    @Test func cameraOverlayUsesMeasuredTimingAndRefusesCallbackTiming() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let app = AppModel(); app.library.setRoot(root)
        let doc = try #require(app.library.createSession())
        try await makeVideo(doc.url.appending(path: "camera.mov"), size: CGSize(width: 96, height: 64), seconds: 2)
        let screen = Take(number: 1, kind: .screen, file: "screen.mov", startedAt: .distantPast, duration: 2, captureHostTime: 100.2, timingQuality: .videoFrame)
        let camera = Take(number: 1, kind: .camera, file: "camera.mov", startedAt: .distantPast, duration: 2, captureHostTime: 100, timingQuality: .videoFrame)
        doc.meta.takes = [screen, camera]; doc.save()
        let main = MediaEditProject.Clip(file: "screen.mov", name: "Screen", kind: .video, lane: .video, sourceDuration: 2, start: 0.5, end: 1.5, speed: 2)
        try MediaEditProject(clips: [main]).save(in: doc.url)
        let store = MediaEditorStore(doc: doc); await store.open(); defer { store.close() }
        store.selected = main.id; await store.addPairedCamera()
        let overlay = try #require(store.project.clips.last)
        #expect(overlay.lane == .overlay && overlay.volume == 0)
        #expect(abs(overlay.start - 0.7) < 0.0001 && abs(overlay.end - 1.7) < 0.0001)
        #expect(overlay.duration == 0.5 && overlay.offset == 0 && overlay.speed == 2)
        doc.meta.takes[1].timingQuality = .callback
        store.selected = main.id; await store.addPairedCamera()
        #expect(store.project.clips.count == 2)
        #expect(store.problem?.contains("no frame timing") == true)
    }
    @Test func selectingAClipKeepsAPlayheadInsideItAndMalformedProjectsStayUntouched() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let app = AppModel(); app.library.setRoot(root)
        let doc = try #require(app.library.createSession())
        try image(.red, at: doc.url.appending(path: "image.png"))
        let store = MediaEditorStore(doc: doc); await store.open(); defer { store.close() }
        await store.add(try #require(store.assets.first))
        let deadline = Date().addingTimeInterval(20)
        while store.building && Date() < deadline { await Task.yield() }
        store.seek(2); store.select(try #require(store.project.clips.first).id)
        #expect(store.time == 2)
        store.close()
        let damaged = Data("{broken".utf8)
        try damaged.write(to: MediaEditProject.file(in: doc.url))
        await store.open()
        #expect(store.loadFailed && !store.editable)
        store.edit { $0.clips = [] }
        #expect(try Data(contentsOf: MediaEditProject.file(in: doc.url)) == damaged)
    }
    @Test func renderEditorWorkspace() async throws {
        guard let directory = ProcessInfo.processInfo.environment["CUTMARK_SNAPSHOT"] else { return }
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let app = AppModel(); app.library.setRoot(root)
        let doc = try #require(app.library.createSession()); doc.meta.title = "A clearer product demo"
        try await makeVideo(doc.url.appending(path: "Screen demo.mov"), size: CGSize(width: 320, height: 180), seconds: 4)
        try image(.init(calibratedRed: 0.23, green: 0.34, blue: 0.62, alpha: 1), at: doc.url.appending(path: "Opening card.png"))
        try image(.init(calibratedRed: 0.68, green: 0.43, blue: 0.24, alpha: 1), at: doc.url.appending(path: "Closing card.png"))
        let a = MediaEditProject.Clip(file: "Screen demo.mov", name: "Screen demo", kind: .video, lane: .video, sourceDuration: 4, end: 4)
        let b = MediaEditProject.Clip(file: "Opening card.png", name: "Opening card", kind: .image, lane: .video, sourceDuration: 3600, end: 3)
        let c = MediaEditProject.Clip(file: "Closing card.png", name: "Camera overlay", kind: .image, lane: .overlay, sourceDuration: 3600, end: 2, offset: 1)
        let d = MediaEditProject.Clip(file: "Screen demo.mov", name: "Soundtrack", kind: .audio, lane: .audio, sourceDuration: 4, end: 4, offset: 1)
        try MediaEditProject(clips: [b, a, c, d]).save(in: doc.url)
        let store = MediaEditorStore(doc: doc); await store.open(); defer { store.close() }
        let deadline = Date().addingTimeInterval(20)
        while (store.building || store.strips[a.id] == nil || store.thumbnails.count < 3) && Date() < deadline { await Task.yield() }
        #expect(store.problem == nil)
        store.select(a.id)
        for (name, width, height) in [("editor-wide", 1360.0, 860.0), ("editor-compact", 860.0, 660.0), ("editor-source", 1360.0, 860.0), ("editor-dark", 1360.0, 860.0)] {
            if name == "editor-dark" { store.showTimeline() }
            if name == "editor-source" { store.preview(try #require(store.assets.first(where: { $0.kind == .image }))) }
            let host = NSHostingView(rootView: MediaEditorWorkspace(doc: doc, store: store).environment(app).environment(\.colorScheme, name == "editor-dark" ? .dark : .light))
            let window = NSWindow(contentRect: NSRect(x: 60, y: 60, width: width, height: height), styleMask: [.titled], backing: .buffered, defer: false)
            window.title = "Cutmark editor — synthetic test"; window.contentView = host; window.orderFrontRegardless()
            let until = Date().addingTimeInterval(1)
            while Date() < until { try? await Task.sleep(for: .milliseconds(30)); host.layoutSubtreeIfNeeded() }
            let destination = URL(fileURLWithPath: directory).appending(path: name + ".png")
            let capture = Process(); capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            capture.arguments = ["-x", "-o", "-l", String(window.windowNumber), destination.path]
            try capture.run(); capture.waitUntilExit()
            if capture.terminationStatus != 0 {
                let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: rep)
                try #require(rep.representation(using: .png, properties: [:])).write(to: destination)
            }
            window.orderOut(nil)
            await store.open()
        }
    }
    func image(_ color: NSColor, at url: URL) throws {
        let image = NSImage(size: CGSize(width: 160, height: 90))
        image.lockFocus(); color.setFill(); NSRect(x: 0, y: 0, width: 160, height: 90).fill(); image.unlockFocus()
        let tiff = try #require(image.tiffRepresentation)
        let rep = try #require(NSBitmapImageRep(data: tiff))
        try #require(rep.representation(using: .png, properties: [:])).write(to: url)
    }
    private func makeVideo(_ url: URL, size: CGSize, seconds: Int, fps: Int = 30) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
        ])
        let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 64_000,
        ])
        input.expectsMediaDataInRealTime = false
        audio.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferWidthKey as String: Int(size.width),
            kCVPixelBufferHeightKey as String: Int(size.height),
        ])
        guard writer.canAdd(input), writer.canAdd(audio) else { throw TestFailure.writer }
        writer.add(input)
        writer.add(audio)
        guard writer.startWriting() else { throw writer.error ?? TestFailure.writer }
        writer.startSession(atSourceTime: .zero)
        guard let pool = adaptor.pixelBufferPool else { throw TestFailure.writer }

        for frame in 0..<(seconds * fps) {
            while !audio.isReadyForMoreMediaData { await Task.yield() }
            let sample = try audioSample(startFrame: Int64(frame * 48000 / fps), frames: Int32(48000 / fps))
            guard audio.append(sample) else { throw writer.error ?? TestFailure.writer }
            while !input.isReadyForMoreMediaData { await Task.yield() }
            var pixel: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixel) == kCVReturnSuccess, let pixel else {
                throw TestFailure.writer
            }
            CVPixelBufferLockBaseAddress(pixel, [])
            if let base = CVPixelBufferGetBaseAddress(pixel) {
                let context = try #require(CGContext(data: base, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                    bytesPerRow: CVPixelBufferGetBytesPerRow(pixel), space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue))
                context.setFillColor(NSColor(calibratedRed: 0.07, green: 0.13, blue: 0.27, alpha: 1).cgColor)
                context.fill(CGRect(origin: .zero, size: size))
                context.setFillColor(NSColor(calibratedRed: 0.25, green: 0.43, blue: 0.76, alpha: 1).cgColor)
                context.fill(CGRect(x: size.width * 0.08, y: size.height * 0.12, width: size.width * 0.84, height: size.height * 0.76))
                context.setFillColor(NSColor(calibratedRed: 0.95, green: 0.72, blue: 0.4, alpha: 1).cgColor)
                context.fill(CGRect(x: size.width * (0.16 + Double(frame % 30) / 180), y: size.height * 0.27, width: size.width * 0.3, height: size.height * 0.46))
            }
            CVPixelBufferUnlockBaseAddress(pixel, [])
            guard adaptor.append(pixel, withPresentationTime: CMTime(value: CMTimeValue(frame),
                                                                      timescale: CMTimeScale(fps))) else {
                throw writer.error ?? TestFailure.writer
            }
        }
        input.markAsFinished()
        audio.markAsFinished()
        await withCheckedContinuation { continuation in
            writer.finishWriting { continuation.resume() }
        }
        guard writer.status == .completed else { throw writer.error ?? TestFailure.writer }
    }

    private func audioSample(startFrame: Int64, frames: Int32) throws -> CMSampleBuffer {
        var format = AudioStreamBasicDescription(
            mSampleRate: 48_000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2,
            mFramesPerPacket: 1,
            mBytesPerFrame: 2,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 16,
            mReserved: 0)
        var formatDescription: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &format,
                                             layoutSize: 0, layout: nil, magicCookieSize: 0,
                                             magicCookie: nil, extensions: nil,
                                             formatDescriptionOut: &formatDescription) == noErr,
              let formatDescription else { throw TestFailure.writer }

        let byteCount = Int(frames) * 2
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
                                                 blockLength: byteCount, blockAllocator: kCFAllocatorDefault,
                                                 customBlockSource: nil, offsetToData: 0, dataLength: byteCount,
                                                 flags: 0, blockBufferOut: &block) == kCMBlockBufferNoErr,
              let block else { throw TestFailure.writer }
        let values = (0..<Int(frames)).map { Int16(sin(Double(startFrame + Int64($0)) * 2 * .pi * 440 / 48000) * 6500) }
        _ = values.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: byteCount) }

        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48_000),
                                        presentationTimeStamp: CMTime(value: startFrame, timescale: 48_000),
                                        decodeTimeStamp: .invalid)
        var sampleSize = 2
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block,
                                        formatDescription: formatDescription, sampleCount: CMItemCount(frames),
                                        sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                        sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize,
                                        sampleBufferOut: &sample) == noErr,
              let sample else { throw TestFailure.writer }
        return sample
    }

    private enum TestFailure: Error { case writer }
}
