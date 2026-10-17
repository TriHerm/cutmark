import CoreGraphics
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
}
