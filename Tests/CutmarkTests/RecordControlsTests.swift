import AppKit
import CoreGraphics
import SwiftUI
import Testing
@testable import Cutmark

struct RecordControlsTests {
    @Test func minimumStageUsesCompactRecordingControls() {
        #expect(RecordPillLayout.choose(stageWidth: 380, showsDisplayPicker: false, textScale: 1) == .compact)
        #expect(RecordPillLayout.choose(stageWidth: 380, showsDisplayPicker: true, textScale: 1) == .compact)
        #expect(RecordPillLayout.compactWidth == 292)
        #expect(RecordPillLayout.compactWidth <= 380 - 36)
        #expect(RecordPillLayout.choose(stageWidth: 640, showsDisplayPicker: true, textScale: 1) == .regular)
    }

    @Test func largerTextKeepsWideRecordingControlsCompactUntilTheyFit() {
        #expect(RecordPillLayout.choose(stageWidth: 640, showsDisplayPicker: true, textScale: 1.12) == .compact)

        let larger: CGFloat = 1.25
        #expect(RecordPillLayout.choose(stageWidth: 626, showsDisplayPicker: true, textScale: larger) == .compact)
        #expect(RecordPillLayout.choose(stageWidth: 689, showsDisplayPicker: true, textScale: larger) == .compact)
        #expect(RecordPillLayout.choose(stageWidth: 774, showsDisplayPicker: true, textScale: larger) == .regular)

        #expect(RecordPillLayout.choose(stageWidth: 546, showsDisplayPicker: false, textScale: larger) == .compact)
        #expect(RecordPillLayout.choose(stageWidth: 624, showsDisplayPicker: false, textScale: larger) == .regular)
    }

    @Test func savedRecordControlsStayInsideStage() {
        let stage = CGSize(width: 900, height: 600)
        let pill = CGSize(width: 420, height: 60)

        let bottom = RecordPillPlacement.point(normalized: CGPoint(x: 0.5, y: 1), stage: stage, control: pill)
        #expect(bottom.x == 450)
        #expect(bottom.y == 552)

        let clamped = RecordPillPlacement.clamped(point: CGPoint(x: -200, y: 900), stage: stage, control: pill)
        #expect(clamped.x == 228)
        #expect(clamped.y == 552)
    }

    @Test func recordControlPositionRoundTripsAcrossNormalizedStorage() {
        let stage = CGSize(width: 1100, height: 700)
        let pill = CGSize(width: 500, height: 60)
        let saved = CGPoint(x: 0.23, y: 0.61)
        let point = RecordPillPlacement.point(normalized: saved, stage: stage, control: pill)
        let roundTrip = RecordPillPlacement.normalized(point: point, stage: stage, control: pill)

        #expect(abs(roundTrip.x - saved.x) < 0.0001)
        #expect(abs(roundTrip.y - saved.y) < 0.0001)
    }

    @Test func screenPreviewRespectsPrompterAndStageEdges() {
        let stage = CGSize(width: 900, height: 600)
        let preview = CGSize(width: 250, height: 150)
        let topRight = ScreenPreviewPlacement.point(normalized: CGPoint(x: 1, y: 0), stage: stage,
                                                     control: preview, topInset: 96)
        #expect(topRight.x == 757)
        #expect(topRight.y == 189)

        let bottomLeft = ScreenPreviewPlacement.clamped(point: CGPoint(x: -100, y: 900), stage: stage,
                                                        control: preview, topInset: 96)
        #expect(bottomLeft.x == 143)
        #expect(bottomLeft.y == 507)
    }

    @Test func screenPreviewPositionSurvivesResizeAndSmallStage() {
        let stage = CGSize(width: 900, height: 600)
        let preview = CGSize(width: 250, height: 150)
        let saved = CGPoint(x: 0.28, y: 0.72)
        let point = ScreenPreviewPlacement.point(normalized: saved, stage: stage,
                                                  control: preview, topInset: 96)
        let restored = ScreenPreviewPlacement.normalized(point: point, stage: stage,
                                                          control: preview, topInset: 96)
        #expect(abs(restored.x - saved.x) < 0.0001)
        #expect(abs(restored.y - saved.y) < 0.0001)

        // A low stage cannot reserve the full prompter inset; keep the preview visible.
        let compact = CGSize(width: 380, height: 240)
        let compactPreview = CGSize(width: 180, height: 160)
        let clamped = ScreenPreviewPlacement.point(normalized: CGPoint(x: 1, y: 0), stage: compact,
                                                   control: compactPreview, topInset: 90)
        #expect(clamped.x + compactPreview.width / 2 <= compact.width - 18)
        #expect(clamped.y - compactPreview.height / 2 >= 18)
        #expect(clamped.y + compactPreview.height / 2 <= compact.height - 18)

        let portraitWidth = ScreenPreviewPlacement.width(stage: compact, aspect: 9.0 / 16.0)
        #expect(portraitWidth < 180)
        #expect(portraitWidth / (9.0 / 16.0) + 28 + 36 <= compact.height)
        #expect(ScreenPreviewPlacement.width(stage: stage, aspect: 16.0 / 9.0) == 260)
    }

    @Test func recordingPanelNativeDragTracksPointerAndCanReverseWithoutDrift() {
        let start = CGPoint(x: 400, y: 80)
        let down = CGPoint(x: 200, y: 250)
        let moved = CapturePanelDragGeometry.origin(from: start, mouseDown: down,
                                                     mouseNow: CGPoint(x: 660, y: 430))
        #expect(moved == CGPoint(x: 860, y: 260))
        #expect(CapturePanelDragGeometry.origin(from: start, mouseDown: down,
                                                 mouseNow: down) == start)
    }

    @Test func preparationRecordPillIsFixedButRecordingControlsCanMove() {
        let stage = CGSize(width: 900, height: 600)
        let pill = CGSize(width: 420, height: 60)
        let moved = CGPoint(x: 320, y: 205)
        let idle = RecordPillPlacement.stagePosition(recording: false, livePosition: moved,
                                                     stage: stage, control: pill)
        let recording = RecordPillPlacement.stagePosition(recording: true, livePosition: moved,
                                                          stage: stage, control: pill)
        #expect(idle == CGPoint(x: 450, y: 552))
        #expect(recording == moved)
        #expect(RecordPillPlacement.stagePosition(recording: false, livePosition: nil,
            stage: stage, control: pill) == idle)
    }

    @Test func preparationPositionIgnoresPriorDragsAndStageResizes() {
        // Screen/window changes and a past active recording must not move the idle Record
        // control away from the stage's bottom center. The live controller may still move.
        for stage in [CGSize(width: 380, height: 480), CGSize(width: 640, height: 640),
                      CGSize(width: 1080, height: 770)] {
            let pill = CGSize(width: stage.width < 500 ? 292 : 420, height: 60)
            let expected = CGPoint(x: stage.width / 2, y: stage.height - pill.height / 2 - 18)
            for prior in [CGPoint(x: -200, y: -200), CGPoint(x: stage.width / 4, y: 90),
                          CGPoint(x: 5000, y: 5000)] {
                #expect(RecordPillPlacement.stagePosition(recording: false, livePosition: prior,
                    stage: stage, control: pill) == expected)
            }
        }
    }

    @MainActor
    @Test func recordingStatusDragSurfaceWinsHitTestingWithoutStealingStopButton() {
        let host = NSHostingView(rootView: HStack(spacing: 0) {
            Text("Timer").frame(width: 100, height: 44).overlay(CapturePanelDragRegion())
            Button("Stop") {}.frame(width: 80, height: 44)
        }.frame(width: 180, height: 44))
        let panel = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 180, height: 44),
                             styleMask: [.borderless], backing: .buffered, defer: false)
        panel.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: 180, height: 44)
        host.layoutSubtreeIfNeeded()
        #expect(host.hitTest(NSPoint(x: 50, y: 22)) is CapturePanelDragRegion.DragView)
        #expect(!(host.hitTest(NSPoint(x: 150, y: 22)) is CapturePanelDragRegion.DragView))
    }
}
