import AVFoundation
import CoreGraphics
import SwiftUI

/// These are observations, not a guarantee that a future take will succeed. In particular a
/// selected microphone never counts as tested sound, and an expired sample never stays green.
enum RecordingSoundCheck {
    static func message(permission: Bool, selected: Bool, monitoring: Bool, sample: Date?, signal: Date?, now: Date = Date()) -> String {
        guard permission else { return "Microphone access is off. Allow it in macOS Settings." }
        guard selected else { return "Choose a microphone." }
        guard monitoring, let sample, now.timeIntervalSince(sample) >= 0, now.timeIntervalSince(sample) < 1 else {
            return "Sound not checked. Turn on camera preview to check the selected mic."
        }
        if let signal, now.timeIntervalSince(signal) >= 0, now.timeIntervalSince(signal) < 2 {
            return "Sound detected · say a few words and watch the meter."
        }
        return "No sound detected yet · say a few words."
    }
}

/// The quick recorder uses the same capture settings and permissions as the Record stage.
struct QuickRecordingInputs: View {
    @Environment(AppModel.self) private var app
    @ObservedObject var camera: CameraRecorder
    @ObservedObject var screen: ScreenRecorder
    @AppStorage("screenPreviewVisible") private var previewVisible = false
    @State private var sourcesOpen = false

    private var mode: Mode { app.mode.captureMode(cameraPaused: camera.paused) }
    private var screenAllowed: Bool { CGPreflightScreenCaptureAccess() }
    private var micName: String {
        camera.audioDevices.first { $0.uniqueID == camera.audioID }?.localizedName ?? "Choose microphone"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            CutmarkSwitch(selection: Binding(get: { mode }, set: { value in
                app.mode = value
                if value.recordsCamera { camera.setPaused(false) }
                if !value.recordsScreen { previewVisible = false; screen.setPreviewing(false) }
            }), options: [(.camera, "Camera"), (.screen, "Screen"), (.cameraScreen, "Both")], fill: true)
            if mode.recordsScreen {
                Button {
                    sourcesOpen = true
                    Task { await screen.refreshCaptureSources() }
                } label: {
                    inputLabel("display", name: screen.selectedSourceName)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Screen source: \(screen.selectedSourceName)")
                .cutmarkMenu(isPresented: $sourcesOpen, width: 290) {
                    if !screenAllowed {
                        MenuButton("Allow screen recording…", icon: "lock") {
                            Task { await screen.refreshCaptureSources(requestPermission: true) }
                        }
                    }
                    if !screen.displays.isEmpty { MenuLabel("Displays") }
                    for display in screen.displays {
                        MenuButton(display.name, icon: "display", checked: screen.selectedSource == .display(display.id)) {
                            screen.selectSource(.display(display.id))
                        }
                    }
                    if !screen.windows.isEmpty { MenuLabel("Windows") }
                    for window in screen.windows {
                        MenuButton(window.name, icon: "macwindow", checked: screen.selectedSource == window.source) {
                            screen.selectSource(window.source)
                        }
                    }
                    if screenAllowed {
                        MenuButton("Preview source", icon: "eye", checked: previewVisible) {
                            previewVisible.toggle()
                            screen.setPreviewing(previewVisible)
                        }
                    }
                }
            }
            if mode.recordsCamera {
                CutmarkMenuButton(help: "Choose a camera") {
                    inputLabel("video", name: camera.videoDevices.first { $0.uniqueID == camera.videoID }?.localizedName ?? "Choose camera")
                } content: {
                    for device in camera.videoDevices {
                        MenuButton(device.localizedName, icon: "video", checked: device.uniqueID == camera.videoID) {
                            camera.chooseVideo(device.uniqueID)
                        }
                    }
                    if camera.videoDevices.isEmpty { MenuLabel("No camera available") }
                }
            }
            CutmarkMenuButton(help: "Choose a microphone") {
                inputLabel("mic", name: micName)
            } content: {
                for device in camera.audioDevices {
                    MenuButton(device.localizedName, icon: "mic", checked: device.uniqueID == camera.audioID) {
                        camera.chooseAudio(device.uniqueID)
                    }
                }
                if camera.audioDevices.isEmpty { MenuLabel("No microphone available") }
            }
            if mode.recordsCamera && !camera.paused && !camera.held {
                RecordingSoundStatus(meter: camera.meter,
                    permission: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
                    deviceID: camera.audioID, monitoring: true)
            }
            CutmarkMenuButton(help: "Choose whether to count down before recording") {
                inputLabel("timer", name: app.countdownOn ? "3-second countdown" : "Start immediately")
            } content: {
                MenuButton("3 seconds", checked: app.countdownOn) { app.countdownOn = true }
                MenuButton("No countdown", checked: !app.countdownOn) { app.countdownOn = false }
            }
        }.padding(12)
            .background(Theme.canvas, in: RoundedRectangle(cornerRadius: 11))
    }

    private func inputLabel(_ icon: String, name: String) -> some View {
        HStack(spacing: 9) {
            Image(systemName: icon).foregroundStyle(Theme.accent).frame(width: 17)
            Text(name).lineLimit(1)
            Spacer(minLength: 4)
            Image(systemName: "chevron.up.chevron.down").font(.system(size: 8)).foregroundStyle(Theme.muted)
        }.font(Theme.sans(12, .medium)).frame(minHeight: 24).contentShape(Rectangle())
    }
}

struct RecordingSetupPanel: View {
    @Environment(AppModel.self) private var app
    let doc: SessionDoc
    @ObservedObject var camera: CameraRecorder
    @ObservedObject var screen: ScreenRecorder
    @AppStorage("screenPreviewVisible") private var screenPreviewVisible = false
    @State private var inputs = false
    @State private var space: String = "Checking available space…"
    private var capture: Mode { app.mode.captureMode(cameraPaused: camera.paused) }

    var body: some View {
        VStack(alignment: .leading, spacing: 17) {
            Text("Before you record").font(Theme.display(22))
            Text("\(capture.rawValue) · check the picture and sound, then press Record.")
                .font(Theme.sans(12)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            if let problem = camera.permissionProblem {
                Text(problem).font(Theme.sans(11)).foregroundStyle(Theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if capture.recordsCamera {
                row("video", "Camera", camera.videoDevices.first { $0.uniqueID == camera.videoID }?.localizedName ?? "Choose a camera")
                if camera.paused || camera.held {
                    Button("Turn on camera preview") { Task { await camera.resume() } }
                        .buttonStyle(AccentButtonStyle(kind: .quiet))
                }
            }
            if capture.recordsScreen {
                row("display", "Screen or window", screen.selectedSourceName)
                if ScreenRecorder.captureSource(selected: screen.selectedSource ?? screen.displayID.map(ScreenRecorder.CaptureSource.display),
                    availableDisplays: screen.displays.map(\.id), availableWindows: screen.windows.map(\.identity)) == nil {
                    Text("The selected source is unavailable. Choose an open window or display.")
                        .font(Theme.sans(11)).foregroundStyle(Theme.danger).fixedSize(horizontal: false, vertical: true)
                }
                Text(CGPreflightScreenCaptureAccess() ? "Screen access is allowed. Preview the selected source to check its content." : "Screen access needs permission before recording.")
                    .font(Theme.sans(11)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            }
            row("mic", "Microphone", camera.audioDevices.first { $0.uniqueID == camera.audioID }?.localizedName ?? "Choose a microphone")
            RecordingSoundStatus(meter: camera.meter,
                permission: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
                deviceID: camera.audioID, monitoring: !camera.paused && !camera.held)
            row("internaldrive", "Save location", doc.url.lastPathComponent)
            Text(space).font(Theme.sans(11)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            Button {
                inputs = true
                if app.mode.recordsScreen {
                    Task { await screen.refreshCaptureSources(requestPermission: true) }
                }
            } label: {
                Label("Change recording inputs", systemImage: "slider.horizontal.3")
            }
            .buttonStyle(AccentButtonStyle(kind: .quiet))
            .cutmarkMenu(isPresented: $inputs, width: 280) {
                DevicePanel.rows(mode: app.mode, camera: camera, screen: screen,
                    previewVisible: screenPreviewVisible,
                    selectCaptureSource: { screen.selectSource($0) },
                    selectMode: { mode in
                        app.mode = mode
                        if !mode.recordsScreen { screenPreviewVisible = false; screen.setPreviewing(false) }
                    }) {
                    screenPreviewVisible.toggle()
                    screen.setPreviewing(screenPreviewVisible, requestPermission: screenPreviewVisible)
                }
            }
            Text("After recording, “Take saved” appears only when the video file is on disk.")
                .font(Theme.sans(11)).foregroundStyle(Theme.faint).fixedSize(horizontal: false, vertical: true)
        }.padding(20).frame(width: 350).background(Theme.paper).foregroundStyle(Theme.ink)
        .task(id: doc.url) {
            if capture.recordsScreen { await screen.refreshCaptureSources(requestPermission: false) }
            let url = doc.url
            space = await Task.detached(priority: .utility) {
                let bytes = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage
                if let issue = RecordingPreflight.problem(availableBytes: bytes) { return issue }
                guard let bytes else { return "Available space could not be checked." }
                return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) + " available · recordings stay on this Mac."
            }.value
        }
    }

    private func row(_ icon: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).foregroundStyle(Theme.accent).frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(Theme.sans(12, .semibold))
                Text(detail).font(Theme.sans(12)).foregroundStyle(Theme.muted).lineLimit(2)
            }
        }
    }
}

private struct RecordingSoundStatus: View {
    @ObservedObject var meter: MicMeter
    let permission: Bool
    let deviceID: String?
    let monitoring: Bool
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            VStack(alignment: .leading, spacing: 7) {
                ProgressView(value: monitoring ? Double(meter.level) : 0).tint(Theme.accent)
                    .accessibilityLabel("Live microphone level")
                Text(RecordingSoundCheck.message(permission: permission, selected: deviceID != nil,
                    monitoring: monitoring && meter.sampleDeviceID == deviceID, sample: meter.lastSampleAt,
                    signal: meter.lastSignalAt, now: context.date))
                    .font(Theme.sans(11)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
