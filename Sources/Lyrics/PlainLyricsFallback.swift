import Foundation

/// Last resort when no provider has *synced* lyrics: find plain (untimed) lyrics
/// on the web and spread the lines over the song so they still scroll along.
///
/// Sources, in order: LRCLIB `plainLyrics`, Musixmatch plain lyrics, Genius,
/// Songtexte.com (strong German catalog), lyrics.ovh.
///
/// Timings are estimates (weighted by line length, with pauses between stanzas);
/// the user can nudge them with the existing offset controls.
enum PlainLyricsFallback {
    /// `SyncedLyrics.source` values produced here.
    static let lrclibSource = "lrclib-plain"
    static let lyricsOvhSource = "lyricsovh-plain"

    static let musixmatchSource = "musixmatch-plain"
    static let geniusSource = "genius-plain"
    static let songtexteSource = "songtexte-plain"

    /// Sources tried in order; the first that returns text wins.
    private static func sources(session: URLSession) -> [(id: String, fetch: (TrackInfo) async -> String?)] {
        [
            (lrclibSource, { await lrclibPlain(for: $0, session: session) }),
            (musixmatchSource, { try? await MusixmatchProvider().fetchPlainLyrics(for: $0) }),
            (geniusSource, { await WebLyricsScrapers.genius(for: $0, session: session) }),
            (songtexteSource, { await WebLyricsScrapers.songtexte(for: $0, session: session) }),
            (lyricsOvhSource, { await lyricsOvh(for: $0, session: session) }),
        ]
    }

    static func fetch(for track: TrackInfo, session: URLSession = .shared) async -> SyncedLyrics? {
        for source in sources(session: session) {
            if Task.isCancelled { return nil }
            if let text = await source.fetch(track),
               let lyrics = estimatedLyrics(from: text, durationSeconds: track.durationSeconds, source: source.id) {
                logInfo("[plain] \(source.id) lyrics for: \(track.title)")
                return lyrics
            }
        }
        logInfo("[plain] No plain lyrics found for: \(track.title) — \(track.artist)")
        return nil
    }

    // MARK: - LRCLIB

    private static func lrclibPlain(for track: TrackInfo, session: URLSession) async -> String? {
        var exact = URLComponents(string: "https://lrclib.net/api/get")!
        exact.queryItems = [
            URLQueryItem(name: "track_name", value: track.title),
            URLQueryItem(name: "artist_name", value: track.artist),
            URLQueryItem(name: "album_name", value: track.album),
            URLQueryItem(name: "duration", value: String(Int(track.durationSeconds))),
        ]
        if let json = await getJSON(exact.url, session: session) as? [String: Any],
           let plain = nonEmpty(json["plainLyrics"] as? String) {
            return plain
        }

        var search = URLComponents(string: "https://lrclib.net/api/search")!
        search.queryItems = [URLQueryItem(name: "q", value: "\(cleanTitle(track.title)) \(primaryArtist(track.artist))")]
        guard let results = await getJSON(search.url, session: session) as? [[String: Any]] else { return nil }

        let scored = results.compactMap { item -> (score: Double, text: String)? in
            guard let plain = nonEmpty(item["plainLyrics"] as? String) else { return nil }
            let candidate = TrackMatcher.Candidate(
                title: item["trackName"] as? String ?? "",
                artist: item["artistName"] as? String ?? "",
                album: item["albumName"] as? String,
                durationMs: (item["duration"] as? NSNumber).map { Int($0.doubleValue * 1000) }
            )
            let (score, confidence) = TrackMatcher.score(target: track, candidate: candidate)
            // Plain lyrics carry no timing to sanity-check, so demand a solid metadata match.
            guard confidence >= .medium else { return nil }
            return (score, plain)
        }
        return scored.max { $0.score < $1.score }?.text
    }

    // MARK: - lyrics.ovh

    private static func lyricsOvh(for track: TrackInfo, session: URLSession) async -> String? {
        let artist = primaryArtist(track.artist)
        let title = cleanTitle(track.title)
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))
        guard let a = artist.addingPercentEncoding(withAllowedCharacters: allowed),
              let t = title.addingPercentEncoding(withAllowedCharacters: allowed),
              let url = URL(string: "https://api.lyrics.ovh/v1/\(a)/\(t)")
        else { return nil }
        guard let json = await getJSON(url, session: session) as? [String: Any] else { return nil }
        return nonEmpty(json["lyrics"] as? String)
    }

    // MARK: - Networking

    private static func getJSON(_ url: URL?, session: URLSession) async -> Any? {
        guard let url else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("Lyrisland (https://github.com/EurFelux/Lyrisland)", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await session.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            return try? JSONSerialization.jsonObject(with: data)
        } catch {
            logDebug("[plain] Request failed for \(url.host ?? "?"): \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Pure Helpers

    private static func nonEmpty(_ text: String?) -> String? {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }

    /// "Song - Remastered 2011 (feat. X)" → "Song".
    static func cleanTitle(_ title: String) -> String {
        var result = title
        for separator in [" - ", " – ", " — "] {
            if let range = result.range(of: separator) {
                result = String(result[..<range.lowerBound])
            }
        }
        result = result.replacingOccurrences(
            of: #"\s*[\(\[](feat\.?|ft\.?|with|featuring|remaster|live|radio edit)[^\)\]]*[\)\]]"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        return result.trimmingCharacters(in: .whitespaces)
    }

    /// "A, B & C" → "A".
    static func primaryArtist(_ artist: String) -> String {
        let separators = [", ", " & ", " feat. ", " ft. ", " x ", " und "]
        var result = artist
        for separator in separators {
            if let range = result.range(of: separator, options: .caseInsensitive) {
                result = String(result[..<range.lowerBound])
            }
        }
        return result.trimmingCharacters(in: .whitespaces)
    }

    /// Spread plain lyric lines over the song: lines get time proportional to their
    /// length, stanza breaks add a pause, and a short intro/outro is left empty.
    static func estimatedLyrics(from plain: String, durationSeconds: Double, source: String) -> SyncedLyrics? {
        // (text, isStanzaBreak)
        var items: [(text: String, isBreak: Bool)] = []
        for raw in plain.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || isSectionHeader(line) {
                if let last = items.last, !last.isBreak { items.append(("", true)) }
            } else {
                items.append((line, false))
            }
        }
        while items.last?.isBreak == true {
            items.removeLast()
        }
        let textCount = items.filter { !$0.isBreak }.count
        guard textCount > 0 else { return nil }

        let duration = durationSeconds > 0 ? durationSeconds : Double(textCount) * 3.5
        let start = min(12, duration * 0.08)
        let end = max(start + 1, duration - min(8, duration * 0.05))

        let weights = items.map { $0.isBreak ? 6.0 : 6.0 + Double($0.text.count) }
        let total = weights.reduce(0, +)

        var lines: [LyricLine] = []
        var elapsed = 0.0
        for (item, weight) in zip(items, weights) {
            if !item.isBreak {
                let time = start + (end - start) * elapsed / total
                lines.append(LyricLine(id: lines.count, time: time, text: item.text, translation: nil))
            }
            elapsed += weight
        }
        return SyncedLyrics(lines: lines, source: source, globalOffset: 0)
    }

    /// "[Chorus]", "[Verse 2: Artist]", "(Refrain)" and similar annotations.
    private static func isSectionHeader(_ line: String) -> Bool {
        (line.hasPrefix("[") && line.hasSuffix("]"))
            || (line.hasPrefix("(") && line.hasSuffix(")") && line.count < 30
                && line.range(of: #"(?i)chorus|verse|refrain|bridge|intro|outro|hook|strophe"#, options: .regularExpression) != nil)
    }
}
