import SwiftUI

/// Explicit editing and delivery destinations, reconstructed from the session's saved files.
struct SessionStudio: View {
    @Environment(AppModel.self) private var app
    let doc: SessionDoc
    let exporting: Bool
    @State private var files = SessionJourney.Files()
    @State private var version = 0
    @State private var loaded = false
    @State private var review: Job?
    private var jobs: [Job] { app.jobs.bySession[doc.url.standardizedFileURL] ?? [] }
    private var result: Job? {
        if case .result(let job) = SessionJourney.next(files: files, jobs: jobs) { return job }
        return files.edit.map { TimelineResultReview.savedJob(video: $0, session: doc.url) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(exporting ? "Ready for the final watch?" : "Make your best take.")
                            .font(Theme.display(30))
                        Text(exporting ? "Review the finished video, save a version, then export a copy." : "Cut mistakes, keep the good parts, and shape your video.")
                            .font(Theme.sans(14)).foregroundStyle(Theme.muted)
                    }
                    Spacer()
                    Button { SessionMode.set(exporting ? .post : .assets) } label: {
                        Label(exporting ? "Prepare a post" : "Media & sound", systemImage: exporting ? "text.bubble" : "folder")
                    }.buttonStyle(AccentButtonStyle(kind: .quiet))
                }
                if loaded {
                    if exporting {
                        delivery
                    } else {
                        editCard
                        if !doc.takeGroups.isEmpty {
                            Text("RECORDINGS").font(Theme.sans(11, .bold)).tracking(1).foregroundStyle(Theme.muted)
                            ForEach(doc.meta.takes.filter { ($0.duration ?? 0) > 0 }, id: \.file) { take in
                                HStack(spacing: 12) {
                                    Image(systemName: take.kind == .screen ? "display" : "video").foregroundStyle(Theme.accent)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("Take \(take.number) · \(take.kind == .screen ? "Screen" : "Camera")").font(Theme.sans(14, .medium))
                                        Text(SessionDoc.clock(take.duration ?? 0)).font(Theme.mono(11)).foregroundStyle(Theme.muted)
                                    }
                                    Spacer()
                                    Button("Edit take") {
                                        if let video = SessionJourney.containedVideo(take.file, session: doc.url) { open(video) }
                                    }.buttonStyle(AccentButtonStyle(kind: .quiet))
                                    .disabled(SessionJourney.containedVideo(take.file, session: doc.url) == nil)
                                }.padding(16).background(Theme.paper, in: RoundedRectangle(cornerRadius: 14))
                            }
                        }
                    }
                }
            }.padding(28).frame(maxWidth: 1000, alignment: .leading).frame(maxWidth: .infinity)
        }
        .background(Theme.canvas)
        .task(id: "\(doc.url.path)|\(version)|\(doc.meta.takes.count)") {
            let session = doc.url, takes = doc.meta.takes
            let found = await Task.detached(priority: .utility) { SessionJourney.load(session: session, takes: takes) }.value
            guard !Task.isCancelled else { return }; files = found; loaded = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .cutmarkFilesChanged)) { _ in version += 1 }
        .onReceive(NotificationCenter.default.publisher(for: .cutmarkJobsChanged)) { _ in version += 1 }
        .sheet(item: $review) { TimelineResultReview(job: $0).environment(app) }
    }

    private var editCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(files.draft == nil ? "Start with your latest recording" : "Pick up where you left off", systemImage: "scissors")
                .font(Theme.sans(19, .semibold))
            Text("Your original stays safe. Edits save automatically, and Undo brings a section back.")
                .font(Theme.sans(13)).foregroundStyle(Theme.muted)
            HStack {
                if let video = files.draft ?? files.edit ?? files.take {
                    Button(files.draft == nil ? "Open editor" : "Continue editing") { open(video) }
                        .buttonStyle(AccentButtonStyle(kind: .solid))
                } else {
                    Button("Record your first take") { SessionMode.set(.record) }.buttonStyle(AccentButtonStyle(kind: .solid))
                }
                Spacer()
                StyleChip(doc: doc, showLink: true)
            }
            Text("Styles guide assisted edits. The cut preview keeps your original look.")
                .font(Theme.sans(11)).foregroundStyle(Theme.muted)
        }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.paper, in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Theme.border, lineWidth: 1))
    }

    private var delivery: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(result == nil ? "Create your video in the editor" : "Your video is ready to review", systemImage: "play.rectangle")
                .font(Theme.sans(19, .semibold))
            Text(result == nil ? "Choose Create video when your cuts are ready. The finished version will appear here." : "Watch the full video and check the sound before exporting.")
                .font(Theme.sans(13)).foregroundStyle(Theme.muted)
            if let result {
                Button("Review & export…") { review = result }.buttonStyle(AccentButtonStyle(kind: .solid))
            } else {
                Button("Go to editor") { SessionMode.set(.edit) }.buttonStyle(AccentButtonStyle(kind: .solid))
            }
            JobsRow(session: doc.url).environment(app)
        }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.paper, in: RoundedRectangle(cornerRadius: 18))
    }
    private func open(_ video: URL) { TimelineEditorWindow.shared.open(video: video, doc: doc, app: app) }
}

struct PlanGuideWorkspace: View {
    @Environment(AppModel.self) private var app
    let doc: SessionDoc
    @State private var notes = false
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button("Script & scenes") { notes = false }.buttonStyle(AccentButtonStyle(kind: notes ? .quiet : .solid)).fixedSize()
                Button("Talking points") { notes = true }.buttonStyle(AccentButtonStyle(kind: notes ? .solid : .quiet)).fixedSize()
                Spacer()
                Text(notes ? "Prepare notes for a natural delivery" : "Write it once. Read it while recording.")
                    .font(Theme.sans(12)).foregroundStyle(Theme.muted).lineLimit(1).layoutPriority(-1)
            }.padding(.horizontal, 16).padding(.vertical, 10).background(Theme.paper)
            if notes {
                HStack {
                    Button("Notes") { app.guideMode = .notes }.buttonStyle(AccentButtonStyle(kind: app.guideMode != .board ? .solid : .quiet))
                    Button("Board") { app.guideMode = .board }.buttonStyle(AccentButtonStyle(kind: app.guideMode == .board ? .solid : .quiet))
                    Spacer()
                    Button("Use these points to record") {
                        if app.guideMode == .teleprompter { app.guideMode = .notes }
                        app.shot = nil; doc.quickTake = false; SessionMode.set(.record)
                    }.buttonStyle(AccentButtonStyle(kind: .quiet))
                }.padding(.horizontal, 16).padding(.vertical, 10)
                RecordingGuidePane(doc: doc)
            } else {
                ScriptPane(doc: doc, onRecord: { app.guideMode = .teleprompter; app.shot = nil; doc.quickTake = false; SessionMode.set(.record) })
            }
        }
    }
}
