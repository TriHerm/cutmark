import AppKit
import SwiftUI

// About Takes (2026-10-04): its own window in place of the plain system panel. The mascot, the
// version and the build, what the library holds, a note asking for a star or a coffee (2026-10-12,
// in place of "What Takes does"), and where to find Marvin.

struct AboutView: View {
    @Environment(AppModel.self) var app

    var body: some View {
        VStack(spacing: 0) {
            hero
            VStack(spacing: 22) {
                stats
                SupportNote()
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
            Text("Takes").font(Theme.display(34))
            Text("Write it, record it, post it. Takes helps with every step.")
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
        .help("The build Takes runs now")
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
                Text("Made by").foregroundStyle(Theme.muted)
                Text("Marvin Aziz").fontWeight(.semibold)
            }
            .font(Theme.sans(12.5))
            HStack(spacing: 8) {
                ForEach(About.links, id: \.name) { l in SocialLink(link: l) }
            }
            Text("© \(Calendar.current.component(.year, from: Date()).formatted(.number.grouping(.never))) Marvin Aziz")
                .font(Theme.sans(10.5)).foregroundStyle(Theme.faint)
        }
    }

}

enum About {
    struct Link { let name: String; let handle: String; let mark: String; let url: URL }

    static let links: [Link] = [
        Link(name: "GitHub", handle: "marvtub", mark: "github", url: URL(string: "https://github.com/marvtub")!),
        Link(name: "X", handle: "@marvinaziz", mark: "x", url: URL(string: "https://x.com/marvinaziz")!),
        Link(name: "LinkedIn", handle: "marvin-aziz", mark: "linkedin", url: URL(string: "https://www.linkedin.com/in/marvin-aziz")!),
    ]

    static let repo = URL(string: "https://github.com/marvtub/takes-public")!
    static let coffee = URL(string: "https://paypal.me/webtotheflow")!

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
            .help("Takes")
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

/// Marvin's note: who builds Takes, and two ways to thank him. Paper-warm card, handwritten
/// greeting and sign-off, a star button (with the live count) and a coffee button.
struct SupportNote: View {
    @AppStorage("about.stars") private var stars = 0

    private static let card = Theme.dynamic(0xFBF6EC, 0x29282A)
    private static let edge = Theme.dynamic(0xEADFC8, 0x3A3833)
    private static let hand = Theme.dynamic(0x5A4A2E, 0xF3E7CF)
    private static let text = Theme.dynamic(0x5B5246, 0xD6D2C8)
    private static let sign = Theme.dynamic(0x8A7B62, 0xBDB6A6)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Text("MA").font(Theme.sans(12, .bold)).foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(Theme.accent, in: Circle())
                    .overlay(Circle().strokeBorder(Self.edge, lineWidth: 1).padding(-3))
                Text("Hey, it's Marvin.").font(Theme.hand(25)).foregroundStyle(Self.hand)
            }
            Text("I build Takes on my own, in the open, and give it away for free. If it saved you an evening, here are two ways to say thanks.")
                .font(Theme.sans(13)).foregroundStyle(Self.text).lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 8) {
                SupportButton(url: About.repo, mark: "github", title: "Give it a star on GitHub",
                              detail: "Free · helps others find it", fill: Theme.ink, ink: Theme.paper) {
                    if stars > 0 {
                        HStack(spacing: 4) {
                            Image(systemName: "star.fill").font(.system(size: 10)).foregroundStyle(Color(red: 0.89, green: 0.63, blue: 0.03))
                            Text(stars.formatted()).font(Theme.mono(11.5, .semibold))
                        }
                        .foregroundStyle(Theme.paper)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Theme.paper.opacity(0.14), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    }
                }
                SupportButton(url: About.coffee, mark: "paypal", title: "Buy me a coffee",
                              detail: "Any amount · PayPal", fill: Theme.accent, ink: .white) {
                    Image(systemName: "cup.and.saucer").font(.system(size: 15, weight: .medium)).foregroundStyle(.white)
                }
            }
            .padding(.top, 2)
            Text("Thank you! Marvin").font(Theme.hand(21)).foregroundStyle(Self.sign)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 18).padding(.top, 18).padding(.bottom, 14)
        .background(Self.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Self.edge, lineWidth: 0.5))
        .task { await loadStars() }
    }

    /// The repo's star count from GitHub's public API; kept so the next open shows it at once.
    private func loadStars() async {
        guard let url = URL(string: "https://api.github.com/repos/marvtub/takes-public"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let n = json["stargazers_count"] as? Int else { return }
        stars = n
    }
}

/// One full-width link button in the note: a logo, a title over a detail line, and a trailing part.
private struct SupportButton<Trailing: View>: View {
    let url: URL
    let mark: String
    let title: String
    let detail: String
    let fill: Color
    let ink: Color
    @ViewBuilder var trailing: Trailing
    @State private var hover = false

    var body: some View {
        Link(destination: url) {
            HStack(spacing: 11) {
                if let img = BrandMark.image(mark) {
                    Image(nsImage: img).resizable().interpolation(.high).frame(width: 20, height: 20)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(Theme.sans(13, .semibold)).foregroundStyle(ink)
                    Text(detail).font(Theme.sans(11)).foregroundStyle(ink.opacity(0.7))
                }
                Spacer(minLength: 0)
                trailing
            }
            .padding(.horizontal, 12)
            .frame(height: 46)
            .background(fill, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .shadow(color: fill.opacity(hover ? 0.35 : 0), radius: 12, y: 6)
            .offset(y: hover ? -1 : 0)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .onHover { hover = $0 }
        .animation(Theme.motion, value: hover)
        .help(url.absoluteString)
    }
}

/// "About Takes" in the app menu and in the sidebar's Takes menu.
struct AboutButton: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View { Button("About Takes") { openWindow(id: "about") } }
}
