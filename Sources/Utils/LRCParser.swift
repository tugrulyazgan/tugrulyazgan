import Foundation

/// Shared LRC format parser. Handles standard `[mm:ss.xx(x)]` timestamps.
enum LRCParser {
    /// Parse an LRC string into sorted `LyricLine` array.
    /// - Parameters:
    ///   - raw: The raw LRC text.
    ///   - translations: Optional parallel translation lines keyed by time (seconds).
    static func parse(_ raw: String, translations: [TimeInterval: String]? = nil) -> [LyricLine] {
        let pattern = #"\[(\d{1,2}):(\d{2})\.(\d{2,3})\]\s*(.*)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }

        var lines: [LyricLine] = []
        for line in raw.components(separatedBy: .newlines) {
            let nsRange = NSRange(line.startIndex..., in: line)
            guard let match = regex.firstMatch(in: line, range: nsRange) else { continue }

            let minutes = Double(line[Range(match.range(at: 1), in: line)!])!
            let seconds = Double(line[Range(match.range(at: 2), in: line)!])!
            let msString = String(line[Range(match.range(at: 3), in: line)!])
            let ms = Double(msString)! / (msString.count == 2 ? 100.0 : 1000.0)
            let text = String(line[Range(match.range(at: 4), in: line)!])

            guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { continue }

            let time = minutes * 60 + seconds + ms
            let translation = translations?[time]
            lines.append(LyricLine(id: lines.count, time: time, text: text, translation: translation))
        }

        return lines.sorted { $0.time < $1.time }
    }
}
