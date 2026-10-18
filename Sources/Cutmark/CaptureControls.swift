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
        // Native mouse tracking below owns drag motion. Relying on this flag alone did not
        // move the NSHostingView-backed strip (SwiftUI intercepts the mouse down).
        isMovableByWindowBackground = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
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

/// A native draggable region for the recording strip while another app has keyboard focus.
/// The hosting view consumes pointer events over SwiftUI controls, so the panel's
/// isMovableByWindowBackground alone does not give the user a reliable drag target.
struct CapturePanelDragRegion: NSViewRepresentable {
    final class DragView: NSView {
        private var origin: NSPoint?
        private var cursor: NSPoint?

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override var mouseDownCanMoveWindow: Bool { false }
        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            origin = window.frame.origin
            cursor = NSEvent.mouseLocation
        }
        override func mouseDragged(with event: NSEvent) {
            guard let window, let origin, let cursor else { return }
            let now = NSEvent.mouseLocation
            let proposed = CapturePanelDragGeometry.origin(from: origin, mouseDown: cursor, mouseNow: now)
            // A direct window transform, with no SwiftUI animation or retained bitmap snapshot.
            // The user can move the strip between displays while recording another application.
            window.setFrameOrigin(proposed)
        }
        override func mouseUp(with event: NSEvent) { origin = nil; cursor = nil }
    }

    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ view: NSView, context: Context) {}
}

/// Native panel movement follows absolute screen coordinates, not a repeatedly re-layouted
/// SwiftUI offset. Frame origin changes are exact and reversible when the cursor moves back.
enum CapturePanelDragGeometry {
    static func origin(from start: NSPoint, mouseDown: NSPoint, mouseNow: NSPoint) -> NSPoint {
        NSPoint(x: start.x + mouseNow.x - mouseDown.x,
                y: start.y + mouseNow.y - mouseDown.y)
    }
}

/// Cutmark-native screen recording strip. Device changes remain disabled while recording because
/// swapping capture inputs mid-file would make the camera/screen timeline ambiguous. The strip only
/// exposes controls that are safe for the current recording architecture.
private struct CaptureControlBar: View {
    @Environment(AppModel.self) private var app
    @ObservedObject var camera: CameraRecorder
    @ObservedObject var screen: ScreenRecorder

    private var displayName: String {
        screen.selectedSourceName
    }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                CapturePanelDragRegion()
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.muted)
                    .allowsHitTesting(false)
            }
            .frame(width: 23, height: 34)
            .help("Drag the recording panel freely, including between displays")
            .accessibilityLabel("Move recording controls")
            HStack(spacing: 7) {
                Circle().fill(isFinishing ? Theme.muted : Theme.danger).frame(width: 8, height: 8)
                clock
            }
            .overlay(CapturePanelDragRegion())
            .help("Drag timer to move the recording panel")
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Screen recording in progress")

            Divider().frame(height: 22)

            HStack(spacing: 7) {
                Image(systemName: "mic.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.muted)
                if app.mode.captureMode(cameraPaused: camera.paused).recordsCamera {
                    LevelMeter(meter: camera.meter, track: Theme.border, fill: Theme.live)
                        .frame(width: 58, height: 4)
                        .clipShape(Capsule())
                        .help("Microphone level")
                } else {
                    // ScreenCaptureKit owns the microphone in screen-only mode. The camera meter
                    // is stopped, so showing it at zero would falsely imply silent audio.
                    Text(camera.audioID == nil ? "Mic off" : "Mic selected")
                        .font(Theme.sans(10.5, .medium)).foregroundStyle(Theme.muted)
                        .help("Screen recording handles the microphone. Live level is unavailable.")
                }
            }
            .overlay(CapturePanelDragRegion())
            .help("Drag microphone status to move the recording panel")

            HStack(spacing: 6) {
                Image(systemName: "display")
                    .font(.system(size: 11, weight: .medium))
                Text(displayName).lineLimit(1)
            }
            .overlay(CapturePanelDragRegion())
            .font(Theme.sans(12, .medium))
            .foregroundStyle(Theme.muted)
            .frame(maxWidth: 130)
            .help("Drag recording source label to move the panel")

            Button { app.addRecordingMarker() } label: {
                HStack(spacing: 5) {
                    Image(systemName: app.recordingMarkerCount == 0 ? "flag" : "flag.fill")
                        .font(.system(size: 11, weight: .semibold))
                    if app.recordingMarkerCount > 0 {
                        Text("\(app.recordingMarkerCount)").font(Theme.sans(11, .semibold).monospacedDigit())
                    }
                }
                .foregroundStyle(Theme.muted)
                .frame(minWidth: 30, minHeight: 30)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!app.canMarkRecording)
            .help("Add a marker to this take")
            .accessibilityLabel("Add marker")

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
        // Native drag surfaces are *above* the static status groups. A background NSView
        // underneath NSHostingView never receives mouseDown and is not a working drag target.
        // Do not overlay the marker or Stop button: they must keep first-click semantics.
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
