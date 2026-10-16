import Foundation

/// Cheap checks that should fail before Cutmark wakes the camera or starts the countdown. They are
/// deliberately conservative: an unavailable capacity reading does not block recording, but a
/// volume that is already nearly full does.
enum RecordingPreflight {
    static let minimumFreeBytes: Int64 = 1_000_000_000

    static func problem(for session: URL) -> String? {
        let values = try? session.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return problem(availableBytes: values?.volumeAvailableCapacityForImportantUsage)
    }

    static func problem(availableBytes: Int64?) -> String? {
        guard let availableBytes, availableBytes < minimumFreeBytes else { return nil }
        return "Cutmark needs at least 1 GB of free space before recording. Free some space, then try again."
    }
}
