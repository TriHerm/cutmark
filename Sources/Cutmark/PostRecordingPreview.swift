import AppKit
import AVFoundation
import SwiftUI

/// A transient pointer to the take Cutmark already saved. It never owns or duplicates media.
/// The stable session id keeps the card attached if auto-naming renames the session folder.
struct PostRecordingPreview: Equatable, Sendable, Identifiable {
    let sessionID: String
    let number: Int
    let preferredKind: TakeKind
    let sourceCount: Int

    var id: String { "\(sessionID):\(number)" }

    var sourceLabel: String {
        if sourceCount > 1 { return preferredKind == .screen ? "Screen preview · camera saved" : "Camera preview · screen saved" }
        return preferredKind == .camera ? "Camera" : "Screen"
    }

    static func make(sessionID: String?, session: URL, number: Int, takes: [Take],
                     fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> Self? {
        guard let sessionID, !sessionID.isEmpty else { return nil }
        let valid = takes.filter { take in
            guard take.number == number, let duration = take.duration, duration.isFinite, duration > 0,
                  !take.file.isEmpty, !take.file.contains("/"), !take.file.contains("..") else { return false }
            return fileExists(session.appending(path: take.file))
        }
        guard !valid.isEmpty else { return nil }
        // Paired capture has two independent files, not a composite. For the Reelbird-style HUD,
        // screen is the useful review source; camera-only naturally falls back to camera.
        let preferred = valid.first(where: { $0.kind == .screen }) ?? valid[0]
        return Self(sessionID: sessionID, number: number, preferredKind: preferred.kind, sourceCount: valid.count)
    }

    @MainActor
    func matches(_ doc: SessionDoc) -> Bool { doc.meta.id == sessionID }

    @MainActor
    /// A requested source never silently substitutes the other kind. The default still
    /// prefers screen and falls back to the only saved/playable file.
    func source(in doc: SessionDoc, kind: TakeKind? = nil) -> (take: Take, url: URL)? {
        guard matches(doc) else { return nil }
        let group = doc.meta.takes.filter { $0.number == number && (kind == nil || $0.kind == kind) }
        let ordered = group.sorted { a, b in
            if a.kind == preferredKind { return true }
            if b.kind == preferredKind { return false }
            return a.kind.rawValue < b.kind.rawValue
        }
        for take in ordered {
            guard let duration = take.duration, duration.isFinite, duration > 0,
                  !take.file.isEmpty, !take.file.contains("/"), !take.file.contains("..") else { continue }
            let url = doc.fileURL(take)
            if FileManager.default.fileExists(atPath: url.path) { return (take, url) }
        }
        return nil
    }
}

enum PostRecordingPreviewPlacement {
    static func origin(screenFrame: CGRect, panelSize: CGSize, margin: CGFloat = 18) -> CGPoint {
        let x = min(screenFrame.maxX - panelSize.width - margin, screenFrame.minX + margin)
        let y = min(screenFrame.maxY - panelSize.height - margin, screenFrame.minY + margin)
        return CGPoint(x: max(screenFrame.minX, x), y: max(screenFrame.minY, y))
    }
}

/// A post-save card that stays visible even when another application still owns focus. It mirrors
/// CaptureControlPanel's non-activating/full-screen behavior but is a separate window and never
/// participates in capture. Replacing or dismissing its content releases the AVPlayer immediately.
@MainActor
final class PostRecordingPreviewPanel {
    private let panel = PostRecordingPreviewWindow()

    func present(_ recent: PostRecordingPreview, doc: SessionDoc, app: AppModel,
                 displayID: CGDirectDisplayID?) {
        guard app.library.current?.meta.id == recent.sessionID,
              recent.matches(doc), recent.source(in: doc) != nil else { dismiss(); return }
        let root = PostRecordingPreviewCard(recent: recent, doc: doc).environment(app).padding(6)
        let host = PostRecordingFirstMouseHostingView(rootView: root)
        host.sizingOptions = [.intrinsicContentSize]
        panel.contentView = host
        panel.setContentSize(host.fittingSize)

        let screens = NSScreen.screens
        let selected = screens.first { screen in
            guard let n = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                  let displayID else { return false }
            return CGDirectDisplayID(n.uint32Value) == displayID
        }
        let mouse = NSEvent.mouseLocation
        let target = selected ?? NSApp.keyWindow?.screen ?? screens.first(where: { $0.frame.contains(mouse) })
            ?? NSScreen.main ?? screens.first
        if let target {
            panel.setFrameOrigin(PostRecordingPreviewPlacement.origin(screenFrame: target.visibleFrame,
                                                                       panelSize: panel.frame.size))
        }
        panel.orderFrontRegardless()
    }

    func dismiss() {
        panel.orderOut(nil)
        panel.contentView = nil
    }
}

private final class PostRecordingPreviewWindow: NSPanel {
    init() {
        super.init(contentRect: .zero,
                   styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                   backing: .buffered, defer: false)
        level = .statusBar
        isFloatingPanel = true
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovableByWindowBackground = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isReleasedWhenClosed = false
        animationBehavior = .utilityWindow
        sharingType = .none
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class PostRecordingFirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Reelbird-style compact review card. "Saved" is status only: Stop already persisted the take.
/// Reveal is intentionally the only file action here; Play and Edit work on that same source.
@MainActor
struct PostRecordingPreviewCard: View {
    @Environment(AppModel.self) private var app
    let recent: PostRecordingPreview
    let doc: SessionDoc

    @State private var player = AVPlayer()
    @State private var loadedURL: URL?
    @State private var playing = false
    @State private var selectedKind: TakeKind?

    private var visibleSource: (take: Take, url: URL)? {
        guard app.library.current?.meta.id == recent.sessionID else { return nil }
        if let selectedKind, let selected = recent.source(in: doc, kind: selectedKind) { return selected }
        return recent.source(in: doc)
    }

    private var sourceURL: URL? {
        visibleSource?.url
    }

    private var labelForCurrentSource: String {
        // The card can outlive a missing/removed file. Never claim the other source is saved
        // unless both independently playable files still exist.
        guard hasBothSources else { return visibleSource?.take.kind == .screen ? "Screen" : "Camera" }
        return visibleSource?.take.kind == .camera
            ? "Camera preview · screen saved" : "Screen preview · camera saved"
    }

    private var hasBothSources: Bool {
        recent.source(in: doc, kind: .camera) != nil && recent.source(in: doc, kind: .screen) != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Take \(recent.number)").font(Theme.sans(12, .semibold))
                    Text(labelForCurrentSource).font(Theme.sans(10.5)).foregroundStyle(Theme.muted)
                }
                Spacer(minLength: 8)
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .help("Dismiss saved-take preview")
            }

            if hasBothSources {
                HStack(spacing: 6) {
                    sourceButton(.screen)
                    sourceButton(.camera)
                }
                .accessibilityLabel("Review saved recordings separately")
            }

            Button { togglePlayback() } label: {
                ZStack {
                    Theme.stage
                    PlayerLayerView(player: player).allowsHitTesting(false)
                    if !playing {
                        Image(systemName: "play.fill")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 42, height: 42)
                            .background(.black.opacity(0.58), in: Circle())
                    }
                }
                .frame(height: 128)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(.white.opacity(0.08), lineWidth: 0.5))
            }
            .buttonStyle(.plain)
            .help(playing ? "Pause preview" : "Play saved take")

            HStack(spacing: 8) {
                Button { togglePlayback() } label: {
                    Label(playing ? "Pause" : "Play", systemImage: playing ? "pause.fill" : "play.fill")
                }
                .buttonStyle(.plain)

                Spacer(minLength: 4)

                Label("Saved", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(Theme.muted)

                Button("Review") {
                    guard let url = sourceURL else { dismiss(); return }
                    player.pause(); playing = false
                    // A storyboard shot can return the main UI to its covering tab after
                    // Stop & Save. Open the Record stage first, or the reviewed movie would
                    // play invisibly behind that full-window page.
                    SessionMode.set(.record)
                    app.jump(to: url, at: nil)
                    NSApp.activate(ignoringOtherApps: true)
                    dismissSoon()
                }
                    .buttonStyle(.plain)
                    .help("Open the saved take in Cutmark for full review")

                Button("Edit") {
                    guard let url = sourceURL else { dismiss(); return }
                    player.pause(); playing = false
                    TimelineEditorWindow.shared.open(video: url, doc: doc, app: app)
                    dismissSoon()
                }
                .buttonStyle(.plain)
                .font(Theme.sans(11, .semibold))
                .foregroundStyle(Theme.accent)
            }
            .font(Theme.sans(10.5, .medium))
        }
        .padding(12)
        .frame(width: 282)
        .background(Theme.paper, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.border, lineWidth: 1))
        .shadow(color: Theme.shadow.opacity(1.35), radius: 18, y: 8)
        .onAppear { refreshPlayer() }
        .onChange(of: sourceURL) { _, url in
            if url == nil { dismiss() } else { refreshPlayer() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .cutmarkFilesChanged)) { _ in
            if sourceURL == nil { dismiss() } else { refreshPlayer() }
        }
        .onDisappear { player.pause(); player.replaceCurrentItem(with: nil) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Saved recording preview")
    }

    private func togglePlayback() {
        guard sourceURL != nil else { dismiss(); return }
        refreshPlayer()
        if playing {
            player.pause()
            playing = false
            return
        }
        if let item = player.currentItem, item.duration.isNumeric,
           player.currentTime().seconds >= item.duration.seconds - 0.05 {
            player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
        }
        player.play()
        playing = true
    }

    private func sourceButton(_ kind: TakeKind) -> some View {
        let isSelected = visibleSource?.take.kind == kind
        return Button {
            guard recent.source(in: doc, kind: kind) != nil else { return }
            selectedKind = kind
            refreshPlayer()
        } label: {
            Text(kind == .screen ? "Screen" : "Camera")
                .font(Theme.sans(10.5, isSelected ? .semibold : .medium))
                .foregroundStyle(isSelected ? Theme.accent : Theme.muted)
                .frame(maxWidth: .infinity, minHeight: 24)
                .background(isSelected ? Theme.accent.opacity(0.12) : Theme.stage,
                            in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .help("Review the saved \(kind.rawValue) file separately; this is not a synchronized composite")
        .accessibilityLabel("Preview \(kind.rawValue) recording")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func refreshPlayer() {
        guard let url = sourceURL else {
            player.pause(); player.replaceCurrentItem(with: nil); loadedURL = nil; playing = false
            return
        }
        guard loadedURL != url else { return }
        player.pause()
        player.replaceCurrentItem(with: AVPlayerItem(url: url))
        loadedURL = url
        playing = false
    }

    private func dismiss() {
        player.pause()
        playing = false
        app.dismissPostRecordingPreview()
    }

    private func dismissSoon() {
        Task { @MainActor in app.dismissPostRecordingPreview() }
    }
}
