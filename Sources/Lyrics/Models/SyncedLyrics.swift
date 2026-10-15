import Foundation

/// A timed piece of a lyric line (word or syllable), offset relative to the line start.
struct LyricWord: Codable {
    let offset: TimeInterval
    let text: String
}

/// A single time-stamped lyric line.
struct LyricLine: Identifiable, Codable {
    let id: Int // index in the lyrics array
    let time: TimeInterval
    let text: String
    let translation: String?
    /// Word-level timing when the provider has it (e.g. Musixmatch richsync).
    var words: [LyricWord]? = nil
}

/// Parsed synced lyrics with source attribution.
struct SyncedLyrics: Codable {
    let lines: [LyricLine]
    let source: String // e.g. "lrclib"
    let globalOffset: TimeInterval // user-adjustable offset (seconds)

    /// Find the index of the active line for a given playback position (binary search).
    func lineIndex(at position: TimeInterval) -> Int? {
        let adjusted = position + globalOffset
        // Binary search: find the last line whose time <= adjusted
        var lo = 0
        var hi = lines.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if lines[mid].time <= adjusted {
                lo = mid + 1
            } else {
                hi = mid
            }
        }
        return lo > 0 ? lo - 1 : nil
    }

    /// How much of line `index` has been sung at `position` (0…1, by characters), so the
    /// line can fill and scroll at the singer's pace. Uses word timings when available,
    /// otherwise spreads the line over an estimated singing time.
    func progress(ofLine index: Int, at position: TimeInterval) -> Double {
        guard lines.indices.contains(index) else { return 0 }
        let line = lines[index]
        let elapsed = position + globalOffset - line.time
        guard elapsed > 0 else { return 0 }

        let gap = index + 1 < lines.count ? lines[index + 1].time - line.time : 6
        let totalChars = Double(max(1, line.text.count))

        if let words = line.words, !words.isEmpty {
            var sung = 0.0
            for (i, word) in words.enumerated() {
                let chars = Double(word.text.count)
                let end = i + 1 < words.count
                    ? words[i + 1].offset
                    : min(max(gap, word.offset + 0.2), word.offset + 0.3 + chars * 0.12)
                if elapsed >= end {
                    sung += chars
                } else {
                    if elapsed > word.offset, end > word.offset {
                        sung += chars * (elapsed - word.offset) / (end - word.offset)
                    }
                    break
                }
            }
            return min(1, sung / Double(max(1, words.reduce(0) { $0 + $1.text.count })))
        }

        return min(1, elapsed / Self.estimatedSingingDuration(characters: totalChars, gapToNextLine: gap))
    }

    /// Singing time of a line without word timings: ~9 characters per second plus a little
    /// lead-in, never longer than the gap to the next line.
    static func estimatedSingingDuration(characters: Double, gapToNextLine gap: TimeInterval) -> TimeInterval {
        let byLength = max(1.2, characters * 0.11 + 0.6)
        return max(0.3, min(gap * 0.95, byLength))
    }
}
