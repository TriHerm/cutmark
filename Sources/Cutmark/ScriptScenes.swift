import Foundation
import SwiftUI

/// Match scene lines without changing the script. Keep repeated lines in storyboard order.
enum SceneScript {
    static func ranges(_ board: Storyboard, in script: String) -> [String: NSRange] {
        let text = script as NSString
        var cursor = 0, result: [String: NSRange] = [:]
        for scene in board.shots {
            let words = scene.say.split(whereSeparator: \.isWhitespace)
            guard !words.isEmpty else { continue }
            var pattern = words.map { NSRegularExpression.escapedPattern(for: String($0)) }.joined(separator: "\\s+")
            if let first = words.first?.first, first.isLetter || first.isNumber || first == "_" {
                pattern = "(?<![\\p{L}\\p{M}\\p{N}_])" + pattern
            }
            if let last = words.last?.last, last.isLetter || last.isNumber || last == "_" {
                pattern += "(?![\\p{L}\\p{M}\\p{N}_])"
            }
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: script, range: NSRange(location: cursor, length: text.length - cursor)) else { continue }
            result[scene.id] = match.range
            cursor = NSMaxRange(match.range)
        }
        return result
    }
}

/// Scene context stays beside the complete editable script (2026-10-25).
struct ScriptScenes: View {
    @Environment(AppModel.self) private var app
    @Environment(\.paneShown) private var shown
    @State private var lastFocused: String?
    @State private var showVisuals = false
    @AppStorage("visualPreviewRequest") private var visualRequest = 0
    var doc: SessionDoc
    var board: Storyboard
    var jump: (NSRange) -> Void

    private var selected: StoryShot? {
        board.shots.first { $0.id == doc.focusedSceneID } ?? board.shots.first
    }
    private var matches: [String: NSRange] { SceneScript.ranges(board, in: doc.activeText) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("SCENES").font(Theme.sans(10, .bold)).tracking(1).foregroundStyle(Theme.muted)
                Text("\(board.shots.count)").font(Theme.mono(10)).foregroundStyle(Theme.faint)
                Spacer()
                Button("Visual previews") { showVisuals = true }
                    .buttonStyle(.plain).font(Theme.sans(11)).foregroundStyle(Theme.muted)
                    .cutmarkPopover(isPresented: $showVisuals) {
                        StoryboardPane(doc: doc, onEditScript: { showVisuals = false; SessionMode.set(.write) })
                            .environment(app).environment(\.paneShown, true)
                            .frame(width: 820, height: 600)
                    }
            }
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        ForEach(Array(board.shots.enumerated()), id: \.element.id) { i, scene in
                            let on = selected?.id == scene.id
                            Button {
                                doc.focusedSceneID = scene.id
                                if let range = matches[scene.id] { jump(range) }
                                lastFocused = scene.id
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("\(i + 1) · \(scene.section.title)")
                                        .font(Theme.sans(11, .semibold))
                                    Text(scene.say.isEmpty ? StoryboardPane.howTitle(scene.kind) : scene.say)
                                        .font(Theme.sans(11)).lineLimit(1)
                                }
                                .foregroundStyle(on ? Theme.accentInk : Theme.muted)
                                .frame(width: 126, alignment: .leading).padding(10)
                                .background(on ? Theme.accentSoft : Theme.surface, in: RoundedRectangle(cornerRadius: 9))
                                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(on ? Theme.accent.opacity(0.5) : Theme.border))
                            }
                            .buttonStyle(.plain).id(scene.id)
                            .accessibilityLabel("Scene \(i + 1), \(scene.section.title): \(scene.say)")
                            .help("Jump to this scene in the full script")
                        }
                    }
                }
                .scrollIndicators(.never)
                .onChange(of: doc.focusedSceneID) { _, id in
                    if let id { withAnimation(Theme.motion) { proxy.scrollTo(id, anchor: .center) } }
                }
            }
            if let scene = selected {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        if !scene.how.isEmpty {
                            Text(StoryboardPane.howTitle(scene.kind)).font(Theme.sans(11, .semibold)).foregroundStyle(Theme.muted)
                            Text(scene.how).font(Theme.sans(12)).foregroundStyle(Theme.ink).lineLimit(3)
                                .textSelection(.enabled)
                        }
                        if !scene.say.isEmpty && matches[scene.id] == nil {
                            Text("This scene’s lines aren’t in this script version.")
                                .font(Theme.sans(11)).foregroundStyle(Theme.muted)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    Button { app.record(shot: scene) } label: {
                        Label("Record scene", systemImage: "record.circle")
                    }
                    .buttonStyle(PillGhostStyle()).font(Theme.sans(12, .medium)).fixedSize()
                    .help("Open Record for this scene. Start the take when you are ready.")
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(Theme.canvas)
        .overlay(alignment: .bottom) { Rule() }
        .disabled(app.isRecording)
        .onAppear { jumpIfChanged(); openRequestedVisuals() }
        .onChange(of: shown) { _, on in if on { jumpIfChanged(); openRequestedVisuals() } }
        .onChange(of: shown) { _, on in if !on { showVisuals = false } }
        .onChange(of: doc.focusedSceneID) { jumpIfChanged() }
        .onChange(of: visualRequest) { if shown { showVisuals = true } }
        .onChange(of: doc.activeDraft) { lastFocused = nil; jumpIfChanged() }
    }

    private func jumpIfChanged() {
        guard shown, let scene = selected, scene.id != lastFocused else { return }
        if let range = matches[scene.id] { jump(range) }
        lastFocused = scene.id
    }

    private func openRequestedVisuals() {
        if shown && UserDefaults.standard.string(forKey: "rightTab") == SessionMode.storyboard.rawValue { showVisuals = true }
    }
}
