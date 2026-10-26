import AppKit
import SwiftUI

/// Reconstruct the next step from saved files and real jobs, so relaunch needs no workflow flag.
/// Private renders stay private until the creator reviews and saves a checked version.
enum SessionJourney {
    struct Files {
        var take: URL?
        var takeNumber: Int?
        var latestTakeDate: Date?
        var edit: URL?
        var draft: URL?
        var missingTakes = false
    }
    enum Step {
        case empty, missing, take(URL, Int), edit(URL), draft(URL), processing(Job), attention(Job), result(Job)
    }

    static func containedVideo(_ relative: String, session: URL) -> URL? {
        guard !relative.hasPrefix("/"), !relative.split(separator: "/").contains("..") else { return nil }
        let root = session.resolvingSymlinksInPath().standardizedFileURL
        let url = session.appending(path: relative).resolvingSymlinksInPath().standardizedFileURL
        guard url.path.hasPrefix(root.path + "/"), ["mp4", "mov", "m4v"].contains(url.pathExtension.lowercased()),
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true, (values.fileSize ?? 0) > 0 else { return nil }
        return url
    }

    static func video(for job: Job) -> URL? {
        if let video = job.outputs.compactMap({ containedVideo($0, session: job.session) }).first { return video }
        // Saving moves the private render into edits. A still-open editor must reopen that same
        // immutable version rather than show a missing private output or make a second version.
        let folder = job.session.appending(path: "edits")
        for file in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey])) ?? []
            where file.lastPathComponent.hasSuffix(".recipe.json") {
            guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 1_048_576,
                  let data = try? Data(contentsOf: file),
                  let recipe = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  recipe["render_id"] as? String == job.id,
                  let relative = recipe["edit"] as? String, relative.hasPrefix("edits/"),
                  let video = containedVideo(relative, session: job.session) else { continue }
            return video
        }
        return nil
    }

    static func load(session: URL, takes: [Take]) -> Files {
        let fm = FileManager.default
        var files = Files()
        let valid = takes.sorted {
            $0.number == $1.number ? ($0.kind == .screen && $1.kind != .screen) : $0.number > $1.number
        }.filter {
            !$0.file.contains("/") && !$0.file.contains("..") && ($0.duration ?? 0) > 0
                && containedVideo($0.file, session: session) != nil
        }
        files.missingTakes = valid.count < takes.count
        if let take = valid.first {
            files.take = session.appending(path: take.file); files.takeNumber = take.number
            files.latestTakeDate = take.startedAt
        }
        let edits = ((try? fm.contentsOfDirectory(at: session.appending(path: "edits"),
                           includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { containedVideo("edits/" + $0.lastPathComponent, session: session) != nil }
            .sorted { modified($0) > modified($1) }
        files.edit = edits.first.flatMap { modified($0) >= (files.latestTakeDate ?? .distantPast) ? $0 : nil }
        // Only advertise a resumable draft after replaying its saved operations. A stale, corrupt
        // or empty JSON file must not produce a reassuring "Continue editing" state.
        files.draft = (valid.map { session.appending(path: $0.file) } + edits).compactMap { video -> (URL, Date)? in
            guard let file = EditTimelineDraft.file(video: video, session: session),
                  let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 1_048_576,
                  let data = try? Data(contentsOf: file), let draft = try? JSONDecoder().decode(EditTimelineDraft.self, from: data),
                  !draft.actions.isEmpty else { return nil }
            let expected = video.deletingLastPathComponent().standardizedFileURL.path == session.standardizedFileURL.path ? "takes/" + video.lastPathComponent : "edits/" + video.lastPathComponent
            guard draft.base == expected,
                  modified(file) >= (files.latestTakeDate ?? .distantPast),
                  modified(file) > (files.edit.map(modified) ?? .distantPast) else { return nil }
            var replay = EditTimelineDraft(base: draft.base, fps: draft.fps, source: draft.source, segments: draft.source)
            for action in draft.actions { guard replay.apply(action) else { return nil } }
            guard replay.segments == draft.segments else { return nil }
            return (video, modified(file))
        }.sorted { $0.1 > $1.1 }.first?.0
        return files
    }

    static func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    static func next(files: Files, jobs: [Job]) -> Step {
        let ordered = jobs.filter { !$0.isGenerate }.sorted { ($0.started ?? .distantPast) > ($1.started ?? .distantPast) }
        if let live = ordered.first(where: { $0.status.live }) { return .processing(live) }
        if let latest = ordered.first, (latest.started ?? .distantPast) >= (files.latestTakeDate ?? .distantPast) {
            if latest.status == .failed || latest.status == .lost || latest.status == .stopped { return .attention(latest) }
            if latest.status == .done, latest.outputs.contains(where: {
                $0.hasPrefix("_edit/renders/") && containedVideo($0, session: latest.session) != nil
            }) { return .result(latest) }
        }
        if let draft = files.draft { return .draft(draft) }
        if let edit = files.edit { return .edit(edit) }
        if let take = files.take { return .take(take, files.takeNumber ?? 1) }
        return files.missingTakes ? .missing : .empty
    }

    static func jobTitle(_ job: Job) -> String {
        switch job.status {
        case .starting: return "Getting started…"
        case .running:
            let stage = job.stage ?? "Working on your video"
            if let p = job.progress, p.isFinite { return "\(stage) · \(Int(min(100, max(0, p * 100)).rounded()))%" }
            return stage + "…"
        case .done: return "Video ready to review"
        case .failed: return "This step didn’t finish. Open Details to continue."
        case .stopped: return "Processing stopped. Open Details to continue."
        case .lost: return "Processing was interrupted. Open Details to continue."
        }
    }
}

struct SessionJourneyBar: View {
    let doc: SessionDoc

    var body: some View {
        // The library replaces the selected document directly. Give the state owner a new
        // identity before its next disk read so another session's actions cannot remain live.
        SessionJourneyContent(doc: doc).id(doc.url)
    }
}

private struct SessionJourneyContent: View {
    @Environment(AppModel.self) private var app
    let doc: SessionDoc
    @State private var files = SessionJourney.Files()
    @State private var loaded = false
    @State private var fileVersion = 0
    @AppStorage("rightTab") private var tab = "script"
    @State private var setup = false
    @State private var details = false
    @State private var review: Job?

    private var jobs: [Job] { (app.jobs.bySession[doc.url.standardizedFileURL] ?? []).filter { !app.jobs.dismissedKeys.contains($0.key) } }
    private var step: SessionJourney.Step { SessionJourney.next(files: files, jobs: jobs) }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon).foregroundStyle(Theme.accent).opacity(loaded ? 1 : 0)
            Text(loaded ? title : "").font(Theme.sans(12, .medium)).lineLimit(1).help(title)
            Spacer(minLength: 4)
            if loaded { action }
            if SessionMode(rawValue: tab) == .record {
                Button { setup = true } label: { Label("Recording setup", systemImage: "checklist") }
                    .buttonStyle(AccentButtonStyle(kind: .quiet))
                    .cutmarkPopover(isPresented: $setup) {
                        RecordingSetupPanel(doc: doc, camera: app.camera, screen: app.screen).environment(app)
                    }
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 8).background(Theme.paper)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
        .task(id: "\(doc.url.path)|\(doc.meta.takes.count)|\(fileVersion)") {
            let session = doc.url, takes = doc.meta.takes
            let loaded = await Task.detached(priority: .utility) { SessionJourney.load(session: session, takes: takes) }.value
            guard !Task.isCancelled, doc.url == session else { return }; files = loaded; self.loaded = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .cutmarkFilesChanged)) { _ in fileVersion += 1 }
        .onReceive(NotificationCenter.default.publisher(for: .cutmarkJobsChanged)) { note in
            if note.object as? URL == doc.url, !jobs.contains(where: { $0.status.live }) { fileVersion += 1 }
        }
        .sheet(item: $review) { TimelineResultReview(job: $0).environment(app) }
        .cutmarkPopover(isPresented: $details) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Processing").font(Theme.sans(14, .semibold))
                JobsRow(session: doc.url).environment(app)
                if case .attention(let job) = step {
                    Button("Ask Cutmark for help") {
                        details = false; app.chats.open = true
                        app.chats.chat(doc.url).send(JobBoard.note(for: [job]), title: doc.meta.title, onStage: nil)
                    }.buttonStyle(AccentButtonStyle(kind: .quiet))
                }
                if let take = files.draft ?? files.take {
                    Button("Continue editing") { details = false; open(take) }
                        .buttonStyle(AccentButtonStyle(kind: .quiet))
                }
            }.padding(16).frame(width: 380)
        }
    }
    private var title: String {
        switch step {
        case .empty: return "Ready for your first take"
        case .missing: return "A recording file is missing. Check the session folder."
        case .take(_, let n): return "Take \(n) saved · ready for a first cut"
        case .edit: return "Saved video · ready to review or edit"
        case .draft: return "Your editing draft is saved"
        case .processing(let job), .attention(let job), .result(let job): return SessionJourney.jobTitle(job)
        }
    }
    private var icon: String {
        switch step {
        case .processing: return "hourglass"
        case .attention, .missing: return "exclamationmark.circle"
        case .empty: return "record.circle"
        default: return "checkmark.circle"
        }
    }
    @ViewBuilder private var action: some View {
        switch step {
        case .take(let url, _): Button("Edit take") { open(url) }.buttonStyle(AccentButtonStyle(kind: .solid))
        case .draft(let url): Button("Continue editing") { open(url) }.buttonStyle(AccentButtonStyle(kind: .solid))
        case .edit(let url): Button("Review video") { review = TimelineResultReview.savedJob(video: url, session: doc.url) }
                .buttonStyle(AccentButtonStyle(kind: .solid))
        case .result(let job): Button("Review video") { review = job }.buttonStyle(AccentButtonStyle(kind: .solid))
        case .attention, .processing: Button("Details") { details = true }.buttonStyle(AccentButtonStyle(kind: .quiet))
        case .missing: Button("Show folder") { NSWorkspace.shared.open(doc.url) }.buttonStyle(AccentButtonStyle(kind: .quiet))
        case .empty: EmptyView()
        }
    }
    private func open(_ url: URL) { TimelineEditorWindow.shared.open(video: url, doc: doc, app: app) }
}
