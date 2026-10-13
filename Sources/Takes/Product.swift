import Foundation

/// Public product identity for the TriHerm Labs distribution.
///
/// The implementation is derived from the MIT-licensed Takes project, but Cutmark owns its bundle,
/// library, update channel and public repository. Keep these names separate from compatibility names
/// in the on-disk format and MCP tools.
enum Product {
    static let name = "Cutmark"
    static let organization = "TriHerm Labs"
    static let bundleID = "com.triherm.cutmark"
    static let repository = "TriHerm/cutmark"
    static let repositoryURL = URL(string: "https://github.com/TriHerm/cutmark")!
    static let upstreamURL = URL(string: "https://github.com/marvtub/takes-public")!
    static let defaultLibrary = "Movies/Cutmark"
    static let appSupport = "Library/Application Support/Cutmark"
    static let logs = "Library/Logs/Cutmark"
}
