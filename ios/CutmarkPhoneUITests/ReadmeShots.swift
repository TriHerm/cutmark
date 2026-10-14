import XCTest

/// The public README's phone pictures (2026-10-08), against the made-up library that
/// scripts/public/media.sh serves (Tests/CutmarkTests/PhoneReadmeServer.swift). Not part of check.sh.
final class ReadmeShots: XCTestCase {
    func testPhonePictures() throws {
        let env = ProcessInfo.processInfo.environment
        guard let server = env["CUTMARK_DEMO_SERVER"] else { throw XCTSkip("Only for media.sh") }
        let app = XCUIApplication()
        app.launchEnvironment["CUTMARK_SERVER"] = server
        app.launchArguments += ["-lookMode", "dark"]
        app.launch()
        if app.buttons["Connect"].waitForExistence(timeout: 5) { app.buttons["Connect"].tap() }
        if app.buttons["Videos"].waitForExistence(timeout: 15) { app.buttons["Videos"].tap() }
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS 'I let AI edit'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        sleep(3)
        shot("phone-videos")
        row.tap()
        for (tab, name) in [("Files", "phone-files"), ("Board", "phone-board"), ("Post", "phone-post")] {
            app.buttons[tab].tap()
            sleep(4)
            shot(name)
        }
    }

    private func shot(_ name: String) {
        let dir = ProcessInfo.processInfo.environment["CUTMARK_SHOTS"] ?? NSTemporaryDirectory()
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name + ".png"))
    }
}
