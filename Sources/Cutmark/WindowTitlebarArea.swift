import AppKit
import SwiftUI

/// Only the empty header background handles window gestures; text fields and buttons keep theirs.
struct WindowTitlebarArea: NSViewRepresentable {
    func makeNSView(context: Context) -> TitlebarView { TitlebarView() }
    func updateNSView(_ view: TitlebarView, context: Context) {}

    final class TitlebarView: NSView {
        override var mouseDownCanMoveWindow: Bool { false }
        // Headers are replaced when switching boards; frame history belongs to the window.
        private static let restoredFrames = NSMapTable<NSWindow, NSValue>(keyOptions: .weakMemory, valueOptions: .strongMemory)
        override func mouseDown(with event: NSEvent) {
            guard let window, !window.styleMask.contains(.fullScreen) else { return }
            if event.clickCount == 2 {
                guard let screen = window.screen else { return }
                if let previous = Self.restoredFrames.object(forKey: window)?.rectValue, window.frame == screen.visibleFrame {
                    window.setFrame(previous, display: true, animate: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
                    Self.restoredFrames.removeObject(forKey: window)
                } else {
                    Self.restoredFrames.setObject(NSValue(rect: window.frame), forKey: window)
                    window.setFrame(screen.visibleFrame, display: true, animate: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
                }
            } else {
                window.performDrag(with: event)
            }
        }
    }
}
