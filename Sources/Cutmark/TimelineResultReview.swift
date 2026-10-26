import AppKit
import AVFoundation
import Darwin
import SwiftUI
import UniformTypeIdentifiers

/// Review the actual rendered movie, then explicitly keep a checked local version or export it.
struct TimelineResultReview: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var app
    let job: Job
    @State private var player = AVPlayer()
    @State private var video: URL?
    @State private var saved = false
    @State private var busy = false
    @State private var problem: String?
    @State private var exported = false

    static func savedJob(video: URL, session: URL) -> Job {
        Job(id: "saved-" + video.lastPathComponent, label: "Saved video", outputs: ["edits/" + video.lastPathComponent],
            fromChat: false, status: .done, started: nil, ended: nil, pid: nil, progress: nil, eta: nil,
            error: nil, stoppedBy: nil, isGenerate: false, folder: session.appending(path: ".jobs"))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(saved ? "Your saved video" : "Review your video").font(Theme.display(24))
                    Text(saved ? "Saved in this session. Export a copy whenever you’re ready." : "Play the result, then save a version when it feels right.")
                        .font(Theme.sans(12)).foregroundStyle(Theme.muted)
                }
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(AccentButtonStyle(kind: .quiet)).disabled(busy)
            }
            PlayerLayerView(player: player, showsControls: true).background(.black)
                .clipShape(RoundedRectangle(cornerRadius: 10)).frame(height: 310)
            HStack(spacing: 12) {
                Button { player.seek(to: .zero); player.play() } label: { Label("Play from start", systemImage: "play.fill") }
                Button("Pause") { player.pause() }
                Spacer()
                if saved {
                    Button { export() } label: { Label("Export video…", systemImage: "square.and.arrow.up") }
                        .buttonStyle(AccentButtonStyle(kind: .solid)).disabled(video == nil || busy)
                } else {
                    Button(busy ? "Saving…" : "Save version") { save() }
                        .buttonStyle(AccentButtonStyle(kind: .solid)).disabled(video == nil || busy)
                }
            }.buttonStyle(AccentButtonStyle(kind: .quiet))
            if let problem {
                Text(problem).font(Theme.sans(12)).foregroundStyle(Theme.danger).textSelection(.enabled)
            } else {
                Label(exported ? "Exported. Your session and recording are still saved." : "Your original recording stays saved.",
                      systemImage: "checkmark.shield").font(Theme.sans(11)).foregroundStyle(Theme.muted)
            }
        }.padding(24).frame(width: 660).background(Theme.paper).foregroundStyle(Theme.ink)
        .task {
            let resolved = await Task.detached(priority: .utility) { SessionJourney.video(for: job) }.value
            guard !Task.isCancelled else { return }
            video = resolved
            if let video {
                saved = video.deletingLastPathComponent().lastPathComponent == "edits"
                player.replaceCurrentItem(with: AVPlayerItem(url: video))
            }
            else { problem = "The finished video is no longer in this session. Your original recording is still available." }
        }
        .onDisappear { player.pause(); player.replaceCurrentItem(with: nil) }
        .interactiveDismissDisabled(busy)
    }

    private func save() {
        guard !busy else { return }; busy = true; problem = nil; player.pause()
        Task {
            defer { busy = false }
            do {
                video = try await TimelineRender.save(job: job); saved = true
                if let video { player.replaceCurrentItem(with: AVPlayerItem(url: video)) }
                app.jobs.seen(job)
                NotificationCenter.default.post(name: .cutmarkFilesChanged, object: job.session)
            } catch { problem = "Couldn’t save this version. \(error.localizedDescription)" }
        }
    }

    private func export() {
        guard let video else { return }
        player.pause()
        let panel = NSSavePanel()
        panel.title = "Export video"
        panel.allowedContentTypes = [UTType(filenameExtension: video.pathExtension) ?? .mpeg4Movie]
        panel.nameFieldStringValue = video.lastPathComponent
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        busy = true; problem = nil
        Task {
            defer { busy = false }
            do {
                try await Task.detached(priority: .userInitiated) {
                    try VideoExport.copy(video, to: destination, session: job.session)
                }.value
                exported = true
                NSWorkspace.shared.activateFileViewerSelecting([destination])
            } catch { problem = error.localizedDescription }
        }
    }
}

enum VideoExport {
    enum Failure: LocalizedError {
        case sessionDestination, copy(String)
        var errorDescription: String? {
            switch self {
            case .sessionDestination: return "Choose a folder outside this session to keep recordings and saved versions safe."
            case .copy(let detail): return "Couldn’t export the video: \(detail)"
            }
        }
    }
    /// Copy first, then atomically install the complete export in the chosen folder. A failed
    /// copy leaves any existing destination intact. Never let Export replace session content.
    static func copy(_ source: URL, to destination: URL, session: URL) throws {
        let root = session.resolvingSymlinksInPath().standardizedFileURL.path
        let target = destination.resolvingSymlinksInPath().standardizedFileURL
        guard target.path != root, !target.path.hasPrefix(root + "/") else { throw Failure.sessionDestination }
        let temporary = target.deletingLastPathComponent().appending(path: ".cutmark-export-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        do {
            try FileManager.default.copyItem(at: source, to: temporary)
            guard rename(temporary.path, target.path) == 0 else {
                throw Failure.copy(String(cString: strerror(errno)))
            }
        } catch let error as Failure { throw error }
        catch { throw Failure.copy(error.localizedDescription) }
    }
}
