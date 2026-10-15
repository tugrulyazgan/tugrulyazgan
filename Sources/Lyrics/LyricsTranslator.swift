import CryptoKit
import Foundation

/// Translates lyric lines (e.g. German → Turkish) so the island can show each
/// original line with its translation underneath.
///
/// Uses Google Translate's public `gtx` endpoint (no API key). Lines are
/// de-duplicated (choruses repeat) and sent in a few newline-joined batches;
/// results are cached on disk per lyrics text + target language.
actor LyricsTranslator {
    /// Translations for one set of lyrics, keyed by the original line text.
    struct Result: Codable {
        /// Language Google detected for the lyrics (e.g. "de"), if known.
        let sourceLanguage: String?
        let translations: [String: String]
    }

    /// Max characters per request — keeps the GET URL well under server limits.
    private static let maxBatchCharacters = 1000

    private let session: URLSession
    private let cache: Cache<String, Result>

    init(
        session: URLSession = .shared,
        cache: Cache<String, Result> = Cache(
            memoryCountLimit: 100,
            namespace: "Translations",
            diskLimitBytes: 20 * 1024 * 1024,
            serializer: CodableCacheSerializer<Result>()
        )
    ) {
        self.session = session
        self.cache = cache
    }

    /// Translate `lines` into `target`. Returns nil when nothing could be translated.
    func translate(_ lines: [String], to target: String) async -> Result? {
        let unique = Self.uniqueTranslatableLines(lines)
        guard !unique.isEmpty else { return nil }

        let key = Self.cacheKey(lines: unique, target: target)
        if let cached = await cache.get(key) { return cached }

        var translations: [String: String] = [:]
        var detected: String?
        for batch in Self.batches(unique, maxCharacters: Self.maxBatchCharacters) {
            if Task.isCancelled { return nil }
            if let batchResult = await translateBatch(batch, to: target) {
                translations.merge(batchResult.map) { current, _ in current }
                detected = detected ?? batchResult.source
            }
        }

        guard !translations.isEmpty || detected != nil else {
            logWarning("[translate] No translation received")
            return nil
        }
        let result = Result(sourceLanguage: detected, translations: translations)
        // Only cache complete results so a flaky network does not stick.
        if translations.count == unique.count || Self.isSameLanguage(detected, target) {
            await cache.set(result, forKey: key)
        }
        logInfo("[translate] \(translations.count)/\(unique.count) lines → \(target) (source: \(detected ?? "?"))")
        return result
    }

    // MARK: - Networking

    /// Translate a batch as one newline-joined request; fall back to one request
    /// per line if the service merged or split lines.
    private func translateBatch(_ batch: [String], to target: String) async -> (map: [String: String], source: String?)? {
        guard let response = await request(batch.joined(separator: "\n"), to: target) else { return nil }
        let source = response.source
        if Self.isSameLanguage(source, target) { return ([:], source) }

        let parts = response.text.components(separatedBy: "\n")
        if parts.count == batch.count {
            return (Self.pairUp(batch, parts), source)
        }

        logDebug("[translate] Line count mismatch (\(parts.count) vs \(batch.count)), translating line by line")
        var map: [String: String] = [:]
        for line in batch {
            if Task.isCancelled { break }
            if let single = await request(line, to: target) {
                map.merge(Self.pairUp([line], [single.text])) { current, _ in current }
            }
        }
        return (map, source)
    }

    private func request(_ text: String, to target: String) async -> (text: String, source: String?)? {
        var components = URLComponents(string: "https://translate.googleapis.com/translate_a/single")!
        components.queryItems = [
            URLQueryItem(name: "client", value: "gtx"),
            URLQueryItem(name: "sl", value: "auto"),
            URLQueryItem(name: "tl", value: target),
            URLQueryItem(name: "dt", value: "t"),
            URLQueryItem(name: "q", value: text),
        ]
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) Lyrisland", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await session.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                logWarning("[translate] HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
                return nil
            }
            return Self.parseResponse(data)
        } catch {
            logWarning("[translate] Request failed: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Pure Helpers

    /// Parse a `translate_a/single?dt=t` response:
    /// `[[["translated","original",…],…], null, "de", …]` → ("translated…", "de").
    static func parseResponse(_ data: Data) -> (text: String, source: String?)? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [Any],
              let segments = root.first as? [Any]
        else { return nil }
        let text = segments.compactMap { ($0 as? [Any])?.first as? String }.joined()
        guard !text.isEmpty else { return nil }
        let source = root.count > 2 ? root[2] as? String : nil
        return (text, source)
    }

    /// Lines worth translating, de-duplicated in first-seen order.
    static func uniqueTranslatableLines(_ lines: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            // Skip empty lines and pure symbols like "♪" or "..."
            guard trimmed.contains(where: \.isLetter), !seen.contains(trimmed) else { continue }
            seen.insert(trimmed)
            result.append(trimmed)
        }
        return result
    }

    /// Split lines into newline-joined batches no longer than `maxCharacters`.
    static func batches(_ lines: [String], maxCharacters: Int) -> [[String]] {
        var result: [[String]] = []
        var current: [String] = []
        var length = 0
        for line in lines {
            if !current.isEmpty, length + line.count + 1 > maxCharacters {
                result.append(current)
                current = []
                length = 0
            }
            current.append(line)
            length += line.count + 1
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    /// Pair originals with translations, dropping translations identical to the original.
    static func pairUp(_ originals: [String], _ translated: [String]) -> [String: String] {
        var map: [String: String] = [:]
        for (original, translation) in zip(originals, translated) {
            let cleaned = translation.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty,
                  cleaned.compare(original, options: [.caseInsensitive, .diacriticInsensitive]) != .orderedSame
            else { continue }
            map[original] = cleaned
        }
        return map
    }

    /// "zh-CN" vs "zh" etc. — compare only the primary language subtag.
    static func isSameLanguage(_ source: String?, _ target: String) -> Bool {
        guard let source else { return false }
        let primary = { (code: String) in code.split(separator: "-").first.map { $0.lowercased() } ?? code.lowercased() }
        return primary(source) == primary(target)
    }

    static func cacheKey(lines: [String], target: String) -> String {
        let digest = SHA256.hash(data: Data(lines.joined(separator: "\n").utf8))
        let hex = digest.prefix(16).map { String(format: "%02x", $0) }.joined()
        return "\(target)-\(hex)"
    }
}

extension SyncedLyrics {
    /// A copy whose lines carry translations from `map` (keyed by trimmed original text).
    /// Lines without an entry keep their provider-supplied translation.
    func applyingTranslations(_ map: [String: String]) -> SyncedLyrics {
        SyncedLyrics(
            lines: lines.map { line in
                let key = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
                return LyricLine(
                    id: line.id, time: line.time, text: line.text,
                    translation: map[key] ?? line.translation, words: line.words
                )
            },
            source: source,
            globalOffset: globalOffset
        )
    }
}
