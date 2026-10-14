/// Features that stay private for now (2026-10-04). The Comments copilot and the Performance
/// board drive the user's own signed-in Chrome with personal runbooks, so the public copy turns
/// them off (scripts/public/export.py sets this to false). The iPhone has the same switch in Look.swift.
enum Features {
    static let socialBoards = false
    /// Cutmark v0.1.0 is a macOS release. The Cutmark iOS companion remains in the source tree for
    /// future release work, but the Mac app does not expose or start the phone bridge yet.
    static let phone = false
    /// The blog article (2026-10-05): the Article side of the post tab, shown as the user's own
    /// blog shows it. Private too; the public copy hides it (export.py sets this to false).
    static let blog = false
}
