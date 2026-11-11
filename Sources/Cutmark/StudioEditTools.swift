import SwiftUI

struct StudioEditTools: View {
    @Environment(AppModel.self) private var app
    @ObservedObject var store: MediaEditorStore
    let doc: SessionDoc
    let panel: Panel
    @Binding var reviewRange: StudioCut?

    enum Panel: String, CaseIterable {
        case clip = "Clip", transcript = "Transcript", assist = "Assist"
    }

    @State private var proposal: StudioCutProposal?
    @State private var revision: String?
    @State private var proposalError: String?
    @State private var selected: Set<StudioCut> = []
    @State private var phrases: [StudioCut] = []
    @State private var transcriptProject: MediaEditProject?
    @State private var filesVersion = 0
    @State private var setup = false

    private var running: Bool { app.chats.existing(doc.url)?.running == true }
    private var currentCuts: [StudioCut] {
        guard let proposal, proposal.revision == revision else { return [] }
        return (try? proposal.validated(for: store.project.duration)) ?? []
    }
    private var selectedCuts: [StudioCut] { currentCuts.filter { selected.contains($0) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if panel == .assist {
                assistHeader.padding(14)
                if !currentCuts.isEmpty {
                    Rule()
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(currentCuts, id: \.self) { cut in
                                timedRow(cut) {
                                    Button {
                                        if !selected.insert(cut).inserted { selected.remove(cut) }
                                    } label: {
                                        Image(systemName: selected.contains(cut) ? "checkmark.square.fill" : "square")
                                            .foregroundStyle(selected.contains(cut) ? Theme.accent : Theme.muted)
                                            .frame(width: 28, height: 30)
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("Include cut at \(MediaEditorTimeline.clock(cut.start))")
                                    .accessibilityAddTraits(selected.contains(cut) ? .isSelected : [])
                                }
                            }
                        }
                    }
                    Rule()
                    VStack(alignment: .leading, spacing: 7) {
                        let saved = selectedCuts.reduce(0) { $0 + $1.end - $1.start }
                        HStack {
                            Text("\(selectedCuts.count) selected · \(MediaEditorTimeline.clock(saved))")
                                .font(Theme.mono(10)).foregroundStyle(Theme.muted)
                            Spacer(minLength: 4)
                            Button(selectedCuts.count == currentCuts.count ? "Clear" : "Select all") {
                                selected = selectedCuts.count == currentCuts.count ? [] : Set(currentCuts)
                            }.buttonStyle(.plain).font(Theme.sans(11, .medium)).foregroundStyle(Theme.accent)
                        }
                        Button("Apply selected cuts") {
                            if let revision { store.applyCuts(selectedCuts, revision: revision) }
                        }.buttonStyle(AccentButtonStyle(kind: .solid))
                            .disabled(!store.editable || selectedCuts.isEmpty)
                    }.padding(14)
                }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Edit by transcript").font(Theme.sans(14, .semibold))
                    Text("Select a phrase to seek. Use the scissors to cut it from the timeline.")
                        .font(Theme.sans(11)).foregroundStyle(Theme.muted)
                }.padding(14)
                Rule()
                ScrollView {
                    LazyVStack(spacing: 0) {
                        if phrases.isEmpty {
                            Text(store.project.duration == 0 ? "Add a recording to see its transcript." : "No timed transcript is available yet.")
                                .font(Theme.sans(12)).foregroundStyle(Theme.muted)
                                .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                            if let video = transcribableVideo {
                                Button(Transcripts.shared.waiting(video) ? "Transcribing…" : "Transcribe video") {
                                    Transcripts.shared.add(video)
                                }.buttonStyle(AccentButtonStyle(kind: .quiet))
                                    .disabled(Transcripts.shared.waiting(video))
                            }
                        }
                        ForEach(phrases, id: \.self) { phrase in
                            timedRow(phrase) {
                                Button {
                                    if let transcriptProject { store.removePhrase(phrase, from: transcriptProject) }
                                } label: {
                                    Image(systemName: "scissors").frame(width: 28, height: 30)
                                }.buttonStyle(.plain)
                                    .disabled(!store.editable || store.project != transcriptProject)
                                    .help("Remove this phrase from the timeline")
                                    .accessibilityLabel("Cut phrase at \(MediaEditorTimeline.clock(phrase.start))")
                            }
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onFilesChanged(in: doc.url) { filesVersion += 1 }
        .onChange(of: proposal) { selected = []; reviewRange = nil }
        .onChange(of: running) { _, active in if !active { filesVersion += 1 } }
        .task(id: Refresh(project: store.project, version: filesVersion, panel: panel, transcripts: Transcripts.shared.version)) {
            let project = store.project, session = doc.url
            switch panel {
            case .clip: break
            case .transcript:
                let found = await Task.detached(priority: .utility) { StudioTranscript.phrases(in: project, session: session) }.value
                guard !Task.isCancelled else { return }
                phrases = found; transcriptProject = project
            case .assist:
                revision = try? StudioCutProposal.revision(of: project, in: session)
                do {
                    let loaded = try StudioCutProposal.load(in: session)
                    if let loaded, loaded.revision == revision { _ = try loaded.validated(for: project.duration) }
                    proposal = loaded; proposalError = nil
                } catch { proposal = nil; proposalError = error.localizedDescription }
            }
        }
    }

    private struct Refresh: Equatable {
        var project: MediaEditProject
        var version: Int
        var panel: Panel
        var transcripts: Int
    }

    private var transcribableVideo: URL? {
        guard Transcripts.supported else { return nil }
        return store.project.clips.lazy.filter { $0.lane == .video && $0.kind == .video && $0.volume > 0 }
            .compactMap { try? MediaEditProject.source($0.file, session: doc.url) }
            .first { !Transcript.exists(for: $0) }
    }

    private var assistHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Suggested cuts").font(Theme.sans(14, .semibold))
            Text("Ask Cutmark to find repeated attempts, false starts and long pauses. Review each cut before applying.")
                .font(Theme.sans(11)).foregroundStyle(Theme.muted)
            Button {
                guard Onboarding.canWrite else { setup = true; return }
                app.chats.open = true
                app.chats.chat(doc.url).send(Self.request, title: doc.meta.title, onStage: nil, shown: "Find cuts in this timeline")
            } label: {
                Label(running ? "Cutmark is working…" : "Find cuts", systemImage: "sparkles")
            }
            .buttonStyle(AccentButtonStyle(kind: .quiet))
            .disabled(!store.editable || store.project.duration == 0 || running)
            .cutmarkPopover(isPresented: $setup) { SetupPanel(setup: Setup.shared) }
            if let proposalError {
                Text(proposalError).font(Theme.sans(11)).foregroundStyle(Theme.warn)
            } else if let proposal, proposal.revision != revision {
                Text("The timeline has changed. Find cuts again for this version.")
                    .font(Theme.sans(11)).foregroundStyle(Theme.muted)
            }
        }.fixedSize(horizontal: false, vertical: true)
    }

    private func timedRow<Trailing: View>(_ cut: StudioCut, @ViewBuilder trailing: () -> Trailing) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 5) {
                Button {
                    reviewRange = cut
                    store.seek(cut.start)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(MediaEditorTimeline.clock(cut.start)) – \(MediaEditorTimeline.clock(cut.end))")
                            .font(Theme.mono(10)).foregroundStyle(Theme.accent)
                        Text(cut.reason).font(Theme.sans(12)).foregroundStyle(Theme.ink)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(.plain).disabled(store.building).help("Seek to this point")
                trailing()
            }.padding(.horizontal, 12).padding(.vertical, 9)
                .background(reviewRange == cut ? Theme.accent.opacity(0.07) : .clear)
            Rule()
        }
    }

    private static let request = """
        Review the current session's native Edit timeline. Call get_studio_timeline, then read the available words_file
        sidecars and use their source times with the returned source-to-output map. Suggest cuts for repeated attempts,
        false starts and long pauses where the evidence supports them. Keep the strongest complete attempt, the meaning,
        and natural pacing. Use propose_studio_cuts with the exact revision and output seconds. Write each reason in the
        recording's language. If there is no timed evidence or nothing to cut, say so. Do not guess ranges, modify
        project.json, render, publish, or change the source recordings.
        """
}
