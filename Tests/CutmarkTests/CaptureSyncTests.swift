import Foundation
import Testing
@testable import Cutmark

struct CaptureSyncTests {
    private let referenceDate = Date(timeIntervalSince1970: 1_700_000_000.125)

    private func take(_ kind: TakeKind, number: Int = 8,
                      hostTime: Double? = 200, quality: CaptureTimingQuality? = .videoFrame) -> Take {
        Take(number: number, kind: kind, file: "take-08-\(kind.rawValue).mov",
             startedAt: referenceDate, duration: 6.5,
             captureHostTime: hostTime, timingQuality: quality)
    }

    @Test func measuredOffsetsKeepBothSignsAndSubsecondPrecision() throws {
        let camera = take(.camera, hostTime: 1000.125)
        let screenLate = take(.screen, hostTime: 1000.305)
        let screenEarly = take(.screen, hostTime: 999.945)
        #expect(abs(try #require(CaptureSync.screenMinusCameraSeconds(camera: camera, screen: screenLate)) - 0.18) < 0.000_001)
        #expect(abs(try #require(CaptureSync.screenMinusCameraSeconds(camera: camera, screen: screenEarly)) + 0.18) < 0.000_001)
    }

    @Test func missingUncertainAndUnrelatedSourcesNeverClaimSync() {
        let camera = take(.camera)
        let screen = take(.screen)
        #expect(CaptureSync.screenMinusCameraSeconds(camera: nil, screen: screen) == nil)
        #expect(CaptureSync.screenMinusCameraSeconds(camera: camera, screen: nil) == nil)
        #expect(CaptureSync.screenMinusCameraSeconds(camera: screen, screen: camera) == nil)
        #expect(CaptureSync.screenMinusCameraSeconds(camera: camera, screen: take(.screen, number: 9)) == nil)
        #expect(CaptureSync.screenMinusCameraSeconds(camera: take(.camera, quality: .callback), screen: screen) == nil)
        #expect(CaptureSync.screenMinusCameraSeconds(camera: take(.camera, quality: .unknown), screen: screen) == nil)
        #expect(CaptureSync.screenMinusCameraSeconds(camera: take(.camera, quality: nil), screen: screen) == nil)
        #expect(CaptureSync.screenMinusCameraSeconds(camera: camera, screen: take(.screen, quality: nil)) == nil)
        #expect(CaptureSync.screenMinusCameraSeconds(camera: camera, screen: take(.screen, hostTime: 0)) == nil)
        #expect(CaptureSync.screenMinusCameraSeconds(camera: camera, screen: take(.screen, hostTime: .infinity)) == nil)
        #expect(CaptureSync.screenMinusCameraSeconds(camera: camera, screen: take(.screen, hostTime: 216)) == nil)
    }

    @Test func takeRoundtripPreservesFrameStartFractionsAndHostClock() throws {
        let camera = take(.camera, hostTime: 24000.123456)
        var meta = SessionMeta(title: "A recording", createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        meta.takes = [camera]
        let data = try Store.encoder.encode(meta)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["createdAt"] as? String == "2023-11-14T22:13:20Z")
        let records = try #require(json["takes"] as? [[String: Any]])
        #expect((records[0]["startedAt"] as? String)?.contains(".125Z") == true)
        #expect(records[0]["captureHostTime"] as? Double == 24000.123456)
        #expect(records[0]["timingQuality"] as? String == "videoFrame")
        let decoded = try Store.decoder.decode(SessionMeta.self, from: data)
        #expect(abs(try #require(decoded.takes.first).startedAt.timeIntervalSince(camera.startedAt)) < 0.001)
        #expect(decoded.takes[0].captureHostTime == camera.captureHostTime)
        #expect(decoded.takes[0].timingQuality == .videoFrame)
    }

    @Test func legacySecondOnlyTakeRemainsReadableWithoutNewSyncFields() throws {
        let json = """
        {"title":"Legacy","named":false,"createdAt":"2023-11-14T22:13:20Z","takes":[
            {"number":5,"kind":"camera","file":"take-05-camera.mov",
             "startedAt":"2023-11-14T22:13:20Z","duration":8.0,"keeper":false}]}
        """
        let old = try Store.decoder.decode(SessionMeta.self, from: Data(json.utf8))
        let take = try #require(old.takes.first)
        #expect(take.captureHostTime == nil && take.timingQuality == nil)
        let saved = try Store.encoder.encode(old)
        let payload = try #require(JSONSerialization.jsonObject(with: saved) as? [String: Any])
        #expect(payload["createdAt"] as? String == "2023-11-14T22:13:20Z")
        let takes = try #require(payload["takes"] as? [[String: Any]])
        #expect(takes[0]["captureHostTime"] == nil && takes[0]["timingQuality"] == nil)
        #expect((takes[0]["startedAt"] as? String)?.hasPrefix("2023-11-14T22:13:20") == true)
        #expect(try Store.decoder.decode(SessionMeta.self, from: saved).takes.count == 1)
    }

    @Test func numericStartDatesRemainReadableByDefaultJSONDecoderCallers() throws {
        // Storyboard and other in-memory callers historically encode Date as a reference-date number.
        let json = #"{"number":1,"kind":"screen","file":"screen.mov","startedAt":12.5}"#
        let decoded = try JSONDecoder().decode(Take.self, from: Data(json.utf8))
        #expect(decoded.startedAt == Date(timeIntervalSinceReferenceDate: 12.5))
        #expect(decoded.captureHostTime == nil && decoded.timingQuality == nil)
    }

    @Test func legacySessionIDStaysIdenticalAfterRoundtripWithoutAnID() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "cutmark-sync-session-\(UUID())")
        let session = root.appending(path: "Project/Legacy")
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = """
        {"title":"Legacy","named":false,"createdAt":"2023-11-14T22:13:20Z","takes":[
            {"number":1,"kind":"camera","file":"take-01-camera.mov",
             "startedAt":"2023-11-14T22:13:20Z"}]}
        """
        let file = session.appending(path: "session.json")
        try Data(original.utf8).write(to: file)
        let before = try #require(Store.derivedID(session))
        let meta = try #require(Store.readMeta(session))
        try Store.encoder.encode(meta).write(to: file, options: .atomic)
        let after = try #require(Store.derivedID(session))
        #expect(before == after)
        #expect(Store.readMeta(session)?.id == nil)
    }

    @Test @MainActor func sessionManifestShowsOnlyMeasuredPairedVideoOffset() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "cutmark-sync-manifest-\(UUID())")
        let session = root.appending(path: "Project/Session")
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let doc = SessionDoc(url: session)
        doc.meta.takes = [take(.camera, hostTime: 1000.18), take(.screen, hostTime: 1000.0)]
        #expect(doc.save())
        let measured = try String(contentsOf: session.appending(path: "SESSION.md"), encoding: .utf8)
        #expect(measured.contains("-0.180s"))
        doc.meta.takes[0].timingQuality = .callback
        #expect(doc.save())
        let unverified = try String(contentsOf: session.appending(path: "SESSION.md"), encoding: .utf8)
        #expect(unverified.contains("Unverified"))
        #expect(!unverified.contains("-0.180s"))
    }
}
