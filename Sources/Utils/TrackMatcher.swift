import Foundation

/// Scoring algorithm for matching search results against a target track.
/// Ported from Lyricify-Lyrics-Helper's CompareHelper (Apache 2.0).
enum TrackMatcher {
    /// Match confidence level.
    enum Confidence: Int, Comparable {
        case noMatch = 0
        case veryLow = 3
        case low = 8
        case medium = 11
        case prettyHigh = 15
        case high = 17
        case veryHigh = 19
        case perfect = 21

        static func < (lhs: Confidence, rhs: Confidence) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    /// Individual field score (0–7).
    enum FieldScore: Int {
        case noMatch = 0
        case low = 2
        case medium = 4
        case high = 5
        case veryHigh = 6
        case perfect = 7
    }

    struct Candidate {
        let title: String
        let artist: String
        let album: String?
        let durationMs: Int?
    }

    /// Compute overall match score and confidence for a candidate against a target.
    static func score(target: TrackInfo, candidate: Candidate) -> (score: Double, confidence: Confidence) {
        let nameScore = compareName(target.title, candidate.title)
        let artistScore = compareArtist(target.artist, candidate.artist)
        let albumScore = candidate.album.map { compareName(target.album, $0) }
        let durationScore = candidate.durationMs.map { compareDuration(target.durationMs, $0) }

        var total = Double(nameScore.rawValue)
            + Double(artistScore.rawValue)
        var maxPossible: Double = 14 // name(7) + artist(7)

        if let album = albumScore {
            total += Double(album.rawValue) * 0.4
            maxPossible += 7 * 0.4
        }
        if let duration = durationScore {
            total += Double(duration.rawValue)
            maxPossible += 7
        }

        // Normalize to 0–30 scale
        let normalized = (total / maxPossible) * 30.0

        let confidence: Confidence = switch normalized {
        case 21...: .perfect
        case 19...: .veryHigh
        case 17...: .high
        case 15...: .prettyHigh
        case 11...: .medium
        case 8...: .low
        case 3...: .veryLow
        default: .noMatch
        }

        return (normalized, confidence)
    }

    // MARK: - Field Comparisons

    static func compareName(_ a: String, _ b: String) -> FieldScore {
        let na = normalize(a)
        let nb = normalize(b)

        if na == nb { return .perfect }
        if na.contains(nb) || nb.contains(na) { return .veryHigh }

        let similarity = textSimilarity(na, nb)
        if similarity > 0.90 { return .veryHigh }
        if similarity > 0.80 { return .high }
        if similarity > 0.68 { return .medium }
        if similarity > 0.55 { return .low }
        return .noMatch
    }

    static func compareArtist(_ a: String, _ b: String) -> FieldScore {
        let partsA = splitArtists(a)
        let partsB = splitArtists(b)

        let matchCount = partsA.filter { artist in
            partsB.contains(where: { normalize($0) == normalize(artist) })
        }.count

        let total = max(partsA.count, partsB.count)
        guard total > 0 else { return .noMatch }

        let ratio = Double(matchCount) / Double(total)
        if ratio >= 1.0 { return .perfect }
        if ratio >= 0.7 { return .veryHigh }
        if ratio >= 0.5 { return .high }

        // Fallback: check if full strings are similar
        let similarity = textSimilarity(normalize(a), normalize(b))
        if similarity > 0.80 { return .medium }
        if similarity > 0.55 { return .low }
        return .noMatch
    }

    static func compareDuration(_ a: Int, _ b: Int) -> FieldScore {
        let diff = abs(a - b)
        if diff == 0 { return .perfect }
        if diff < 300 { return .veryHigh }
        if diff < 700 { return .high }
        if diff < 1500 { return .medium }
        if diff < 3500 { return .low }
        return .noMatch
    }

    // MARK: - Helpers

    /// Normalize a string for comparison: lowercase, strip brackets content.
    private static func normalize(_ s: String) -> String {
        var result = s.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Remove common bracket suffixes: (feat. ...), (Deluxe), etc.
        let bracketPattern = #"\s*[\(\[（【].*?[\)\]）】]"#
        if let regex = try? NSRegularExpression(pattern: bracketPattern) {
            result = regex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: ""
            )
        }

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Split artist string by common delimiters.
    private static func splitArtists(_ artist: String) -> [String] {
        artist
            .components(separatedBy: CharacterSet(charactersIn: ",;/&、"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Simple character-level similarity ratio (Sørensen–Dice on bigrams).
    private static func textSimilarity(_ a: String, _ b: String) -> Double {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        if a == b { return 1.0 }

        let bigramsA = bigrams(a)
        let bigramsB = bigrams(b)

        guard !bigramsA.isEmpty, !bigramsB.isEmpty else { return 0 }

        let intersection = bigramsA.intersection(bigramsB).count
        return 2.0 * Double(intersection) / Double(bigramsA.count + bigramsB.count)
    }

    private static func bigrams(_ s: String) -> Set<String> {
        let chars = Array(s)
        guard chars.count >= 2 else { return Set([s]) }
        return Set((0 ..< chars.count - 1).map { String(chars[$0 ... $0 + 1]) })
    }
}
