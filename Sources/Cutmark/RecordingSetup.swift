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
            Button { inputs = true; Task { await screen.refreshCaptureSources(requestPermission: true) } } label: {
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
