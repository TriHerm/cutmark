import Foundation
import CoreGraphics
import Testing
@testable import Cutmark

struct PostRecordingPreviewTests {
    @Test func cameraOnlySavedTakeProducesPreview() {
        let session = URL(fileURLWithPath: "/tmp/session")
        let take = Take(number: 4, kind: .camera, file: "take-04-camera.mov",
                        startedAt: .distantPast, duration: 2.5)
        let preview = PostRecordingPreview.make(sessionID: "abc123", session: session, number: 4,
                                                takes: [take], fileExists: { $0.lastPathComponent == take.file })
        #expect(preview?.number == 4)
        #expect(preview?.preferredKind == .camera)
        #expect(preview?.sourceCount == 1)
    }

    @Test func screenOnlySavedTakeProducesPreview() {
        let session = URL(fileURLWithPath: "/tmp/session")
        let take = Take(number: 2, kind: .screen, file: "take-02-screen.mov",
                        startedAt: .distantPast, duration: 1.25)
        let preview = PostRecordingPreview.make(sessionID: "abc123", session: session, number: 2,
                                                takes: [take], fileExists: { _ in true })
        #expect(preview?.preferredKind == .screen)
        #expect(preview?.sourceLabel == "Screen")
    }

    @Test func pairedTakePrefersScreenWithoutPretendingItIsComposite() {
        let session = URL(fileURLWithPath: "/tmp/session")
        let camera = Take(number: 7, kind: .camera, file: "take-07-camera.mov",
                          startedAt: .distantPast, duration: 3)
        let screen = Take(number: 7, kind: .screen, file: "take-07-screen.mov",
                          startedAt: .distantPast, duration: 3)
        let preview = PostRecordingPreview.make(sessionID: "abc123", session: session, number: 7,
                                                takes: [screen, camera], fileExists: { _ in true })
        #expect(preview?.preferredKind == .screen)
        #expect(preview?.sourceCount == 2)
        #expect(preview?.sourceLabel == "Screen preview · camera saved")
    }

    @Test func invalidOrUnpersistedTakeNeverProducesSuccessCard() {
        let session = URL(fileURLWithPath: "/tmp/session")
        let noDuration = Take(number: 1, kind: .camera, file: "take-01-camera.mov",
                              startedAt: .distantPast, duration: nil)
        let zero = Take(number: 1, kind: .screen, file: "take-01-screen.mov",
                        startedAt: .distantPast, duration: 0)
        #expect(PostRecordingPreview.make(sessionID: "abc123", session: session, number: 1,
                                          takes: [noDuration, zero], fileExists: { _ in true }) == nil)

        let valid = Take(number: 1, kind: .screen, file: "take-01-screen.mov",
                         startedAt: .distantPast, duration: 1)
        #expect(PostRecordingPreview.make(sessionID: "abc123", session: session, number: 1,
                                          takes: [valid], fileExists: { _ in false }) == nil)
        #expect(PostRecordingPreview.make(sessionID: nil, session: session, number: 1,
                                          takes: [valid], fileExists: { _ in true }) == nil)
    }

    @Test func pairedPreviewFallsBackToTheOnlyValidSavedSource() {
        let session = URL(fileURLWithPath: "/tmp/session")
        let camera = Take(number: 5, kind: .camera, file: "take-05-camera.mov",
                          startedAt: .distantPast, duration: nil)
        let screen = Take(number: 5, kind: .screen, file: "take-05-screen.mov",
                          startedAt: .distantPast, duration: 2)
        let preview = PostRecordingPreview.make(sessionID: "abc123", session: session, number: 5,
                                                takes: [camera, screen], fileExists: { _ in true })
        #expect(preview?.preferredKind == .screen)
        #expect(preview?.sourceCount == 1)
    }

    @Test func floatingCardPinsToLowerLeftOfVisibleDisplay() {
        let origin = PostRecordingPreviewPlacement.origin(
            screenFrame: CGRect(x: 1440, y: 24, width: 1920, height: 1056),
            panelSize: CGSize(width: 294, height: 230))
        #expect(origin == CGPoint(x: 1458, y: 42))
    }
}
