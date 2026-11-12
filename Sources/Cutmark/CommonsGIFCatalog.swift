import Foundation
import ImageIO

/// Commons reports the license and frame count for each result. Only animated
/// files marked public domain or CC0 can be saved directly into an edit.
struct CommonsGIFCatalog {
    struct Item: Codable, Equatable, Identifiable {
        let id: Int
        let title: String
        let license: String
        let source: URL
        let original: URL
        let thumbnail: URL
    }

    struct Page {
        let items: [Item]
        let nextOffset: Int?
    }

    enum Failure: LocalizedError {
        case unavailable, unreadable, tooLarge
        var errorDescription: String? {
            switch self {
            case .unavailable: "Couldn’t reach Wikimedia Commons. Try again in a moment."
            case .unreadable: "Couldn’t read this animation. Choose another GIF or try again."
            case .tooLarge: "This GIF is too large for the catalog. Choose a smaller animation."
            }
        }
    }

    private static let agent = "Cutmark/0.4 (https://github.com/TriHerm/cutmark)"
    private static let maxBytes = 12 * 1024 * 1024
    private static let featured = [
        "File:Muybridge race horse animated.gif",
        "File:Countdown-D-600.gif",
        "File:Lunar libration with phase2.gif",
        "File:GifArrowUp.gif",
        "File:GifArrowDown.gif",
        "File:Color coded racetrack large channel.gif",
        "File:10 seconds countdown.gif",
    ]

    static func request(query: String, offset: Int) -> URLRequest {
        var url = URLComponents()
        url.scheme = "https"
        url.host = "commons.wikimedia.org"
        url.path = "/w/api.php"
        var fields = [
            "action": "query", "format": "json", "formatversion": "2",
            "prop": "imageinfo", "iiprop": "url|size|mime|extmetadata|metadata",
            "iiextmetadatafilter": "LicenseShortName", "iiurlwidth": "240",
        ]
        if query.isEmpty {
            fields["titles"] = featured.joined(separator: "|")
        } else {
            fields["generator"] = "search"
            fields["gsrsearch"] = query + " filetype:bitmap filemime:gif"
            fields["gsrnamespace"] = "6"
            fields["gsrlimit"] = "20"
            fields["gsroffset"] = String(offset)
        }
        url.queryItems = fields.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        var request = URLRequest(url: url.url!, timeoutInterval: 20)
        request.setValue(agent, forHTTPHeaderField: "User-Agent")
        return request
    }

    func search(query: String, offset: Int = 0) async throws -> Page {
        let (data, response) = try await URLSession.shared.data(for: Self.request(query: query, offset: offset))
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
              response.url?.host == "commons.wikimedia.org" else { throw Failure.unavailable }
        return try Self.decode(data)
    }

    func animation(for item: Item, preview: Bool) async throws -> Data {
        let url = preview ? item.thumbnail : item.original
        let data = try await media(at: url, gifOnly: true)
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetType(source) == "com.compuserve.gif" as CFString?,
              (2...3600).contains(CGImageSourceGetCount(source)) else { throw Failure.unreadable }
        return data
    }

    func thumbnail(for item: Item) async throws -> CGImage {
        let data = try await media(at: item.thumbnail, gifOnly: false)
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, CGImageSourceGetCount(source) / 2, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 250,
              ] as CFDictionary) else { throw Failure.unreadable }
        return image
    }

    private func media(at url: URL, gifOnly: Bool) async throws -> Data {
        guard Self.isMediaURL(url) else { throw Failure.unreadable }
        var request = URLRequest(url: url, timeoutInterval: 25)
        request.setValue(Self.agent, forHTTPHeaderField: "User-Agent")
        let (file, response) = try await URLSession.shared.download(for: request)
        defer { try? FileManager.default.removeItem(at: file) }
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
              let resolved = response.url, Self.isMediaURL(resolved),
              let mime = response.mimeType, gifOnly ? mime == "image/gif" : mime.hasPrefix("image/")
        else { throw Failure.unreadable }
        guard let bytes = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize, bytes <= Self.maxBytes
        else { throw Failure.tooLarge }
        return try Data(contentsOf: file)
    }

    static func decode(_ data: Data) throws -> Page {
        let response = try JSONDecoder().decode(Response.self, from: data)
        guard response.error == nil else { throw Failure.unavailable }
        let pages = response.query?.pages ?? []
        let featuredOrder = Dictionary(uniqueKeysWithValues: featured.enumerated().map { ($1, $0) })
        let ordered = pages.sorted {
            ($0.index ?? featuredOrder[$0.title] ?? Int.max) < ($1.index ?? featuredOrder[$1.title] ?? Int.max)
        }
        let items = ordered.compactMap { page -> Item? in
            guard let info = page.imageinfo?.first, let id = page.pageid,
                  let original = info.url, isMediaURL(original),
                  let source = info.descriptionurl, source.scheme == "https", source.host == "commons.wikimedia.org",
                  let size = info.size, size > 0, size <= maxBytes,
                  info.mime == "image/gif",
                  let count = info.metadata?.first(where: { $0.name == "frameCount" })?.integer, (2...3600).contains(count),
                  let width = info.width, let height = info.height, (1...1920).contains(width), (1...1920).contains(height),
                  let license = info.extmetadata?["LicenseShortName"]?.value, ["Public domain", "CC0"].contains(license)
            else { return nil }
            let thumbnail = info.thumburl.flatMap { isMediaURL($0) ? $0 : nil } ?? original
            let filename = String(page.title.dropFirst("File:".count))
            let title = (filename as NSString).deletingPathExtension.replacingOccurrences(of: "_", with: " ")
            return Item(id: id, title: title, license: license, source: source, original: original, thumbnail: thumbnail)
        }
        return Page(items: items, nextOffset: response.continuation?.gsroffset)
    }

    private static func isMediaURL(_ url: URL) -> Bool {
        url.scheme == "https" && ["upload.wikimedia.org", "thumb.wikimedia.org"].contains(url.host ?? "")
    }

    private struct Response: Decodable {
        struct Query: Decodable { let pages: [File]? }
        struct Continuation: Decodable { let gsroffset: Int? }
        struct APIError: Decodable { let code: String }
        let query: Query?
        let continuation: Continuation?
        let error: APIError?
        enum CodingKeys: String, CodingKey { case query, error; case continuation = "continue" }
    }
    private struct File: Decodable {
        let title: String
        let pageid: Int?
        let index: Int?
        let imageinfo: [ImageInfo]?
    }
    private struct ImageInfo: Decodable {
        struct License: Decodable { let value: String }
        struct Property: Decodable {
            let name: String
            let integer: Int?
            enum CodingKeys: String, CodingKey { case name, value }
            init(from decoder: Decoder) throws {
                let values = try decoder.container(keyedBy: CodingKeys.self)
                name = try values.decode(String.self, forKey: .name)
                integer = try? values.decode(Int.self, forKey: .value)
            }
        }
        let mime: String?
        let size: Int?
        let width: Int?
        let height: Int?
        let url: URL?
        let thumburl: URL?
        let descriptionurl: URL?
        let extmetadata: [String: License]?
        let metadata: [Property]?
    }
}
