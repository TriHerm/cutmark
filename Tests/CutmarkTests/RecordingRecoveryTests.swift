import Foundation
import Testing
@testable import Cutmark

struct RecordingRecoveryTests {
    private func session() throws -> URL {
        let s = FileManager.default.temporaryDirectory.appending(path: "record-recovery-\(UUID().uuidString)/P/Session")
        try FileManager.default.createDirectory(at: s, withIntermediateDirectories: true)
        return s
    }

    @Test func journalKeepsTheRecordingIntentAndExactStarts() throws {
        let s = try session()
        defer { try? FileManager.default.removeItem(at: s.deletingLastPathComponent().deletingLastPathComponent()) }
        let cam = s.appending(path: "take-03-camera.mov"), screen = s.appending(path: "take-03-screen.mov")
        RecordingRecovery.begin(in: s, number: 3, camera: cam, screen: screen, script: "alt", hook: "Start here", shot: "hook-1")
        let before = try #require(RecordingRecovery.read(s, number: 3))
        #expect(before.number == 3 && before.camera == cam.lastPathComponent && before.screen == screen.lastPathComponent)
        #expect(before.script == "alt" && before.hook == "Start here" && before.shot == "hook-1")

        let cameraStart = Date(timeIntervalSince1970: 1_700_000_000)
        let screenStart = cameraStart.addingTimeInterval(0.18)
        RecordingRecovery.started(in: s, number: 3, camera: cameraStart, screen: screenStart)
        let after = try #require(RecordingRecovery.read(s, number: 3))
        #expect(abs(try #require(after.cameraStartedAt).timeIntervalSince(cameraStart)) < 0.001)
        #expect(abs(try #require(after.screenStartedAt).timeIntervalSince(screenStart)) < 0.001)
    }

    @Test func playableCameraAndScreenBecomeTheSameTake() async throws {
        let s = try session()
        defer { try? FileManager.default.removeItem(at: s.deletingLastPathComponent().deletingLastPathComponent()) }
        let cam = s.appending(path: "take-02-camera.mov"), screen = s.appending(path: "take-02-screen.mov")
        RecordingRecovery.begin(in: s, number: 2, camera: cam, screen: screen, script: nil, hook: "Hook", shot: nil)
        let cameraStart = Date(timeIntervalSince1970: 1_700_000_100)
        RecordingRecovery.started(in: s, number: 2, camera: cameraStart, screen: cameraStart.addingTimeInterval(0.2))
        let journal = try #require(RecordingRecovery.read(s, number: 2))
        let durations = [cam.lastPathComponent: 8.2, screen.lastPathComponent: 8.0]
        let takes = await RecordingRecovery.recoverableTakes(in: s, journal: journal, meta: SessionMeta(title: "x", createdAt: Date())) { u in
            durations[u.lastPathComponent]
        }
        #expect(takes.map(\.kind) == [.camera, .screen])
        #expect(takes.allSatisfy { $0.number == 2 && $0.hook == "Hook" })
        #expect(abs(takes[0].startedAt.timeIntervalSince(cameraStart)) < 0.001)
    }

    @Test func invalidScreenDoesNotLoseAPlayableCameraAndExistingTakeIsNotDuplicated() async throws {
        let s = try session()
        defer { try? FileManager.default.removeItem(at: s.deletingLastPathComponent().deletingLastPathComponent()) }
        let cam = s.appending(path: "take-01-camera.mov"), screen = s.appending(path: "take-01-screen.mov")
        RecordingRecovery.begin(in: s, number: 1, camera: cam, screen: screen, script: nil, hook: nil, shot: nil)
        let journal = try #require(RecordingRecovery.read(s, number: 1))
        let takes = await RecordingRecovery.recoverableTakes(in: s, journal: journal, meta: SessionMeta(title: "x", createdAt: Date())) { u in
            u.lastPathComponent.contains("camera") ? 4.0 : nil
        }
        #expect(takes.count == 1 && takes[0].kind == .camera)

        var meta = SessionMeta(title: "x", createdAt: Date())
        meta.takes = takes
        let duplicate = await RecordingRecovery.recoverableTakes(in: s, journal: journal, meta: meta) { _ in 4.0 }
        #expect(duplicate.isEmpty)
    }

    @Test func playableScreenSurvivesEvenWhenCameraDidNotFinalize() async throws {
        let s = try session()
        defer { try? FileManager.default.removeItem(at: s.deletingLastPathComponent().deletingLastPathComponent()) }
        let cam = s.appending(path: "take-06-camera.mov"), screen = s.appending(path: "take-06-screen.mov")
        RecordingRecovery.begin(in: s, number: 6, camera: cam, screen: screen, script: nil, hook: nil, shot: nil)
        let journal = try #require(RecordingRecovery.read(s, number: 6))
        let takes = await RecordingRecovery.recoverableTakes(in: s, journal: journal, meta: SessionMeta(title: "x", createdAt: Date())) { u in
            u.lastPathComponent.contains("screen") ? 9.0 : nil
        }
        #expect(takes.count == 1 && takes[0].kind == .screen && takes[0].number == 6)
    }

    @Test func screenOnlyClaimNeverRequiresOrRecoversACamera() async throws {
        let s = try session()
        defer { try? FileManager.default.removeItem(at: s.deletingLastPathComponent().deletingLastPathComponent()) }
        let screen = s.appending(path: "take-07-screen.mov")
        #expect(RecordingRecovery.begin(in: s, number: 7, camera: nil, screen: screen,
                                        script: "screen-demo", hook: nil, shot: nil))
        let screenStart = Date(timeIntervalSince1970: 1_700_000_200)
        #expect(RecordingRecovery.started(in: s, number: 7, camera: nil, screen: screenStart))
        let journal = try #require(RecordingRecovery.read(s, number: 7))
        #expect(journal.camera == nil && journal.screen == screen.lastPathComponent)
        #expect(journal.cameraStartedAt == nil)

        let takes = await RecordingRecovery.recoverableTakes(
            in: s, journal: journal, meta: SessionMeta(title: "x", createdAt: Date())
        ) { u in u.lastPathComponent == screen.lastPathComponent ? 12.0 : nil }
        #expect(takes.count == 1)
        #expect(takes[0].kind == .screen && takes[0].file == screen.lastPathComponent)
        #expect(abs(takes[0].startedAt.timeIntervalSince(screenStart)) < 0.001)
    }

    @Test func recoveryClaimRequiresAtLeastOneCaptureSource() throws {
        let s = try session()
        defer { try? FileManager.default.removeItem(at: s.deletingLastPathComponent().deletingLastPathComponent()) }
        #expect(!RecordingRecovery.begin(in: s, number: 8, camera: nil, screen: nil,
                                         script: nil, hook: nil, shot: nil))
        #expect(RecordingRecovery.read(s, number: 8) == nil)
    }

    @Test func unrecoveredClaimReservesItsTakeNumber() throws {
        let s = try session()
        defer { try? FileManager.default.removeItem(at: s.deletingLastPathComponent().deletingLastPathComponent()) }
        var meta = SessionMeta(title: "x", createdAt: Date())
        meta.takes = [Take(number: 2, kind: .camera, file: "take-02-camera.mov", startedAt: Date())]
        RecordingRecovery.begin(in: s, number: 3, camera: s.appending(path: "take-03-camera.mov"), screen: nil,
                                script: nil, hook: nil, shot: nil)
        #expect(RecordingRecovery.nextTakeNumber(in: s, meta: meta) == 4)
        RecordingRecovery.clear(s, number: 3)
        #expect(RecordingRecovery.nextTakeNumber(in: s, meta: meta) == 3)

        // A crash from an older Cutmark (or a journal write that failed) can leave only the movie.
        try Data("orphan".utf8).write(to: s.appending(path: "take-05-screen.mov"))
        #expect(RecordingRecovery.nextTakeNumber(in: s, meta: meta) == 6)
    }

    @Test func aNewClaimNeverOverwritesAnOlderCrashClaim() throws {
        let s = try session()
        defer { try? FileManager.default.removeItem(at: s.deletingLastPathComponent().deletingLastPathComponent()) }
        RecordingRecovery.begin(in: s, number: 3, camera: s.appending(path: "take-03-camera.mov"), screen: nil,
                                script: "old", hook: nil, shot: nil)
        RecordingRecovery.begin(in: s, number: 4, camera: s.appending(path: "take-04-camera.mov"), screen: nil,
                                script: "new", hook: nil, shot: nil)
        let journals = RecordingRecovery.journals(in: s)
        #expect(journals.map(\.number) == [3, 4])
        #expect(journals.compactMap(\.script) == ["old", "new"])
    }

    @Test func recordingDoesNotPretendARecoveryClaimWasWritten() throws {
        let missing = FileManager.default.temporaryDirectory
            .appending(path: "record-recovery-missing-\(UUID().uuidString)/no-session")
        #expect(!RecordingRecovery.begin(in: missing, number: 1,
                                         camera: missing.appending(path: "take-01-camera.mov"), screen: nil,
                                         script: nil, hook: nil, shot: nil))
        #expect(!RecordingRecovery.started(in: missing, number: 1, camera: Date(), screen: nil))
    }

    @Test func recoveryNoticeSaysWhatSurvived() {
        #expect(RecordingRecovery.notice(number: 3, kinds: [.camera, .screen]) == "Recovered interrupted Take 3 · camera + screen")
        #expect(RecordingRecovery.notice(number: 4, kinds: [.screen]) == "Recovered interrupted Take 4 · screen")
        #expect(RecordingRecovery.notice(number: 5, kinds: [.camera]) == "Recovered interrupted Take 5 · camera")
    }
}
