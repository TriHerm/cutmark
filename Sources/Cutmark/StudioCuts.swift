import CryptoKit
import Foundation

/// Cuts are in the timeline's output clock. Every overlapping track uses the same time map.
struct StudioCut: Codable, Hashable {
    let start: Double
    let end: Double
    let reason: String
}

struct StudioCutProposal: Codable, Equatable {
    let revision: String
    let cuts: [StudioCut]

    static let path = "_edit/studio/cuts.json"

    static func load(in session: URL) throws -> Self? {
        guard FileManager.default.fileExists(atPath: session.appending(path: path).path) else { return nil }
        let file = try MediaEditProject.source(path, session: session)
        guard let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 64_000 else {
            throw MediaEditProject.Failure.invalid("The suggested cuts file is too large.")
        }
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: file))
    }

    static func revision(of project: MediaEditProject, in session: URL) throws -> String {
        let file = try MediaEditProject.source("_edit/studio/project.json", session: session)
        guard let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 4_194_304 else {
            throw MediaEditProject.Failure.invalid("This edit file is too large to open.")
        }
        let bytes = try Data(contentsOf: file)
        guard try JSONDecoder().decode(MediaEditProject.self, from: bytes) == project else {
            throw MediaEditProject.Failure.invalid("The saved timeline changed. Reopen the editor and try again.")
        }
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    func validated(for duration: Double) throws -> [StudioCut] {
        let sorted = cuts.sorted { $0.start < $1.start }
        var cursor = 0.0
        var removed = 0.0
        guard (1...30).contains(sorted.count) else {
            throw MediaEditProject.Failure.invalid("Suggest between 1 and 30 cuts.")
        }
        for cut in sorted {
            guard cut.start.isFinite, cut.end.isFinite, cut.start >= cursor,
                  cut.end <= duration, cut.end - cut.start >= 1 / 30,
                  !cut.reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  cut.reason.utf8.count <= 600 else {
                throw MediaEditProject.Failure.invalid("Suggested cuts must have valid, non-overlapping times and a reason.")
            }
            cursor = cut.end
            removed += cut.end - cut.start
        }
        guard duration - removed >= 1 / 30 else {
            throw MediaEditProject.Failure.invalid("Keep at least one frame of video.")
        }
        return sorted
    }
}

extension MediaEditProject {
    func removing(_ cuts: [StudioCut]) throws -> Self {
        let sorted = try StudioCutProposal(revision: "", cuts: cuts).validated(for: duration)
        var result = self
        var retained: [(range: Range<Double>, removed: Double)] = []
        var cursor = 0.0, removed = 0.0
        for cut in sorted {
            if cut.start > cursor { retained.append((cursor..<cut.start, removed)) }
            removed += cut.end - cut.start
            cursor = cut.end
        }
        // Keep the unexported tail of audio and overlays so it can still be used later.
        retained.append((cursor..<Double.infinity, removed))
        result.clips = try clips.flatMap { clip -> [Clip] in
            let position = position(clip.id)
            return try retained.compactMap { span in
                let start = max(position, span.range.lowerBound)
                let end = min(position + clip.duration, span.range.upperBound)
                guard end > start else { return nil }
                let keepsStart = start == position
                let keepsEnd = end == position + clip.duration
                var piece = clip
                if !keepsStart {
                    piece.id = UUID()
                    piece.start = clip.start + (start - position) * clip.speed
                    piece.fadeIn = 0
                }
                if !keepsEnd {
                    piece.end = clip.start + (end - position) * clip.speed
                    piece.fadeOut = 0
                }
                guard piece.duration >= 1 / 30 else {
                    // An overlay or audio fragment smaller than a frame cannot be saved.
                    if clip.lane != .video { return nil }
                    throw Failure.invalid("A cut leaves part of a video clip shorter than one frame. Adjust the cut and try again.")
                }
                if clip.lane != .video { piece.offset = max(0, start - span.removed) }
                piece.fadeIn = min(piece.fadeIn, piece.duration)
                piece.fadeOut = min(piece.fadeOut, piece.duration - piece.fadeIn)
                return piece
            }
        }
        try result.validate()
        return result
    }
}

enum StudioTranscript {
    static func phrases(in project: MediaEditProject, session: URL) -> [StudioCut] {
        var cache: [String: [Word]] = [:]
        return project.clips.filter { $0.lane == .video && $0.kind == .video && $0.volume > 0 }.flatMap { clip in
            guard let url = try? MediaEditProject.source(clip.file, session: session) else { return [StudioCut]() }
            if cache[clip.file] == nil { cache[clip.file] = Transcript.words(for: url) ?? [] }
            let at = project.position(clip.id)
            var result: [StudioCut] = [], phrase: [Word] = []
            func flush() {
                defer { phrase.removeAll(keepingCapacity: true) }
                guard let first = phrase.first, let end = phrase.map(\.end).max(),
                      end - first.start >= clip.speed / 30 else { return }
                result.append(StudioCut(start: at + (first.start - clip.start) / clip.speed,
                                        end: min(project.duration, at + (end - clip.start) / clip.speed),
                                        reason: phrase.map(\.word).joined(separator: " ")))
            }
            let words = (cache[clip.file] ?? []).filter {
                $0.start.isFinite && $0.end.isFinite && $0.start >= clip.start &&
                $0.end <= clip.end && $0.end > $0.start
            }.sorted { $0.start < $1.start }
            for word in words {
                if let last = phrase.last, word.start - last.end > 0.65 { flush() }
                phrase.append(word)
                if phrase.count >= 12 || word.word.last.map({ ".!?".contains($0) }) == true { flush() }
            }
            flush()
            return result
        }
    }
}
