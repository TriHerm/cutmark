import CoreGraphics
import Testing
@testable import Cutmark

struct RecordControlsTests {
    @Test func minimumStageUsesCompactRecordingControls() {
        #expect(RecordPillLayout.choose(stageWidth: 380, showsDisplayPicker: false) == .compact)
        #expect(RecordPillLayout.choose(stageWidth: 380, showsDisplayPicker: true) == .compact)
        #expect(RecordPillLayout.compactWidth == 292)
        #expect(RecordPillLayout.compactWidth <= 380 - 36)
        #expect(RecordPillLayout.choose(stageWidth: 640, showsDisplayPicker: true) == .regular)
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
