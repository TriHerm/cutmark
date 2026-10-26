import SwiftUI

enum PrompterScrollMode: String, CaseIterable, Identifiable {
    case automatic, voice
    var id: String { rawValue }
    var title: String { self == .automatic ? "Automatic" : "Follow my voice" }
}

struct PrompterModePicker: View {
    @Environment(AppModel.self) private var app
    var compact = false
    var body: some View {
        CutmarkSwitch(selection: Binding(get: { app.prompterScrollMode }, set: { app.prompterScrollMode = $0 }),
                      options: PrompterScrollMode.allCases.map { ($0, compact && $0 == .voice ? "Voice" : $0.title) }, fill: !compact)
            .help("Automatic moves at a steady speed. Follow my voice moves as you speak.")
    }
}

/// Only the active scroll behavior is visible; layout and start options stay in the menu.
struct PrompterMotionControls: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            PrompterModePicker()
            if app.prompterScrollMode == .automatic {
                HStack(spacing: 10) {
                    Text("Speed").font(Theme.sans(11, .medium)).foregroundStyle(Theme.muted)
                    Slider(value: Binding(get: { app.speed }, set: { app.speed = $0 }), in: 5...200)
                        .accessibilityLabel("Automatic scroll speed")
                    Text("\(Int(app.speed))").font(Theme.mono(10)).foregroundStyle(Theme.muted).frame(width: 28)
                }
            } else if app.voice.failed {
                Text("Voice follow is unavailable. Using automatic scrolling.")
                    .font(Theme.sans(11)).foregroundStyle(Theme.muted)
            }
        }.padding(.horizontal, 16).padding(.vertical, 10).background(Theme.paper)
    }
}
