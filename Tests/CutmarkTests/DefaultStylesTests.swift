import Foundation
import Testing
@testable import Cutmark

/// Compatibility around styles older Cutmark builds shipped and copied into the library.
@MainActor
struct DefaultStylesTests {
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let shipped = repo.appending(path: "styles")

    @Test func legacyMagazineIsNoLongerBundled() {
        let fm = FileManager.default
        #expect(!fm.fileExists(atPath: Self.shipped.appending(path: "Magazine").path))
    }

    @Test func onlyAnUnchangedLegacyMagazineStaysOffTheBoard() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appending(path: "legacy-style-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: tmp) }
        let legacy = StyleLib.style("Magazine", root: tmp)
        try fm.createDirectory(at: legacy, withIntermediateDirectories: true)
        try #"{"template":"magazine","shipped":true}"#
            .write(to: legacy.appending(path: "style.json"), atomically: true, encoding: .utf8)
        try "keep me".write(to: legacy.appending(path: "README.md"), atomically: true, encoding: .utf8)
        let exact = try #require(StyleLib.treeDigest(legacy))

        #expect(StyleLib.styleNames(root: tmp, retiredDigests: [exact]).isEmpty)
        #expect(fm.fileExists(atPath: legacy.appending(path: "README.md").path))

        let project = tmp.appending(path: "Project")
        StyleLib.choose("Magazine", project: project)
        #expect(StyleLib.chosen(project: project, root: tmp, retiredDigests: [exact]) == "Magazine")
        #expect(StyleLib.chosen(project: tmp.appending(path: "New Project"), root: tmp, retiredDigests: [exact]) == nil)
        let session = project.appending(path: "Session")
        #expect(StyleLib.chosen(session: session, pick: "Magazine", root: tmp, retiredDigests: [exact]) == "Magazine")

        let custom = StyleLib.style("Custom", root: tmp)
        try fm.createDirectory(at: custom, withIntermediateDirectories: true)
        try #"{"description":"mine"}"#.write(to: custom.appending(path: "style.json"), atomically: true, encoding: .utf8)
        #expect(StyleLib.styleNames(root: tmp, retiredDigests: [exact]) == ["Custom"])
        #expect(StyleLib.chosen(project: project, root: tmp, retiredDigests: [exact]) == "Magazine")
        #expect(StyleLib.chosen(project: tmp.appending(path: "New Project"), root: tmp, retiredDigests: [exact]) == "Custom")

        try "customized".write(to: legacy.appending(path: "README.md"), atomically: true, encoding: .utf8)
        #expect(StyleLib.styleNames(root: tmp, retiredDigests: [exact]) == ["Custom", "Magazine"])

        let userRoot = fm.temporaryDirectory.appending(path: "user-style-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: userRoot) }
        let userMagazine = StyleLib.style("Magazine", root: userRoot)
        try fm.createDirectory(at: userMagazine, withIntermediateDirectories: true)
        try #"{"template":"magazine"}"#
            .write(to: userMagazine.appending(path: "style.json"), atomically: true, encoding: .utf8)
        let userDigest = try #require(StyleLib.treeDigest(userMagazine))
        #expect(StyleLib.styleNames(root: userRoot, retiredDigests: [userDigest]) == ["Magazine"])
    }

    @Test func seedCopiesOnceAndKeepsYours() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appending(path: "seed-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: tmp) }
        let shipped = tmp.appending(path: "shipped"), root = tmp.appending(path: "lib")
        for n in ["Magazine", "Swiss"] {
            try fm.createDirectory(at: shipped.appending(path: n), withIntermediateDirectories: true)
            try "shipped".write(to: shipped.appending(path: "\(n)/README.md"), atomically: true, encoding: .utf8)
        }
        // You already have a Magazine of your own.
        try fm.createDirectory(at: StyleLib.style("Magazine", root: root), withIntermediateDirectories: true)
        try "mine".write(to: StyleLib.style("Magazine", root: root).appending(path: "README.md"), atomically: true, encoding: .utf8)
        let defaults = try #require(UserDefaults(suiteName: "seed-\(UUID().uuidString)"))

        #expect(StyleLib.seed(from: shipped, root: root, defaults: defaults) == ["Swiss"])
        #expect(try String(contentsOf: StyleLib.style("Magazine", root: root).appending(path: "README.md"), encoding: .utf8) == "mine")
        #expect(StyleLib.styleNames(root: root) == ["Magazine", "Swiss"])

        // Deleted styles stay deleted.
        try fm.removeItem(at: StyleLib.style("Swiss", root: root))
        #expect(StyleLib.seed(from: shipped, root: root, defaults: defaults).isEmpty)
        #expect(StyleLib.styleNames(root: root) == ["Magazine"])

        // Another library folder gets them.
        let other = tmp.appending(path: "other")
        #expect(StyleLib.seed(from: shipped, root: other, defaults: defaults) == ["Magazine", "Swiss"])
    }
}
