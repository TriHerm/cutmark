import Foundation
import Testing
@testable import Takes

/// The phone gate without demo mode: every other phone test skips it (audit #9, 2026-10-11).
struct PhoneGateTests {
    private func library() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "gate-\(UUID().uuidString)")
        let s = root.appending(path: "P/2026-10-11-a")
        try FileManager.default.createDirectory(at: s, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: s.appending(path: "session.json"))
        return root
    }

    private func ask(_ path: String, login: String?, token: String? = nil, query: [String: String] = [:]) -> PhoneRequest {
        var r = PhoneRequest(method: "GET", path: path, query: query)
        if let login { r.headers["tailscale-user-login"] = login }
        if let token { r.headers["authorization"] = "Bearer \(token)" }
        return r
    }

    @Test func aForgedHeaderGetsNothingWhileTheLoginIsUnknown() throws {
        let server = PhoneServer(root: try library())
        #expect(server.gate(ask("/api/ping", login: "anyone@x.com"), needsToken: false)?.status == 503)
        #expect(server.gate(ask("/api/sessions", login: "anyone@x.com"))?.status == 401)
    }

    @Test func aPairedPhoneStillGetsInWhileTheLoginIsUnknown() throws {
        let server = PhoneServer(root: try library(), tokens: ["good"])
        #expect(server.gate(ask("/api/sessions", login: "me@x.com", token: "good")) == nil)
    }

    @Test func anotherLoginIsRefused() throws {
        let server = PhoneServer(root: try library(), login: "me@x.com", tokens: ["good"])
        #expect(server.gate(ask("/api/sessions", login: "them@x.com", token: "good"))?.status == 403)
        #expect(server.gate(ask("/api/ping", login: "them@x.com"), needsToken: false)?.status == 403)
        #expect(server.gate(ask("/api/ping", login: "ME@x.com"), needsToken: false) == nil)
        #expect(server.gate(ask("/api/sessions", login: nil, token: "good"))?.status == 403)
    }

    @Test func anUnpairedTokenGets401() async throws {
        let server = PhoneServer(root: try library(), login: "me@x.com", tokens: ["good"])
        #expect(server.gate(ask("/api/sessions", login: "me@x.com", token: "bad"))?.status == 401)
        #expect(server.gate(ask("/api/sessions", login: "me@x.com"))?.status == 401)
        guard case .json(_, 401) = await server.respond(ask("/api/sessions", login: "me@x.com", token: "bad")) else {
            Issue.record("an unpaired token got an answer"); return
        }
    }

    @Test func aSymlinkCannotLeaveTheLibrary() throws {
        let root = try library()
        let outside = FileManager.default.temporaryDirectory.appending(path: "gate-out-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("secret".utf8).write(to: outside.appending(path: "secret.txt"))
        let link = root.appending(path: "P/2026-10-11-a/link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let server = PhoneServer(root: root)
        #expect(server.inLibrary(link.appending(path: "secret.txt").path) == nil)
        #expect(server.inLibrary(root.appending(path: "P/../../x").path) == nil)
        #expect(server.inLibrary(root.appending(path: "P/2026-10-11-a/session.json").path) != nil)
    }

    @Test func anEncodedDotDotSessionIsRefused() throws {
        let server = PhoneServer(root: try library())
        let r = try #require(PhoneRequest.parse(head: "GET /api/session?id=P%2F..%2F..%2Fx HTTP/1.1\r\nHost: m"))
        #expect(r.query["id"] == "P/../../x")
        #expect(server.session(r.query["id"]) == nil)
        #expect(server.session("P/2026-10-11-a") != nil)
    }
}
