import AVFoundation
import SwiftUI

/// The player above shows the original take/published version. This strip edits a separate,
/// recoverable plan: trimming/splitting never writes into the media or published recipe.
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
    @State private var showPrecision = false

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 9) {
                Image(systemName: "film.stack").foregroundStyle(Theme.accent)
                Text("Edit timeline").font(Theme.sans(13, .semibold))
                    .help("Select a clip. Drag its ends to trim, split at the player position, or move clips with arrows.")
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
                                TimelineSegmentView(index: i, segment: seg, start: startTime(i),
                                                    selected: i == selected,
                                                    select: { choose(i) },
                                                    trim: { edge, delta in
                                    guard let proposal = self.draft?.trimProposal(index: i, edge: edge, dragSeconds: delta)
                                    else { return }
                                    apply(proposal)
                                    choose(i)
                                })
                            }
                        }
                    }
                    ScrollView(.horizontal) {
                        HStack(spacing: 9) {
                            Button("Split at playhead") { splitAtPlayhead() }
                                .buttonStyle(AccentButtonStyle(kind: .quiet))
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
                            Button(showPrecision ? "Hide precise times" : "Precise trim") { showPrecision.toggle() }
                                .buttonStyle(AccentButtonStyle(kind: .quiet))
                            if !draft.isRawTake, draft.segments.contains(where: { $0.kind == "screen" }) {
                                Button("Suggest zoom") { reviewZooms() }
                                    .buttonStyle(AccentButtonStyle(kind: .quiet))
                            }
                        }
                    }
                    .lineLimit(1)
                    if showPrecision {
                        HStack(spacing: 8) {
                            Text("Clip \(selected + 1) · source seconds")
                                .font(Theme.sans(11)).foregroundStyle(Theme.muted)
                            timeField("In", $trimIn)
                            timeField("Out", $trimOut)
                            Button("Apply trim") { trimSelected() }
                                .buttonStyle(AccentButtonStyle(kind: .quiet))
                            timeField("Split", $splitAt)
                            Button("Split at time") { splitSelected() }
                                .buttonStyle(AccentButtonStyle(kind: .quiet))
                        }
                    }
                    HStack(spacing: 10) {
                        if let problem {
                            Text(problem).font(Theme.sans(11)).foregroundStyle(Theme.danger).lineLimit(1)
                        } else {
                            Text(draft.actions.isEmpty ? "Source stays unchanged; make a cut to start."
                                 : "Player shows the original until the draft is rendered. No media is overwritten.")
                                .font(Theme.sans(11)).foregroundStyle(Theme.faint)
                        }
                        Spacer(minLength: 8)
                        Button("Reset draft") { reset() }
                            .buttonStyle(AccentButtonStyle(kind: .quiet))
                            .disabled(draft.actions.isEmpty)
                        Button(draft.isRawTake ? "Render new edit" : "Render draft") { render() }
                            .buttonStyle(AccentButtonStyle(kind: .solid))
                            .disabled(draft.actions.isEmpty && !draft.isRawTake)
                    }
                } else {
                    Text("The source is unavailable for editing. Open a recorded take or an edit with its recipe.")
                        .font(Theme.sans(12)).foregroundStyle(Theme.muted)
                }
            }
        }
        .padding(12)
        .background(Theme.paper, in: RoundedRectangle(cornerRadius: 13))
        .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(Theme.border))
        .shadow(color: Theme.shadow, radius: 12, y: 5)
        .task(id: video) {
            // Recorded takes are editable immediately, without first creating an edit via chat.
            // Prefer measured video duration; session metadata may be missing after recovery.
            let measured = try? await AVURLAsset(url: video).load(.duration)
            guard !Task.isCancelled else { return }
            let take = video.deletingLastPathComponent().standardizedFileURL
                    == doc.url.standardizedFileURL
                ? doc.meta.takes.first { $0.file == video.lastPathComponent } : nil
            let raw = take.flatMap { t -> EditTimelineDraft? in
                let length = (measured?.seconds).flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
                    ?? t.duration ?? 0
                let fps = t.kind == .screen ? Double(ScreenMovieWriter.frameRate) : 30
                return EditTimelineDraft.fromTake(t, duration: length, fps: fps)
            }
            draft = EditTimelineDraft.restore(video: video, session: doc.url, original: raw)
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
        if let raw = draft, raw.isRawTake {
            draft = EditTimelineDraft(base: raw.base, fps: raw.fps, source: raw.source, segments: raw.source)
        } else {
            draft = EditTimelineDraft.read(video: video)
        }
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
        guard let draft else { return }
        if draft.isRawTake {
            guard let recipe = draft.initialRecipe(),
                  let bytes = try? JSONSerialization.data(withJSONObject: recipe, options: [.sortedKeys]),
                  let json = String(data: bytes, encoding: .utf8) else { return }
            app.chats.chat(doc.url).send(
                "Create a new non-destructive edit from this raw recorded take. Call render_edit "
                + "with this exact recipe: \(json). Inspect the render and checks. "
                + "Do not publish_edit until I review the new result. Never modify the take files.",
                title: doc.meta.title, onStage: video, shown: "Render this timeline as a new edit")
            app.chats.open = true
            return
        }
        guard !draft.actions.isEmpty,
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

/// Compact modern clip strip: visible before any edit exists; its drag handles are source-space
/// trims. All gesture math uses this clip's displayed width, so compact stages work too.
private struct TimelineSegmentView: View {
    let index: Int
    let segment: EditTimelineDraft.Segment
    let start: Double
    let selected: Bool
    let select: () -> Void
    let trim: (EditTimelineDraft.TrimEdge, Double) -> Void

    private var clipWidth: CGFloat { min(310, max(116, segment.duration * 34)) }

    var body: some View {
        Button(action: select) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 5) {
                    Image(systemName: segment.kind == "screen" ? "display" : "video")
                    Text("Clip \(index + 1) · Take \(segment.take)").lineLimit(1)
                }
                Text("\(SessionDoc.clock(start))  ·  \(String(format: "%.1f", segment.duration)) s")
                    .font(Theme.mono(10)).foregroundStyle(Theme.muted)
            }
            .font(Theme.sans(11, .medium))
            .padding(.horizontal, 22)
            .frame(width: clipWidth, height: 58, alignment: .leading)
            .background(selected ? Theme.accentSoft : Theme.canvas,
                        in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(
                selected ? Theme.accent : Theme.border, lineWidth: selected ? 1.5 : 1))
        }
        .buttonStyle(.plain)
        .overlay(alignment: .leading) { grip(.start) }
        .overlay(alignment: .trailing) { grip(.end) }
        .help("Select clip \(index + 1); drag its left or right edge inward to trim")
        .accessibilityLabel("Select timeline clip \(index + 1), take \(segment.take), \(String(format: "%.1f", segment.duration)) seconds")
    }

    private func grip(_ edge: EditTimelineDraft.TrimEdge) -> some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(Theme.accent.opacity(selected ? 0.85 : 0.4))
            .frame(width: 6, height: 36)
            .frame(width: 19, height: 58)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 5)
                .onEnded { value in
                    // Minimum-width bars remain usable; convert pixels to this occurrence's
                    // source seconds, never an estimated fixed 30-pixels-per-second clock.
                    trim(edge, Double(value.translation.width / clipWidth) * segment.duration)
                })
            .help(edge == .start ? "Drag right to trim the beginning" : "Drag left to trim the end")
            .accessibilityLabel(edge == .start ? "Trim start of clip \(index + 1)" : "Trim end of clip \(index + 1)")
    }
}
