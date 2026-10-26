import SwiftUI

/// Recording and drafting use the existing files; the original script and take stay intact.
enum TakePlan {
    @MainActor static func voiceFile(_ doc: SessionDoc, number: Int) -> URL? {
        let takes = doc.meta.takes.filter { $0.number == number }
        guard let take = takes.first(where: { $0.kind == .camera }) ?? takes.first(where: { $0.kind == .screen }) else { return nil }
        return doc.fileURL(take)
    }

    enum Failure: LocalizedError {
        case noTranscript
        var errorDescription: String? {
            switch self {
            case .noTranscript: return "The transcript is not ready yet. Your take is saved."
            }
        }
    }

    @MainActor static func saveDraft(_ text: String, name: String, author: String, note: String, doc: SessionDoc) throws -> String {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Failure.noTranscript }
        let base = Library.slug(name)
        var slug = base, n = 2
        let fm = FileManager.default
        while doc.variants.contains(where: { $0.slug == slug }) || fm.fileExists(atPath: doc.variantsDir.appending(path: "\(slug).md").path) {
            slug = "\(base)-\(n)"; n += 1
        }
        let created = SessionDoc.iso.string(from: Date())
        let raw = FrontMatter.render([("name", name), ("author", author), ("note", note), ("created", created)], text)
        try fm.createDirectory(at: doc.variantsDir, withIntermediateDirectories: true)
        try raw.write(to: doc.variantsDir.appending(path: "\(slug).md"), atomically: true, encoding: .utf8)
        // Publish the selection only after the complete draft has reached disk.
        doc.variants.append(Variant(slug: slug, name: name, author: author, note: note, created: created, text: text))
        doc.activeDraft = slug
        return slug
    }

    @MainActor @discardableResult static func importTranscript(_ doc: SessionDoc, number: Int) throws -> String {
        guard let file = voiceFile(doc, number: number), let text = Transcript.text(for: file),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Failure.noTranscript }
        let note = "Transcript of take \(number)"
        if let saved = doc.variants.first(where: { $0.author == "transcript" && $0.note == note && $0.text == text }),
           doc.readVariants().contains(where: { $0.slug == saved.slug && $0.text == text }) {
            doc.activeDraft = saved.slug
            return saved.slug
        }
        return try saveDraft(text, name: "Take \(number) draft", author: "transcript", note: note, doc: doc)
    }

    static func organizeRequest(variant: String) -> String {
        """
        Organize the draft in variants/\(variant).md into a short video plan in this same session.
        Read get_session and the complete draft first. Refine only that alternative with update_variant;
        preserve script.md, every other alternative, recordings, and existing scene IDs where they still fit.
        Keep my meaning and voice; do not invent facts. Keep only spoken words in the draft.
        Save matching hook, main and end scenes with set_storyboard(draw=false): say must match the draft,
        filming directions go in do, and sketch is a written frame description. Do not generate images or video.
        Never create another session. Tell me the plan is ready in Plan, with this alternative selected.
        """
    }
}

extension AppModel {
    /// Prepare first, so the creator can check framing and press Record. No provider is needed.
    @discardableResult func prepareQuickTake() -> SessionDoc? {
        guard !isRecording, let doc = library.createSession() else { return nil }
        scrolling = false; shot = nil; preview = nil; board = nil
        doc.quickTake = true
        chats.onRecord = false; chats.open = false
        SessionMode.set(.record)
        return doc
    }

    func useTakeAsDraft(_ doc: SessionDoc, number: Int) throws {
        guard !isRecording, library.current === doc else { return }
        try TakePlan.importTranscript(doc, number: number)
        doc.quickTake = false
        shot = nil; preview = nil
        SessionMode.set(.write)
    }

    @discardableResult func organizeDraft(_ doc: SessionDoc) throws -> String? {
        guard !isRecording, library.current === doc, Onboarding.canWrite,
              chats.existing(doc.url)?.running != true else { return nil }
        let slug = try TakePlan.saveDraft(doc.activeText, name: "Video plan", author: "user",
                                         note: "Plan from \(doc.draftName(doc.activeDraft))", doc: doc)
        doc.quickTake = false
        chats.docked = true; chats.open = true
        chats.chat(doc.url).send(TakePlan.organizeRequest(variant: slug), title: doc.meta.title, onStage: nil)
        return slug
    }
}

struct QuickTakePane: View {
    @Environment(AppModel.self) private var app
    var doc: SessionDoc
    private var latest: Int? { doc.meta.takes.map(\.number).max() }
    private var recordTitle: String {
        switch app.phase {
        case .idle: return "Record idea"
        case .warming, .countdown: return "Cancel"
        case .recording: return "Finish take"
        case .starting: return "Preparing…"
        case .finishing: return "Saving…"
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Label("QUICK TAKE", systemImage: "record.circle").font(Theme.sans(11, .bold)).tracking(1).foregroundStyle(Theme.accent)
                Text(app.isRecording ? "Let the idea out." : "One idea is enough.")
                    .font(Theme.display(30)).foregroundStyle(Theme.ink)
                Text("Say it in your own words. You can turn the transcript into a plan after the take.")
                    .font(Theme.sans(15)).foregroundStyle(Theme.muted).lineSpacing(4)
                Button { app.toggleRecord() } label: {
                    Label(recordTitle, systemImage: app.isRecording ? "stop.fill" : "record.circle")
                }
                .buttonStyle(AccentButtonStyle(kind: .solid))
                .disabled(app.phase == .starting || app.phase == .finishing)
                if !app.isRecording {
                    Button("Add a script or notes") { doc.quickTake = false }
                        .buttonStyle(.plain).font(Theme.sans(12)).foregroundStyle(Theme.muted)
                    if let latest { TakePlanCard(doc: doc, number: latest) }
                }
            }.padding(28).frame(maxWidth: 560, alignment: .leading).frame(maxWidth: .infinity)
        }.background(Theme.paper)
    }
}

/// Also available from a take's menu, so this handoff survives relaunch and session changes.
struct TakePlanCard: View {
    @Environment(AppModel.self) private var app
    var doc: SessionDoc
    var number: Int
    var onImported: (() -> Void)? = nil
    @State private var text: String?
    @State private var failure: String?
    @State private var setup = false
    private var voice: URL? { TakePlan.voiceFile(doc, number: number) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Take \(number) is saved").font(Theme.sans(14, .semibold)).foregroundStyle(Theme.ink)
            if let text, !text.isEmpty {
                Text(text).font(Theme.sans(12)).foregroundStyle(Theme.muted).lineLimit(3)
                Button("Use transcript as draft") {
                    do { try app.useTakeAsDraft(doc, number: number); onImported?() }
                    catch { failure = error.localizedDescription }
                }.buttonStyle(AccentButtonStyle(kind: .solid))
                Text("Creates an alternative. Your original script stays saved.")
                    .font(Theme.sans(11)).foregroundStyle(Theme.faint)
            } else {
                Text(voice.map { Transcripts.shared.waiting($0) } == true ? "Transcribing on your Mac…" : "The transcript is not ready yet.")
                    .font(Theme.sans(12)).foregroundStyle(Theme.muted)
                Button(Transcripts.supported ? "Prepare transcript" : "Transcribe with Cutmark") { transcribe() }
                    .buttonStyle(PillGhostStyle()).disabled(voice == nil || voice.map { Transcripts.shared.waiting($0) } == true)
                    .cutmarkPopover(isPresented: $setup) { SetupPanel(setup: Setup.shared) }
            }
            if let failure { Text(failure).font(Theme.sans(12)).foregroundStyle(Theme.warn) }
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.canvas, in: RoundedRectangle(cornerRadius: 12))
        .disabled(app.isRecording)
        .task(id: "\(Transcripts.shared.version)-\(voice?.path ?? "")") {
            let file = voice
            text = await Task.detached(priority: .utility) { file.flatMap { Transcript.text(for: $0) } }.value
        }
    }

    private func transcribe() {
        guard let voice else { return }
        if Transcripts.supported { Transcripts.shared.add(voice); return }
        guard Onboarding.canWrite else { setup = true; return }
        app.chats.docked = true; app.chats.open = true; app.chats.onRecord = true
        app.chats.chat(doc.url).send("Read get_session first. Prepare the full local transcript for take \(number) using the cutmark-video-edit preparation workflow. Save its word times beside the take. Do not edit the video or change any scripts, scenes or other takes.", title: doc.meta.title, onStage: nil)
    }
}

struct PlanActions: View {
    @Environment(AppModel.self) private var app
    var doc: SessionDoc
    @State private var setup = false
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 12) {
                Text("Your video plan").font(Theme.sans(13, .semibold)).foregroundStyle(Theme.ink)
                Spacer(minLength: 8)
                Button("Quick take") { app.prepareQuickTake() }.buttonStyle(PillGhostStyle())
                Button { organize() } label: { Label("Organize draft", systemImage: "sparkles") }
                    .buttonStyle(PillGhostStyle())
                    .disabled(doc.activeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || app.chats.existing(doc.url)?.running == true)
                    .help("Refine a copy of this draft into scenes. Uses your connected assistant; preview images stay optional.")
                    .cutmarkPopover(isPresented: $setup) { SetupPanel(setup: Setup.shared) }
            }
            if let failure { Text(failure).font(Theme.sans(12)).foregroundStyle(Theme.warn) }
        }
        .padding(.horizontal, 16).padding(.vertical, 10).background(Theme.canvas)
        .disabled(app.isRecording)
    }

    private func organize() {
        guard Onboarding.canWrite else { setup = true; return }
        do {
            try app.organizeDraft(doc)
        } catch { failure = error.localizedDescription }
    }
}
