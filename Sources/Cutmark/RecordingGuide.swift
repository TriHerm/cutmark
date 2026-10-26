import SwiftUI

enum RecordingGuideMode: String, CaseIterable, Identifiable {
    case teleprompter, notes, board
    var id: String { rawValue }
    var title: String {
        switch self {
        case .teleprompter: return "Teleprompter"
        case .notes: return "Notes"
        case .board: return "Board"
        }
    }
}

/// Plain text shared with MCP. A blank line separates talking points; the first line is the title.
enum RecordingGuide {
    static let file = "recording-notes.md"
    struct Card: Equatable {
        var title: String
        var detail: String
    }
    static func cards(_ text: String) -> [Card] {
        var blocks: [[String]] = [], lines: [String] = []
        for line in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: .newlines) {
            let line = line.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                if !lines.isEmpty { blocks.append(lines); lines = [] }
            } else { lines.append(line) }
        }
        if !lines.isEmpty { blocks.append(lines) }
        return blocks.map { Card(title: $0[0], detail: $0.dropFirst().joined(separator: "\n")) }
    }
    static func position(_ index: Int, count: Int) -> Int { min(max(0, index), count) }
}

struct RecordingGuidePicker: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        CutmarkSwitch(selection: Binding(get: { app.guideMode }, set: { app.guideMode = $0 }),
                      title: { $0.title }, fill: true)
            .padding(12)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Recording guide")
    }
}

struct RecordingGuidePane: View {
    @Environment(AppModel.self) private var app
    var doc: SessionDoc
    @State private var editing = false
    private var cards: [RecordingGuide.Card] { RecordingGuide.cards(doc.recordingNotes) }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(app.guideMode == .board ? "Your video’s direction" : "Your talking points")
                    .font(Theme.sans(15, .semibold))
                Spacer()
                if !app.isRecording {
                    Button(editing ? "Done editing" : "Edit notes") { editing.toggle() }
                        .buttonStyle(PillGhostStyle())
                }
                Button { NotchPanel.shared.toggle(app) } label: {
                    Image(systemName: "macbook").frame(width: 28, height: 28)
                }
                .buttonStyle(PillGhostStyle())
                .help("Show your guide near the camera")
            }.padding(16)
            if let error = doc.recordingNotesError {
                HStack(alignment: .top, spacing: 12) {
                    Text(error).font(Theme.sans(12)).foregroundStyle(Theme.danger)
                    Spacer(minLength: 0)
                    if !app.isRecording {
                        Button(doc.recordingNotesUnsaved ? "Retry save" : "Retry loading") {
                            if doc.recordingNotesUnsaved { doc.setRecordingNotes(doc.recordingNotes) }
                            else { doc.reloadRecordingNotes() }
                        }.buttonStyle(PillGhostStyle()).font(Theme.sans(12, .medium))
                    }
                }.padding(.horizontal, 16)
            }
            if !app.isRecording && (editing || cards.isEmpty) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Add one talking point per paragraph. Put supporting notes on the lines below it. Leave a blank line before the next point.")
                        .font(Theme.sans(13)).foregroundStyle(Theme.muted)
                    TextEditor(text: Binding(get: { doc.recordingNotes }, set: { doc.setRecordingNotes($0) }))
                        .font(Theme.sans(18)).scrollContentBackground(.hidden)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(12).background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
                        .accessibilityLabel("Recording notes")
                    Text(doc.recordingNotesUnsaved
                         ? "Your latest notes are not saved yet. Retry before leaving this session."
                         : "Notes are saved with this session. Your script stays separate.")
                        .font(Theme.sans(12)).foregroundStyle(Theme.muted)
                }.padding(16)
            } else if app.guideMode == .board {
                RecordingGuideBoard(cards: cards, index: cueBinding)
            } else {
                RecordingNotesView(cards: cards)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { editing = cards.isEmpty }
        .onChange(of: app.isRecording) { _, on in if on { editing = false } }
        .onChange(of: doc.url) { editing = cards.isEmpty }
    }

    private var cueBinding: Binding<Int> {
        Binding(get: { doc.recordingCue }, set: { doc.recordingCue = $0 })
    }
}

struct RecordingNotesView: View {
    let cards: [RecordingGuide.Card]
    var fontSize: Double = 22
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if cards.isEmpty { Text("Add talking points in Record → Notes.").foregroundStyle(Theme.muted) }
                ForEach(cards.indices, id: \.self) { i in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(cards[i].title).font(Theme.sans(fontSize, .semibold))
                        if !cards[i].detail.isEmpty {
                            Text(cards[i].detail).font(Theme.sans(max(14, fontSize - 3))).foregroundStyle(Theme.muted)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct RecordingGuideBoard: View {
    let cards: [RecordingGuide.Card]
    @Binding var index: Int
    var compact = false
    private var position: Int { RecordingGuide.position(index, count: cards.count) }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 10 : 18) {
            HStack {
                Text(cards.isEmpty ? "No talking points yet" : position == cards.count ? "All points covered" : "Point \(position + 1) of \(cards.count)")
                    .font(Theme.sans(12, .medium)).foregroundStyle(Theme.muted)
                Spacer()
                if position > 0 {
                    Button("Restart") { index = 0 }.buttonStyle(.plain).font(Theme.sans(12)).foregroundStyle(Theme.accent)
                }
            }
            if cards.isEmpty {
                Text("Add talking points in Record → Notes.").font(Theme.sans(16)).foregroundStyle(Theme.muted)
            } else if compact {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        if position < cards.count {
                            card(cards[position], prominent: true)
                        } else {
                            Label("Ready to wrap up", systemImage: "checkmark.circle").font(Theme.sans(20, .semibold))
                        }
                        if position + 1 < cards.count {
                            Text("NEXT · \(cards[position + 1].title)").font(Theme.sans(13)).foregroundStyle(Theme.muted)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                // A narrow recording pane stacks the lanes so the current point stays readable.
                ViewThatFits(in: .horizontal) {
                    ScrollView {
                    HStack(alignment: .top, spacing: 12) {
                        lane("DONE", range: 0..<position, current: false).frame(minWidth: 140)
                        lane("NOW", range: position..<min(position + 1, cards.count), current: true).frame(minWidth: 200)
                        lane("NEXT", range: min(position + 1, cards.count)..<cards.count, current: false).frame(minWidth: 140)
                    }
                    }.frame(minWidth: 504)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            lane("NOW", range: position..<min(position + 1, cards.count), current: true)
                            lane("NEXT", range: min(position + 1, cards.count)..<cards.count, current: false)
                            lane("DONE", range: 0..<position, current: false)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
            HStack(spacing: 10) {
                Button { index = max(0, position - 1) } label: { Label("Back", systemImage: "chevron.left") }
                    .disabled(position == 0)
                Spacer()
                Button { index = min(cards.count, position + 1) } label: {
                    Label(position == cards.count - 1 ? "Finish" : "Next point", systemImage: "chevron.right")
                }.disabled(position >= cards.count)
            }.buttonStyle(PillGhostStyle()).font(Theme.sans(13, .medium))
        }
        .padding(compact ? 16 : 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func lane(_ title: String, range: Range<Int>, current: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(Theme.sans(11, .bold)).tracking(1)
                .foregroundStyle(current ? Theme.accent : Theme.muted)
            if range.isEmpty {
                Text(current && position == cards.count ? "All points covered" : "—")
                    .font(Theme.sans(14)).foregroundStyle(Theme.muted)
            }
            ForEach(Array(range), id: \.self) { i in
                card(cards[i], prominent: current)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(current ? Theme.accent.opacity(0.12) : Theme.surface, in: RoundedRectangle(cornerRadius: 12))
            }
        }.frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func card(_ card: RecordingGuide.Card, prominent: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(card.title).font(Theme.sans(prominent ? 22 : 15, .semibold))
            if !card.detail.isEmpty {
                Text(card.detail).font(Theme.sans(prominent ? 17 : 13)).foregroundStyle(Theme.muted)
            }
        }.fixedSize(horizontal: false, vertical: true)
    }
}
