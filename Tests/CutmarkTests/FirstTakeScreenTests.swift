import Foundation
import Testing
@testable import Cutmark

struct FirstTakeScreenTests {
    @MainActor @Test func screenOnlyTakeCanDriveFirstTakeFlow() {
        let root = URL(fileURLWithPath: "/tmp/cutmark-example")
        let screen = root.appending(path: "take-01-screen.mov")
        let first = FirstTake.Moment(session: root, title: "Example", number: 1,
                                     camera: nil, screen: screen, primary: screen,
                                     duration: 15, words: 45)
        #expect(first.files == [screen])
        #expect(first.primary == screen)
    }

    @MainActor @Test func pairedTakeKeepsBothMediaSources() {
        let root = URL(fileURLWithPath: "/tmp/cutmark-example")
        let cam = root.appending(path: "take-01-camera.mov")
        let screen = root.appending(path: "take-01-screen.mov")
        let first = FirstTake.Moment(session: root, title: "Example", number: 1,
                                     camera: cam, screen: screen, primary: screen,
                                     duration: 15, words: 45)
        #expect(first.files == [cam, screen])
    }
}
