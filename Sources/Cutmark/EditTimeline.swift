import AVFoundation
import SwiftUI

/// The published video plays above. This strip edits a separate, recoverable *plan*, never a
/// published recipe. The selected agent renders that plan as a new checked version on request.
struct EditTimelinePanel: View {
    @Environment(AppModel.self) private var app
    let video: URL
    let doc: SessionDoc
    @AppStorage("editTimelineCollapsed") private var collapsed = false
    @State private var draft: EditTimelineDraft?
    @State private var selected = 0
    @State private var trimIn = ""
    @State private var trimOut = ""
    @State private var splitAt = ""
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 9) {
                Image(systemName: "film.stack").foregroundStyle(Theme.accent)
                Text("Timeline").font(Theme.sans(13, .semibold))
                if let draft {
                    Text("\(draft.segments.count) clips · \(SessionDoc.clock(draft.duration))")
                        .font(Theme.mono(11)).foregroundStyle(Theme.muted)
                    if !draft.actions.isEmpty {
                        Text("Draft · \(draft.actions.count) changes")
                            .font(Theme.sans(11, .medium)).foregroundStyle(Theme.accent)
                    }
                }
                Spacer(minLength: 8)
                Button { collapsed.toggle() } label: {
                    Image(systemName: collapsed ? "chevron.up" : "chevron.down")
                }
                .buttonStyle(.plain)
                .help(collapsed ? "Expand timeline" : "Collapse timeline")
            }
            if !collapsed {
                if let draft {
                    ScrollView(.horizontal) {
                        HStack(spacing: 4) {
                            ForEach(Array(draft.segments.enumerated()), id: \.offset) { i, seg in
                                Button { choose(i) } label: {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("\(seg.kind == "screen" ? "Screen" : "Camera") · Take \(seg.take)")
                                            .lineLimit(1)
                                        Text("At \(SessionDoc.clock(startTime(i))) · \(String(format: "%.1f", seg.duration))s")
                                            .font(Theme.mono(10))
                                    }
                                    .font(Theme.sans(11, .medium))
                                    .padding(.horizontal, 9)
                                    .frame(width: min(300, max(110, seg.duration * 36)), height: 48,
                                           alignment: .leading)
                                    .background(i == selected ? Theme.accentSoft : Theme.canvas,
                                                in: RoundedRectangle(cornerRadius: 6))
                                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(
                                        i == selected ? Theme.accent : Theme.border, lineWidth: 1))
                                }
                                .buttonStyle(.plain)
                                .help("Select segment \(i + 1) at output \(SessionDoc.clock(startTime(i)))")
                                .accessibilityLabel("Select timeline segment \(i + 1)")
                            }
                        }
                    }
                    ScrollView(.horizontal) {
                        HStack(spacing: 9) {
                            timelineButton("arrow.left", "Move earlier", selected > 0) {
                                apply(.init(op: "move", index: selected, to: selected - 1)); choose(selected - 1)
                            }
                            timelineButton("arrow.right", "Move later", selected + 1 < draft.segments.count) {
                                apply(.init(op: "move", index: selected, to: selected + 1)); choose(selected + 1)
                            }
                            timelineButton("plus.square.on.square", "Duplicate segment", true) {
                                apply(.init(op: "duplicate", index: selected))
                            }
                            timelineButton("trash", "Remove segment", draft.segments.count > 1) {
                                apply(.init(op: "remove", index: selected)); choose(max(0, selected - 1))
                            }
                            timelineButton("arrow.uturn.backward", "Undo last change", !draft.actions.isEmpty) {
                                undo()
                            }
                            Button("Split at playhead") { splitAtPlayhead() }
                                .buttonStyle(AccentButtonStyle(kind: .quiet))
                            if draft.segments.contains(where: { $0.kind == "screen" }) {
                                Button("Review auto-zoom") { reviewZooms() }
                                    .buttonStyle(AccentButtonStyle(kind: .quiet))
                                    .help("Suggest screen zooms without changing or publishing the edit")
                            }
                            Text("Source seconds").font(Theme.sans(10)).foregroundStyle(Theme.faint)
                            timeField("In", $trimIn)
                            timeField("Out", $trimOut)
                            Button("Trim") { trimSelected() }
                                .buttonStyle(AccentButtonStyle(kind: .quiet))
                            timeField("Split", $splitAt)
                            Button("Split") { splitSelected() }
                                .buttonStyle(AccentButtonStyle(kind: .quiet))
                        }
                    }
                    .lineLimit(1)
                    HStack(spacing: 10) {
                        if let problem {
                            Text(problem).font(Theme.sans(11)).foregroundStyle(Theme.danger).lineLimit(1)
                        } else {
                            Text(draft.actions.isEmpty ? "Edit non-destructively; sources stay unchanged."
                                 : "Preview plays the original; render your draft to see the reordered edit.")
                                .font(Theme.sans(11)).foregroundStyle(Theme.faint)
                        }
                        Spacer(minLength: 8)
                        Button("Reset draft") { reset() }
                            .buttonStyle(AccentButtonStyle(kind: .quiet))
                            .disabled(draft.actions.isEmpty)
                        Button("Render draft") { render() }
                            .buttonStyle(AccentButtonStyle(kind: .solid))
                            .disabled(draft.actions.isEmpty)
                    }
                } else {
                    Text("This video has no editable recipe. Create an edit with render_edit first.")
                        .font(Theme.sans(12)).foregroundStyle(Theme.muted)
                }
            }
        }
        .padding(12)
        .background(Theme.paper, in: RoundedRectangle(cornerRadius: 13))
        .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(Theme.border))
        .shadow(color: Theme.shadow, radius: 12, y: 5)
        .task(id: video) {
            draft = EditTimelineDraft.restore(video: video, session: doc.url)
            choose(0)
        }
    }

    private func startTime(_ index: Int) -> Double {
        guard let draft else { return 0 }
        return draft.outputStart(of: index, lead: EditRecipe.cover(for: video)?.seconds ?? 0) ?? 0
    }

    private func choose(_ index: Int) {
        guard let draft, !draft.segments.isEmpty else { return }
        selected = min(max(index, 0), draft.segments.count - 1)
        let seg = draft.segments[selected]
        trimIn = String(format: "%.3f", seg.start)
        trimOut = String(format: "%.3f", seg.end)
        splitAt = String(format: "%.3f", (seg.start + seg.end) / 2)
        if let original = draft.originalOutputStart(of: selected, lead: EditRecipe.cover(for: video)?.seconds ?? 0) {
            app.player?.seek(to: CMTime(seconds: original, preferredTimescale: 600))
        }
    }

    private func apply(_ action: EditTimelineDraft.Action) {
        guard var copy = draft, copy.apply(action) else {
            problem = "Invalid edit. Keep at least two frames within the source segment."
            return
        }
        do {
            try copy.save(video: video, session: doc.url)
            draft = copy
            problem = nil
        } catch {
            problem = "Could not save the timeline draft. Check the session folder."
        }
    }

    private func trimSelected() {
        guard let a = Double(trimIn), let b = Double(trimOut) else { problem = "Enter numeric source seconds."; return }
        apply(.init(op: "trim", index: selected, in: a, out: b))
        choose(selected)
    }

    private func splitSelected() {
        guard let at = Double(splitAt) else { problem = "Enter a numeric split point."; return }
        apply(.init(op: "split", index: selected, at: at))
        choose(selected)
    }

    private func splitAtPlayhead() {
        guard let draft, let played = app.player?.currentTime().seconds,
              let point = draft.originalSourcePoint(atOutput: played, lead: EditRecipe.cover(for: video)?.seconds ?? 0)
        else {
            problem = "Move the playhead into the cut timeline, then split."
            return
        }
        let index = draft.segments.indices.contains(selected)
            && draft.segments[selected].take == point.take
            && draft.segments[selected].kind == point.kind
            && draft.segments[selected].start <= point.source
            && point.source < draft.segments[selected].end
            ? selected
            : draft.segments.firstIndex { $0.take == point.take && $0.kind == point.kind
                && $0.start <= point.source && point.source < $0.end }
        guard let index else {
            problem = "The playhead is outside your current draft. Select a kept segment."
            return
        }
        apply(.init(op: "split", index: index, at: point.source))
        choose(index)
    }

    private func reset() {
        EditTimelineDraft.clear(video: video, session: doc.url)
        draft = EditTimelineDraft.read(video: video)
        choose(0)
        problem = nil
    }

    private func undo() {
        guard var copy = draft, copy.undoLast() else { return }
        do {
            try copy.save(video: video, session: doc.url)
            draft = copy
            choose(min(selected, copy.segments.count - 1))
            problem = nil
        } catch {
            problem = "Could not save the timeline draft. Check the session folder."
        }
    }

    private func render() {
        guard let draft, !draft.actions.isEmpty,
              let bytes = try? JSONEncoder().encode(draft.actions),
              let actions = String(data: bytes, encoding: .utf8) else { return }
        let request = "For the published edit \(draft.base) in this session, call plan_timeline_edit with "
            + "base=\(draft.base) and these exact ordered actions: \(actions). Review the returned timeline, "
            + "then call render_edit using its returned render_edit arguments. Inspect the render and checks. "
            + "Do not publish_edit until I review the new result. Never overwrite the published edit or take files."
        app.chats.chat(doc.url).send(request, title: doc.meta.title, onStage: video,
                                     shown: "Render my \(draft.actions.count)-change timeline draft for review")
        app.chats.open = true
    }

    private func reviewZooms() {
        guard let draft, draft.segments.contains(where: { $0.kind == "screen" }) else { return }
        app.chats.chat(doc.url).send(
            "Call cutmark suggest_auto_zooms for the published edit \(draft.base). This is a read-only "
            + "review: explain the proposed regions against the kept screen cuts. Do not apply_auto_zooms, "
            + "render_edit or publish_edit without my approval.",
            title: doc.meta.title, onStage: video, shown: "Review suggested screen zooms")
        app.chats.open = true
    }

    private func timeField(_ label: String, _ value: Binding<String>) -> some View {
        HStack(spacing: 4) {
            Text(label).font(Theme.sans(10)).foregroundStyle(Theme.muted)
            TextField(label, text: value)
                .textFieldStyle(.plain).font(Theme.mono(11))
                .frame(width: 46)
        }
        .padding(.horizontal, 5).frame(height: 27)
        .background(Theme.canvas, in: RoundedRectangle(cornerRadius: 6))
    }

    private func timelineButton(_ icon: String, _ label: String, _ enabled: Bool,
                                perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            Image(systemName: icon).font(.system(size: 12, weight: .medium))
                .frame(width: 26, height: 26)
        }
        .buttonStyle(.plain).disabled(!enabled)
        .help(label).accessibilityLabel(label)
    }
}
