import AppKit
import CoreText
import SwiftUI
import Testing
@testable import Takes

@MainActor
struct MenuKitTests {
    private func items() -> [MenuItem] {
        @MenuBuilder func build() -> [MenuItem] {
            MenuButton("Open", icon: "play") {}
            MenuGroup("Move to project", icon: "folder") {
                MenuButton("Inbox") {}
                MenuButton("Takes Launch", checked: true) {}
            }
            MenuButton("Disabled", enabled: false) {}
            MenuDivider()
            MenuDivider()
            MenuButton("Move to Trash", icon: "trash", danger: true) {}
            MenuDivider()
        }
        return build()
    }

    /// Dividers never start, end or double; a closed group hides its rows.
    @Test func visibleRows() {
        let st = MenuState()
        let rows = st.visible(items()).map(\.item.title)
        #expect(rows == ["Open", "Move to project", "Disabled", "", "Move to Trash"])
        st.open.insert("g:Move to project")
        #expect(st.visible(items()).count == 7)
    }

    /// Arrow keys skip disabled rows and wrap; → opens a group, ← closes it from a child.
    @Test func keys() {
        let st = MenuState()
        let list = items()
        st.move(1, in: list)
        #expect(st.highlight == "b:Open")
        st.move(1, in: list)
        #expect(st.highlight == "g:Move to project")
        st.side(true, in: list)
        #expect(st.open.contains("g:Move to project"))
        st.move(1, in: list)
        #expect(st.highlight == "g:Move to project/b:Inbox")
        st.side(false, in: list)
        #expect(st.open.isEmpty && st.highlight == "g:Move to project")
        st.move(-1, in: list)
        st.move(-1, in: list)
        #expect(st.highlight == "b:Move to Trash")
        st.jump("o", in: list)
        #expect(st.highlight == "b:Open")
    }

    /// Typing finds rows in closed groups too.
    @Test func find() {
        let st = MenuState()
        st.query = "inb"
        #expect(st.visible(items()).map(\.item.title) == ["Move to project", "Inbox"])
    }

    /// The kit in light and dark, to look at: `TAKES_SNAPSHOT=/dir ./test.sh --filter MenuKit`.
    @Test func sheet() throws {
        guard let dir = ProcessInfo.processInfo.environment["TAKES_SNAPSHOT"] else { return }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "../../assets")
        for f in (try? FileManager.default.contentsOfDirectory(at: root.appending(path: "fonts"), includingPropertiesForKeys: nil)) ?? []
        where f.pathExtension == "ttf" { CTFontManagerRegisterFontsForURL(f as CFURL, .process, nil) }
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            NSAppearance.current = NSAppearance(named: appearance)
            let st = MenuState()
            st.open.insert("g:Move to project")
            st.highlight = "g:Move to project/b:Inbox"
            let logo = MenuState()
            logo.highlight = "b:Settings…"
            let long = MenuState()
            long.searchable = true
            long.query = "ber"
            @State var mode = "Newest"
            let v = HStack(alignment: .top, spacing: 28) {
                TakesMenuList(content: items, state: st)
                TakesMenuList(content: {
                    @MenuBuilder func b() -> [MenuItem] {
                        MenuButton("Settings…", icon: "gearshape", detail: "⌘ ,") {}
                        MenuDivider()
                        MenuLabel("Appearance")
                        MenuView("look") { LookPicker() }
                        MenuDivider()
                        MenuButton("Reveal library in Finder", icon: "folder") {}
                        MenuButton("About Takes", icon: "info.circle") {}
                    }
                    return b()
                }, state: logo, width: 264)
                TakesMenuList(content: {
                    ["Berlin", "Bern", "Bermuda", "New York", "Pacific Time", "Tokyo", "London", "Paris", "Sydney"]
                        .map { MenuButton($0, detail: "5:02 PM", checked: $0 == "Berlin") {}.item }
                }, state: long)
                VStack(alignment: .leading, spacing: 20) {
                    TakesSwitch(selection: .constant("Newest"), options: [("Newest", "Newest"), ("Most reach", "Most reach"), ("Best rate", "Best rate")])
                    TakesConfirm(title: "New project", message: "A folder for a set of videos.", confirm: "Create",
                                 field: .constant("Launch"), onConfirm: {}, onCancel: {})
                        .menuChrome()
                }
            }
            .padding(30).background(Theme.canvas)
            .environment(\.colorScheme, name == "dark" ? .dark : .light)
            let r = ImageRenderer(content: v)
            r.scale = 2
            let cg = try #require(r.cgImage)
            let data = try #require(NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]))
            try data.write(to: URL(fileURLWithPath: dir).appending(path: "menukit-\(name).png"))
        }
    }
}
