import Foundation

/// Transcript phrases follow the output clock, including repeats, trims and reordered sections.
enum TimelineTranscript {
    struct Phrase: Identifiable, Equatable {
        let section: Int
        let time: Double
        let text: String
        var id: String { "\(section):\(time)" }
    }
    static func phrases(draft: EditTimelineDraft, words: [String: [Word]]) -> [Phrase] {
        var output: [Phrase] = []
        var offset = 0.0
        for (index, segment) in draft.segments.enumerated() {
            defer { offset += segment.duration }
            let start = segment.renderSourceStart ?? segment.start
            let end = min(segment.end, start + segment.duration)
            let kept = (words["\(segment.take):\(segment.kind)"] ?? []).filter {
                $0.start.isFinite && $0.end.isFinite && $0.start >= start && $0.start < end && $0.end >= $0.start
            }.sorted { $0.start < $1.start }
            var phrase: [Word] = []
            func flush() {
                guard let first = phrase.first else { return }
                output.append(Phrase(section: index, time: offset + first.start - start,
                                     text: phrase.map(\.word).joined(separator: " ")))
                phrase = []
            }
            for word in kept {
                if let last = phrase.last, word.start - last.end > 0.8 { flush() }
                phrase.append(word)
                if phrase.count >= 14 || word.word.last.map({ ".!?".contains($0) }) == true { flush() }
            }
            flush()
        }
        return output
    }
}
