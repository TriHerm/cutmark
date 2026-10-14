import Foundation
import Testing
@testable import Cutmark

// A platform marked published means its post is live: the post file says posted too, so the plan
// never lists a live post as draft or ready (2026-10-09).
@MainActor
@Suite struct LivePostTests {
    @Test func markingPublishedMarksThePostPosted() throws {
        let s = FileManager.default.temporaryDirectory.appending(path: "live-post-\(UUID().uuidString)/Proj/2026-10-09-a")
        try FileManager.default.createDirectory(at: s, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: s.deletingLastPathComponent().deletingLastPathComponent()) }
        let d = SessionDoc(url: s)
        d.meta = SessionMeta(title: "A", createdAt: Date(), named: true)
        d.save()
        PostFile.write(PostFile.Content(text: "Hook.\n", meta: ["status": "ready"]), to: s, .linkedin)
        PostFile.write(PostFile.Content(text: "Tweet.\n", meta: ["status": "ready"]), to: s, .x)
        d.markPublished("LinkedIn", url: "https://www.linkedin.com/posts/a")
        let c = try #require(PostFile.read(s, .linkedin))
        #expect(c.status == .posted && c.at != nil && c.meta["url"] == "https://www.linkedin.com/posts/a")
        #expect(PostFile.read(s, .x)?.status == .ready)
    }
}
