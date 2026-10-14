import AppKit
import SwiftUI

// About Cutmark: product identity, build information and library stats.

struct AboutView: View {
    @Environment(AppModel.self) var app

    var body: some View {
        VStack(spacing: 0) {
            hero
            VStack(spacing: 22) {
                stats
                maker
            }
            .padding(.horizontal, 28).padding(.top, 6).padding(.bottom, 22)
        }
        .frame(width: 440)
        .background(Theme.paper)
    }

    // MARK: Hero

    private var hero: some View {
        VStack(spacing: 10) {
            FloatingIcon().padding(.top, 40)
            Text(Product.name).font(Theme.display(34))
            Text("Local-first video production for people and agents.")
                .font(Theme.sans(13)).foregroundStyle(Theme.muted)
                .multilineTextAlignment(.center)
            version.padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 22)
        .background(alignment: .top) {
            ZStack {
                RadialGradient(colors: [Theme.accent.opacity(0.28), .clear], center: .top, startRadius: 0, endRadius: 260)
                RadialGradient(colors: [Theme.secondary.opacity(0.12), .clear], center: .topTrailing, startRadius: 0, endRadius: 220)
            }
            .frame(height: 300)
            .allowsHitTesting(false)
        }
    }

    private var version: some View {
        HStack(spacing: 6) {
            Text("Version \(About.version)").font(Theme.sans(11.5, .medium)).foregroundStyle(Theme.ink)
            if let build = About.build {
                Circle().fill(Theme.faint).frame(width: 3, height: 3)
                Text(build).font(Theme.mono(11)).foregroundStyle(Theme.muted)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 5)
        .background(Theme.hover, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.border, lineWidth: 0.5))
        .textSelection(.enabled)
        .help("The build Cutmark runs now")
    }

    // MARK: Library

    private var stats: some View {
        let all = app.library.grouped.values.flatMap { $0 }
        let items: [(Int, String)] = [
            (app.library.projects.count, "projects"),
            (all.count, "videos"),
            (all.reduce(0) { $0 + $1.takeCount }, "takes"),
            (all.filter(\.published).count, "published"),
        ]
        return HStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                if i > 0 { Rectangle().fill(Theme.border).frame(width: 0.5, height: 30) }
                VStack(spacing: 2) {
                    Text(item.0.formatted()).font(Theme.display(21)).monospacedDigit()
                    Text(item.1).font(Theme.sans(11)).foregroundStyle(Theme.faint)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.vertical, 12)
        .background(Theme.canvas, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.border, lineWidth: 0.5))
        .help("Your library: \(app.library.root.path)")
    }

    // MARK: Maker

    private var maker: some View {
        VStack(spacing: 12) {
            Rectangle().fill(Theme.border).frame(height: 0.5)
            HStack(spacing: 4) {
                Text("Built by").foregroundStyle(Theme.muted)
                Text(Product.organization).fontWeight(.semibold)
            }
            .font(Theme.sans(12.5))
            Text("Created by \(Product.creator)")
                .font(Theme.sans(12)).foregroundStyle(Theme.muted)
            HStack(spacing: 8) {
                ForEach(About.links, id: \.name) { l in SocialLink(link: l) }
            }
            Text("© \(Calendar.current.component(.year, from: Date()).formatted(.number.grouping(.never))) TriHerm Labs · Fernando Abishai")
                .font(Theme.sans(10.5)).foregroundStyle(Theme.faint)
        }
    }

}

enum About {
    struct Link { let name: String; let handle: String; let mark: String; let url: URL }

    static let links: [Link] = [
        Link(name: "GitHub", handle: "TriHerm/cutmark", mark: "github", url: Product.repositoryURL),
    ]

    static let repo = Product.repositoryURL

    static var version: String {
        let i = Bundle.main.infoDictionary
        // Set by build.sh from git: the newest commit's date and the commit count.
        let v = i?["CFBundleShortVersionString"] as? String ?? "0.1"
        let b = i?["CFBundleVersion"] as? String
        return b.map { "\(v) (\($0))" } ?? v
    }

    /// "642335e · Oct 4 10:33" from build.sh's BuildStamp; nil in a debug run.
    static var build: String? {
        guard let s = Bundle.main.infoDictionary?["BuildStamp"] as? String, let sp = s.firstIndex(of: " ") else { return nil }
        return s[..<sp] + " · " + s[s.index(after: sp)...]
    }
}

/// The app icon, rising and settling slowly, with its glow under it.
private struct FloatingIcon: View {
    @State private var up = false

    var body: some View {
        Image(nsImage: NSApp.applicationIconImage).resizable().interpolation(.high)
            .frame(width: 112, height: 112)
            .shadow(color: Color(red: 0.15, green: 0.6, blue: 1).opacity(up ? 0.30 : 0.42), radius: up ? 26 : 18, y: up ? 18 : 10)
            .offset(y: up ? -5 : 0)
            .onAppear { withAnimation(.easeInOut(duration: 2.6).repeatForever(autoreverses: true)) { up = true } }
            .help(Product.name)
    }
}

/// A logo, the network and the handle; opens the profile in the browser.
private struct SocialLink: View {
    let link: About.Link
    @State private var hover = false

    var body: some View {
        Link(destination: link.url) {
            HStack(spacing: 7) {
                if let img = BrandMark.image(link.mark) {
                    Image(nsImage: img).resizable().interpolation(.high).frame(width: 15, height: 15)
                }
                VStack(alignment: .leading, spacing: 0) {
                    Text(link.name).font(Theme.sans(11.5, .semibold)).foregroundStyle(Theme.ink)
                    Text(link.handle).font(Theme.sans(10.5)).foregroundStyle(Theme.faint).lineLimit(1)
                }
            }
            .padding(.leading, 10).padding(.trailing, 12).padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(hover ? Theme.hover : Theme.canvas, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.border, lineWidth: 0.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .onHover { hover = $0 }
        .animation(Theme.motion, value: hover)
        .help(link.url.absoluteString)
    }
}

/// "About Cutmark" in the app menu and sidebar menu.
struct AboutButton: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View { Button("About Cutmark") { openWindow(id: "about") } }
}
