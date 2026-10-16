import Testing
@testable import Cutmark

struct RecordingPreflightTests {
    @Test func lowDiskStopsBeforeRecordingAndUnknownCapacityDoesNot() {
        #expect(RecordingPreflight.problem(availableBytes: nil) == nil)
        #expect(RecordingPreflight.problem(availableBytes: RecordingPreflight.minimumFreeBytes) == nil)
        #expect(RecordingPreflight.problem(availableBytes: RecordingPreflight.minimumFreeBytes - 1) != nil)
    }
}
