import AppKit
import SwiftUI
import Testing
@testable import Cutmark

struct CommonsGIFCatalogTests {
    @Test func onlyIncludesAnimatedGIFsWithReusableLicenses() throws {
        func page(id: Int, index: Int, license: String, frames: Int, host: String = "upload.wikimedia.org") -> [String: Any] {
            [
                "pageid": id, "index": index, "title": "File:GIF \(id).gif",
                "imageinfo": [[
                    "url": "https://\(host)/\(id).gif", "mime": "image/gif", "size": 1_200, "width": 240, "height": 140,
                    "descriptionurl": "https://commons.wikimedia.org/wiki/File:GIF_\(id).gif",
                    "metadata": [["name": "frameCount", "value": frames]],
                    "extmetadata": ["LicenseShortName": ["value": license]]
                ]]
            ]
        }
        let data = try JSONSerialization.data(withJSONObject: [
            "query": ["pages": [
                page(id: 2, index: 4, license: "CC0", frames: 3),
                page(id: 3, index: 3, license: "Public domain", frames: 4),
                page(id: 4, index: 2, license: "CC BY-SA 4.0", frames: 4),
                page(id: 5, index: 1, license: "Public domain", frames: 1),
                page(id: 6, index: 0, license: "CC0", frames: 4, host: "example.com"),
            ]],
            "continue": ["gsroffset": 20]
        ])
        let results = try CommonsGIFCatalog.decode(data)
        #expect(results.items.map(\.id) == [3, 2])
        #expect(results.nextOffset == 20)
        let request = CommonsGIFCatalog.request(query: "cámara & café", offset: 20)
        let url = try #require(request.url)
        let fields = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(fields.first { $0.name == "gsrsearch" }?.value == "cámara & café filetype:bitmap filemime:gif")
    }

    @Test @MainActor func liveCatalogAndBrowserSnapshot() async throws {
        guard let directory = ProcessInfo.processInfo.environment["CUTMARK_GIF_SNAPSHOT"] else { return }
        let catalog = CommonsGIFCatalog()
        let featured = try await catalog.search(query: "")
        try #require(featured.items.count >= 4)
        let search = try await catalog.search(query: "countdown")
        let first = try #require(search.items.first)
        #expect(!((try await catalog.animation(for: first, preview: true)).isEmpty))
        #expect(!((try await catalog.animation(for: first, preview: false)).isEmpty))

        _ = NSApplication.shared
        let host = NSHostingView(rootView: GIFBrowser { _, _ in })
        let window = NSWindow(contentRect: NSRect(x: -5000, y: -5000, width: 660, height: 490),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil); window.contentView = nil }
        try await Task.sleep(for: .seconds(2))
        host.layoutSubtreeIfNeeded()
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        try #require(rep.representation(using: .png, properties: [:]))
            .write(to: URL(fileURLWithPath: directory).appending(path: "gif-browser.png"))
    }
}
