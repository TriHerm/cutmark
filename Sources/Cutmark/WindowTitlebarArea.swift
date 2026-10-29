import AppKit
import SwiftUI

/// Only the empty header background handles window gestures; text fields and buttons keep theirs.
struct WindowTitlebarArea: NSViewRepresentable {
    func makeNSView(context: Context) -> TitlebarView { TitlebarView() }
    func updateNSView(_ view: TitlebarView, context: Context) {}

    final class TitlebarView: NSView {
        override var mouseDownCanMoveWindow: Bool { false }
        private var restoredFrame: NSRect?
        override func mouseDown(with event: NSEvent) {
            guard let window, !window.styleMask.contains(.fullScreen) else { return }
            if event.clickCount == 2 {
                guard let screen = window.screen else { return }
                if let previous = restoredFrame, window.frame == screen.visibleFrame {
                    window.setFrame(previous, display: true, animate: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
                    restoredFrame = nil
                } else {
                    restoredFrame = window.frame
                    window.setFrame(screen.visibleFrame, display: true, animate: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
                }
            } else {
                window.performDrag(with: event)
            }
        }
    }
}
