import AppKit
import SwiftUI

/// The small recording strip that stays reachable after the user switches away from Cutmark.
/// It is deliberately a non-activating panel: clicking Stop must not bring Cutmark to the front
/// or steal keyboard focus from the app being recorded. ScreenRecorder also excludes every Cutmark
/// window from ScreenCaptureKit, and `sharingType = .none` is a second line of defense.
@MainActor
final class CaptureControlPanel {
    private let panel: CapturePanelWindow
    private var placedDisplayID: CGDirectDisplayID?

    init(app: AppModel) {
        panel = CapturePanelWindow()
        let root = CaptureControlBar(camera: app.camera, screen: app.screen)
            .environment(app)
            .padding(12)
        let host = CaptureFirstMouseHostingView(rootView: root)
        host.sizingOptions = [.intrinsicContentSize]
        panel.contentView = host
        panel.setContentSize(host.fittingSize)
    }

    func present(displayID: CGDirectDisplayID?) {
        let screens = NSScreen.screens
        let screen = screens.first { screen in
            guard let n = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                  let displayID else { return false }
            return CGDirectDisplayID(n.uint32Value) == displayID
        } ?? NSScreen.main ?? screens.first

        let targetDisplayID: CGDirectDisplayID? = screen.flatMap { screen in
            (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
                .map { CGDirectDisplayID($0.uint32Value) }
        }
        if let screen,
           targetDisplayID != placedDisplayID || !screens.contains(where: { $0.visibleFrame.intersects(panel.frame) }) {
            let frame = screen.visibleFrame
            let size = panel.frame.size
            panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.minY + 18))
            placedDisplayID = targetDisplayID
        }
        panel.orderFrontRegardless()
    }

    func dismiss() { panel.orderOut(nil) }
}

/// Borderless, non-key UI that can sit above full-screen apps on every Space.
private final class CapturePanelWindow: NSPanel {
    init() {
        super.init(contentRect: .zero,
                   styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                   backing: .buffered,
                   defer: false)
        level = .statusBar
        isFloatingPanel = true
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovableByWindowBackground = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isReleasedWhenClosed = false
        animationBehavior = .utilityWindow
        sharingType = .none
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Buttons in a non-key NSPanel should work on the first click without focusing the panel.
private final class CaptureFirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Cutmark-native screen recording strip. Device changes remain disabled while recording because
/// swapping capture inputs mid-file would make the camera/screen timeline ambiguous. The strip only
/// exposes controls that are safe for the current recording architecture.
private struct CaptureControlBar: View {
    @Environment(AppModel.self) private var app
    @ObservedObject var camera: CameraRecorder
    @ObservedObject var screen: ScreenRecorder

    private var displayName: String {
        screen.displays.first { $0.id == screen.displayID }?.name ?? "Display"
    }

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 7) {
                Circle().fill(isFinishing ? Theme.muted : Theme.danger).frame(width: 8, height: 8)
                clock
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Screen recording in progress")

            Divider().frame(height: 22)

            HStack(spacing: 7) {
                Image(systemName: "mic.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.muted)
                LevelMeter(meter: camera.meter, track: Theme.border, fill: Theme.live)
                    .frame(width: 58, height: 4)
                    .clipShape(Capsule())
                    .help("Microphone level")
            }

            HStack(spacing: 6) {
                Image(systemName: "display")
                    .font(.system(size: 11, weight: .medium))
                Text(displayName).lineLimit(1)
            }
            .font(Theme.sans(12, .medium))
            .foregroundStyle(Theme.muted)
            .frame(maxWidth: 130)
            .help("Screen being recorded")

            Button(action: app.toggleRecord) {
                HStack(spacing: 7) {
                    if isFinishing {
                        ProgressView().controlSize(.small).tint(.white)
                    } else {
                        RoundedRectangle(cornerRadius: 2).fill(.white).frame(width: 10, height: 10)
                    }
                    Text(isFinishing ? "Saving…" : "Stop & Save").font(Theme.sans(12, .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 13)
                .frame(height: 32)
                .background(Theme.danger, in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(isFinishing)
            // ⌘R is local to Cutmark's key window; this strip intentionally works while another
            // app owns keyboard focus, so do not advertise a shortcut that is not global.
            .help("Stop and save the take")
            .accessibilityLabel("Stop and save recording")
        }
        .padding(.horizontal, 10)
        .frame(height: 50)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Theme.paper)
                .shadow(color: .black.opacity(0.22), radius: 18, y: 6)
        )
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.border))
        .foregroundStyle(Theme.ink)
        .fixedSize()
    }

    private var isFinishing: Bool { app.phase == .finishing }

    @ViewBuilder private var clock: some View {
        if case .recording(let start) = app.phase {
            TimelineView(.periodic(from: start, by: 1)) { context in
                Text(SessionDoc.clock(context.date.timeIntervalSince(start)))
                    .font(Theme.sans(13, .semibold).monospacedDigit())
                    .frame(minWidth: 44, alignment: .leading)
            }
        } else {
            Text(isFinishing ? "Saving" : "0:00")
                .font(Theme.sans(13, .semibold).monospacedDigit())
                .frame(minWidth: 44, alignment: .leading)
        }
    }
}
