import Foundation
import Testing
@testable import Takes

struct GeminiKeyTests {
    @Test func savingReplacesOnlyTheGeminiLine() {
        let old = "# keys\nGOOGLE_AI_API_KEY=old-google\nexport GEMINI_API_KEY=\"old\"\nOPENAI_API_KEY=o\n\n"
        #expect(GeminiKey.withKey(old, "new") == "# keys\nGOOGLE_AI_API_KEY=old-google\nOPENAI_API_KEY=o\nGEMINI_API_KEY=new\n")
        #expect(GeminiKey.withKey("", "k") == "GEMINI_API_KEY=k\n")
        #expect(GeminiKey.withKey("A=1", "k") == "A=1\nGEMINI_API_KEY=k\n")
    }

    @Test func saveWritesAPrivateFile() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "gemini-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appending(path: ".config/cutmark/.env")
        try GeminiKey.save("one", to: file)
        try GeminiKey.save("two", to: file)
        #expect(try String(contentsOf: file, encoding: .utf8) == "GEMINI_API_KEY=two\n")
        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
    }

    @Test func keysPreferCutmarkThenTheProcessEnvironment() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "keys-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let legacy = dir.appending(path: ".claude/.env")
        let cutmark = dir.appending(path: ".config/cutmark/.env")
        try FileManager.default.createDirectory(at: legacy.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cutmark.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "GEMINI_API_KEY=legacy\nDEEPSEEK_API_KEY=legacy-deep\n".write(to: legacy, atomically: true, encoding: .utf8)
        try "GEMINI_API_KEY=cutmark\n".write(to: cutmark, atomically: true, encoding: .utf8)

        let files = Keys.load(home: dir, environment: [:])
        #expect(files["GEMINI_API_KEY"] == "cutmark")
        #expect(files["DEEPSEEK_API_KEY"] == "legacy-deep")

        let process = Keys.load(home: dir, environment: ["GEMINI_API_KEY": "process"])
        #expect(process["GEMINI_API_KEY"] == "process")
    }

    @Test func everyUseSaysWhatHappensWithoutIt() {
        #expect(GeminiKey.uses.count == 4)
        for u in GeminiKey.uses { #expect(u.without.contains("Without it")) }
        #expect(SettingsView.SettingsPage.shown.contains(.gemini))
    }
}
