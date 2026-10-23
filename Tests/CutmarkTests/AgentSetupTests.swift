import Foundation
import Testing
@testable import Cutmark

struct AgentSetupTests {
    private let fm = FileManager.default

    private func fixture() throws -> (root: URL, source: URL, target: URL) {
        let root = fm.temporaryDirectory.appending(path: "cutmark-agent-setup-\(UUID().uuidString)")
        let source = root.appending(path: "source")
        let target = root.appending(path: "target")
        try fm.createDirectory(at: source.appending(path: "cutmark-storyboard"), withIntermediateDirectories: true)
        try write("v1", to: source.appending(path: "cutmark-storyboard/SKILL.md"))
        return (root, source, target)
    }

    private func write(_ value: String, to path: URL) throws {
        try fm.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try value.write(to: path, atomically: true, encoding: .utf8)
    }

    private func read(_ path: URL) throws -> String {
        try String(contentsOf: path, encoding: .utf8)
    }

    @Test func installsOnlyShippedSkillsAndKeepsUnrelatedFolders() throws {
        let f = try fixture()
        defer { try? fm.removeItem(at: f.root) }
        try write("keep", to: f.target.appending(path: "mine/SKILL.md"))

        let first = AgentSetup.copySkills(from: f.source, to: f.target)
        #expect(first.installed == ["cutmark-storyboard"])
        #expect(first.failed.isEmpty)
        #expect(try read(f.target.appending(path: "cutmark-storyboard/SKILL.md")) == "v1")
        #expect(try read(f.target.appending(path: "mine/SKILL.md")) == "keep")

        let repeated = AgentSetup.copySkills(from: f.source, to: f.target)
        #expect(repeated.preserved == ["cutmark-storyboard"])
        #expect(repeated.failed.isEmpty)
    }

    @Test func bundledUpdateDoesNotReplaceEvenAnUntouchedInstalledSkill() throws {
        let f = try fixture()
        defer { try? fm.removeItem(at: f.root) }
        _ = AgentSetup.copySkills(from: f.source, to: f.target)

        try write("v2", to: f.source.appending(path: "cutmark-storyboard/SKILL.md"))
        try write("new reference", to: f.source.appending(path: "cutmark-storyboard/references/example.md"))
        let preserved = AgentSetup.copySkills(from: f.source, to: f.target)
        #expect(preserved.preserved == ["cutmark-storyboard"])
        #expect(preserved.failed.isEmpty)
        #expect(try read(f.target.appending(path: "cutmark-storyboard/SKILL.md")) == "v1")
        #expect(!fm.fileExists(atPath: f.target.appending(path: "cutmark-storyboard/references/example.md").path))

        let repeated = AgentSetup.copySkills(from: f.source, to: f.target)
        #expect(repeated.preserved == ["cutmark-storyboard"])
        #expect(repeated.failed.isEmpty)
    }

    @Test func preservesEditedManagedSkillAndAddedUserFiles() throws {
        let f = try fixture()
        defer { try? fm.removeItem(at: f.root) }
        _ = AgentSetup.copySkills(from: f.source, to: f.target)

        try write("user edit", to: f.target.appending(path: "cutmark-storyboard/SKILL.md"))
        try write("my notes", to: f.target.appending(path: "cutmark-storyboard/notes.md"))
        try write("v2", to: f.source.appending(path: "cutmark-storyboard/SKILL.md"))
        let preserved = AgentSetup.copySkills(from: f.source, to: f.target)
        #expect(preserved.preserved == ["cutmark-storyboard"])
        #expect(preserved.failed.isEmpty)
        #expect(try read(f.target.appending(path: "cutmark-storyboard/SKILL.md")) == "user edit")
        #expect(try read(f.target.appending(path: "cutmark-storyboard/notes.md")) == "my notes")
    }

    @Test func addingOnlyAnExtraFilePreventsReplacement() throws {
        let f = try fixture()
        defer { try? fm.removeItem(at: f.root) }
        _ = AgentSetup.copySkills(from: f.source, to: f.target)
        try write("personal reference", to: f.target.appending(path: "cutmark-storyboard/references/custom.md"))
        try write("v2", to: f.source.appending(path: "cutmark-storyboard/SKILL.md"))

        let result = AgentSetup.copySkills(from: f.source, to: f.target)
        #expect(result.preserved == ["cutmark-storyboard"])
        #expect(try read(f.target.appending(path: "cutmark-storyboard/SKILL.md")) == "v1")
        #expect(try read(f.target.appending(path: "cutmark-storyboard/references/custom.md")) == "personal reference")
    }

    @Test func preservesLegacyUntrackedFolderEvenWhenSameAsShipped() throws {
        let f = try fixture()
        defer { try? fm.removeItem(at: f.root) }
        try write("v1", to: f.target.appending(path: "cutmark-storyboard/SKILL.md"))
        let old = AgentSetup.copySkills(from: f.source, to: f.target)
        #expect(old.preserved == ["cutmark-storyboard"])
        #expect(old.failed.isEmpty)

        try write("v2", to: f.source.appending(path: "cutmark-storyboard/SKILL.md"))
        let next = AgentSetup.copySkills(from: f.source, to: f.target)
        #expect(next.preserved == ["cutmark-storyboard"])
        #expect(try read(f.target.appending(path: "cutmark-storyboard/SKILL.md")) == "v1")
        #expect(!fm.fileExists(atPath: f.target.appending(path: "cutmark-storyboard/.cutmark-managed-skill.json").path))
    }

    @Test func preservesFolderWithInvalidReceipt() throws {
        let f = try fixture()
        defer { try? fm.removeItem(at: f.root) }
        _ = AgentSetup.copySkills(from: f.source, to: f.target)
        try write("invalid", to: f.target.appending(path: "cutmark-storyboard/.cutmark-managed-skill.json"))
        try write("v2", to: f.source.appending(path: "cutmark-storyboard/SKILL.md"))

        let result = AgentSetup.copySkills(from: f.source, to: f.target)
        #expect(result.preserved == ["cutmark-storyboard"])
        #expect(try read(f.target.appending(path: "cutmark-storyboard/SKILL.md")) == "v1")
    }

    @Test func rejectsSymlinkedSkillSourceAndLeavesUserFilesAlone() throws {
        let f = try fixture()
        defer { try? fm.removeItem(at: f.root) }
        try write("private", to: f.root.appending(path: "private.md"))
        try fm.removeItem(at: f.source.appending(path: "cutmark-storyboard/SKILL.md"))
        try fm.createSymbolicLink(at: f.source.appending(path: "cutmark-storyboard/SKILL.md"),
                                  withDestinationURL: f.root.appending(path: "private.md"))

        let result = AgentSetup.copySkills(from: f.source, to: f.target)
        #expect(result.failed["cutmark-storyboard"] != nil)
        #expect(!fm.fileExists(atPath: f.target.appending(path: "cutmark-storyboard").path))
        #expect(try read(f.root.appending(path: "private.md")) == "private")
    }

    @Test func existingSymlinkTargetCannotBeReplaced() throws {
        let f = try fixture()
        defer { try? fm.removeItem(at: f.root) }
        try write("user custom", to: f.root.appending(path: "other/SKILL.md"))
        try fm.createDirectory(at: f.target, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: f.target.appending(path: "cutmark-storyboard"),
                                  withDestinationURL: f.root.appending(path: "other"))

        let result = AgentSetup.copySkills(from: f.source, to: f.target)
        #expect(result.preserved == ["cutmark-storyboard"])
        #expect(try read(f.root.appending(path: "other/SKILL.md")) == "user custom")
        #expect((try f.target.appending(path: "cutmark-storyboard").resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink == true)
    }

    @Test func danglingSymlinkIsNeverReplaced() throws {
        let f = try fixture()
        defer { try? fm.removeItem(at: f.root) }
        try fm.createDirectory(at: f.target, withIntermediateDirectories: true)
        let dangling = f.target.appending(path: "cutmark-storyboard")
        try fm.createSymbolicLink(at: dangling, withDestinationURL: f.root.appending(path: "missing"))

        let result = AgentSetup.copySkills(from: f.source, to: f.target)
        #expect(result.preserved == ["cutmark-storyboard"])
        #expect((try dangling.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink == true)
    }

    @Test func symlinkedAncestorCannotRedirectSkillInstall() throws {
        let f = try fixture()
        defer { try? fm.removeItem(at: f.root) }
        let external = f.root.appending(path: "external")
        try fm.createDirectory(at: external, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: f.root.appending(path: ".agents"), withDestinationURL: external)

        let redirected = f.root.appending(path: ".agents/skills")
        let blocked = AgentSetup.copySkills(from: f.source, to: redirected)
        #expect(blocked.failed["setup"] != nil)
        #expect(!fm.fileExists(atPath: external.appending(path: "skills").path))

        // The link may also be two levels above the skills root.
        try fm.createDirectory(at: f.root.appending(path: "real-config"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: f.root.appending(path: "config"),
                                  withDestinationURL: f.root.appending(path: "real-config"))
        let nested = AgentSetup.copySkills(from: f.source, to: f.root.appending(path: "config/agents/skills"))
        #expect(nested.failed["setup"] != nil)
        #expect(!fm.fileExists(atPath: f.root.appending(path: "real-config/agents").path))
    }

    @Test func reportsNonDirectoryTargetWithoutChangingIt() throws {
        let f = try fixture()
        defer { try? fm.removeItem(at: f.root) }
        try write("some other file", to: f.target)
        let result = AgentSetup.copySkills(from: f.source, to: f.target)
        #expect(result.failed["setup"] != nil)
        #expect(try read(f.target) == "some other file")
    }

    @Test func supportsIndependentAgentDestinations() throws {
        let f = try fixture()
        defer { try? fm.removeItem(at: f.root) }
        let claude = f.root.appending(path: ".claude/skills")
        let agents = f.root.appending(path: ".agents/skills")
        #expect(AgentSetup.copySkills(from: f.source, to: claude).installed == ["cutmark-storyboard"])
        #expect(AgentSetup.copySkills(from: f.source, to: agents).installed == ["cutmark-storyboard"])
        try write("local tweak", to: claude.appending(path: "cutmark-storyboard/SKILL.md"))
        try write("v2", to: f.source.appending(path: "cutmark-storyboard/SKILL.md"))
        #expect(AgentSetup.copySkills(from: f.source, to: claude).preserved == ["cutmark-storyboard"])
        #expect(AgentSetup.copySkills(from: f.source, to: agents).preserved == ["cutmark-storyboard"])
        #expect(try read(claude.appending(path: "cutmark-storyboard/SKILL.md")) == "local tweak")
        #expect(try read(agents.appending(path: "cutmark-storyboard/SKILL.md")) == "v1")
    }
}
