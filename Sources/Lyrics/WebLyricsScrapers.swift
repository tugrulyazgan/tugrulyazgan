import Foundation

/// Plain-lyrics lookups on sites without a public lyrics API (Genius, Songtexte.com).
/// They read the public web pages, so a site redesign can break one; every failure
/// just returns nil and `PlainLyricsFallback` moves on to the next source.
enum WebLyricsScrapers {
    private static let browserUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

    // MARK: - Genius

    /// Search Genius, pick the best-matching song (never its translation pages) and read its lyrics.
    static func genius(for track: TrackInfo, session: URLSession = .shared) async -> String? {
        let title = PlainLyricsFallback.cleanTitle(track.title)
        let artist = PlainLyricsFallback.primaryArtist(track.artist)
        var components = URLComponents(string: "https://genius.com/api/search/multi")!
        components.queryItems = [URLQueryItem(name: "q", value: "\(title) \(artist)")]

        guard let data = await get(components.url, session: session),
              let url = bestGeniusSongURL(fromSearch: data, for: track),
              let page = await get(url, session: session),
              let html = String(data: page, encoding: .utf8)
        else { return nil }
        return geniusLyrics(fromHTML: html)
    }

    /// Pick the song hit whose title/artist best match the track.
    static func bestGeniusSongURL(fromSearch data: Data, for track: TrackInfo) -> URL? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let response = json["response"] as? [String: Any],
              let sections = response["sections"] as? [[String: Any]]
        else { return nil }

        let songs = sections
            .flatMap { ($0["hits"] as? [[String: Any]]) ?? [] }
            .filter { ($0["type"] as? String) == "song" }
            .compactMap { $0["result"] as? [String: Any] }

        var best: (score: Double, url: URL)?
        for song in songs {
            guard let title = song["title"] as? String,
                  let artist = (song["primary_artist"] as? [String: Any])?["name"] as? String
                  ?? song["artist_names"] as? String,
                  let urlString = song["url"] as? String,
                  let url = URL(string: urlString)
            else { continue }
            // Skip "Genius English Translations" / "Genius Türkçe Çeviri" style pages.
            if artist.localizedCaseInsensitiveContains("Genius") { continue }

            let candidate = TrackMatcher.Candidate(title: title, artist: artist, album: nil, durationMs: nil)
            let (score, confidence) = TrackMatcher.score(target: track, candidate: candidate)
            guard confidence >= .medium else { continue }
            if score > (best?.score ?? -1) { best = (score, url) }
        }
        return best?.url
    }

    /// Lyrics live in one or more `<div data-lyrics-container="true">`; headers and
    /// annotations inside them are marked `data-exclude-from-selection="true"`.
    static func geniusLyrics(fromHTML html: String) -> String? {
        let containers = HTMLText.elements(in: html, openTagContaining: "data-lyrics-container=\"true\"")
        guard !containers.isEmpty else { return nil }
        let text = containers
            .map { HTMLText.removingElements(in: $0, openTagContaining: "data-exclude-from-selection=\"true\"") }
            .map(HTMLText.plainText)
            .joined(separator: "\n")
        return cleaned(text)
    }

    // MARK: - Songtexte.com

    /// Search Songtexte.com (strong German catalog) and read the best-matching song page.
    static func songtexte(for track: TrackInfo, session: URLSession = .shared) async -> String? {
        let title = PlainLyricsFallback.cleanTitle(track.title)
        let artist = PlainLyricsFallback.primaryArtist(track.artist)
        var components = URLComponents(string: "https://www.songtexte.com/search")!
        components.queryItems = [
            URLQueryItem(name: "q", value: "\(artist) \(title)"),
            URLQueryItem(name: "c", value: "songs"),
        ]
        guard let data = await get(components.url, session: session),
              let html = String(data: data, encoding: .utf8)
        else { return nil }

        // Check the first few hits: each page's <title> names the song and artist.
        for url in songtexteSongURLs(fromSearchHTML: html).prefix(3) {
            guard let page = await get(url, session: session),
                  let pageHTML = String(data: page, encoding: .utf8),
                  let info = songtexteTitleAndArtist(fromHTML: pageHTML)
            else { continue }
            let candidate = TrackMatcher.Candidate(title: info.title, artist: info.artist, album: nil, durationMs: nil)
            guard TrackMatcher.score(target: track, candidate: candidate).confidence >= .medium else { continue }
            if let lyrics = songtexteLyrics(fromHTML: pageHTML) { return lyrics }
        }
        return nil
    }

    /// Song links in search results look like `songtext/<artist>/<title>-<id>.html`.
    static func songtexteSongURLs(fromSearchHTML html: String) -> [URL] {
        let pattern = ##"href="(?:https://www\.songtexte\.com/)?/?(songtext/[^"#?]+\.html)""##
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        var seen = Set<String>()
        var urls: [URL] = []
        for match in regex.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
            guard let range = Range(match.range(at: 1), in: html) else { continue }
            let path = String(html[range])
            guard seen.insert(path).inserted, let url = URL(string: "https://www.songtexte.com/\(path)") else { continue }
            urls.append(url)
        }
        return urls
    }

    /// "<title>Du hast Songtext von Rammstein Lyrics</title>" → ("Du hast", "Rammstein").
    static func songtexteTitleAndArtist(fromHTML html: String) -> (title: String, artist: String)? {
        guard let start = html.range(of: "<title>"),
              let end = html.range(of: "</title>", range: start.upperBound ..< html.endIndex)
        else { return nil }
        let title = HTMLText.decodeEntities(String(html[start.upperBound ..< end.lowerBound]))
        guard let separator = title.range(of: " Songtext von ") else { return nil }
        let song = title[..<separator.lowerBound].trimmingCharacters(in: .whitespaces)
        var artist = String(title[separator.upperBound...])
        if let suffix = artist.range(of: " Lyrics", options: .backwards) {
            artist = String(artist[..<suffix.lowerBound])
        }
        return (song, artist.trimmingCharacters(in: .whitespaces))
    }

    static func songtexteLyrics(fromHTML html: String) -> String? {
        guard let container = HTMLText.elements(in: html, openTagContaining: "id=\"lyrics\"").first else { return nil }
        let text = HTMLText.plainText(container)
        // Songtexte shows a placeholder when it has the song but no lyrics yet.
        guard !text.localizedCaseInsensitiveContains("Leider kein Songtext vorhanden") else { return nil }
        return cleaned(text)
    }

    // MARK: - Helpers

    private static func get(_ url: URL?, session: URLSession) async -> Data? {
        guard let url else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 12)
        request.setValue(browserUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("de-DE,de;q=0.9,en;q=0.8", forHTTPHeaderField: "Accept-Language")
        do {
            let (data, response) = try await session.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                logDebug("[web] HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1) for \(url.host ?? "?")")
                return nil
            }
            return data
        } catch {
            logDebug("[web] Request failed for \(url.host ?? "?"): \(error.localizedDescription)")
            return nil
        }
    }

    /// Trim lines, collapse runs of blank lines, and reject near-empty results.
    private static func cleaned(_ text: String) -> String? {
        var lines: [String] = []
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty, lines.last?.isEmpty ?? true { continue }
            lines.append(line)
        }
        let result = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return result.count >= 20 ? result : nil
    }
}

/// Minimal HTML helpers — enough to pull text out of a known container.
enum HTMLText {
    /// Every element whose opening tag contains `marker`, returned with its inner HTML
    /// (balanced on tags of the same name, so nested `<div>`s are kept intact).
    static func elements(in html: String, openTagContaining marker: String) -> [String] {
        var results: [String] = []
        var searchStart = html.startIndex
        while let markerRange = html.range(of: marker, range: searchStart ..< html.endIndex) {
            guard let tagStart = html.range(of: "<", options: .backwards, range: html.startIndex ..< markerRange.lowerBound),
                  let tagEnd = html.range(of: ">", range: markerRange.upperBound ..< html.endIndex)
            else { break }
            let tagName = html[tagStart.upperBound...].prefix { $0.isLetter || $0.isNumber }
            guard !tagName.isEmpty,
                  let close = matchingClose(in: html, tagName: String(tagName), from: tagEnd.upperBound)
            else {
                searchStart = tagEnd.upperBound
                continue
            }
            results.append(String(html[tagEnd.upperBound ..< close.lowerBound]))
            searchStart = close.upperBound
        }
        return results
    }

    /// `html` with every element whose opening tag contains `marker` cut out entirely.
    static func removingElements(in html: String, openTagContaining marker: String) -> String {
        var result = html
        while let markerRange = result.range(of: marker),
              let tagStart = result.range(of: "<", options: .backwards, range: result.startIndex ..< markerRange.lowerBound),
              let tagEnd = result.range(of: ">", range: markerRange.upperBound ..< result.endIndex) {
            let tagName = String(result[tagStart.upperBound...].prefix { $0.isLetter || $0.isNumber })
            let end = tagName.isEmpty ? nil : matchingClose(in: result, tagName: tagName, from: tagEnd.upperBound)
            result.removeSubrange(tagStart.lowerBound ..< (end?.upperBound ?? tagEnd.upperBound))
        }
        return result
    }

    /// Range of the `</tagName>` that closes an element whose content starts at `from`.
    private static func matchingClose(in html: String, tagName: String, from: String.Index) -> Range<String.Index>? {
        let open = "<\(tagName)"
        let close = "</\(tagName)>"
        var depth = 1
        var cursor = from
        while cursor < html.endIndex {
            let nextClose = html.range(of: close, options: .caseInsensitive, range: cursor ..< html.endIndex)
            var nextOpen = html.range(of: open, options: .caseInsensitive, range: cursor ..< html.endIndex)
            // "<div" must be followed by whitespace or ">" (not e.g. "<divider")
            while let candidate = nextOpen, candidate.upperBound < html.endIndex,
                  !(html[candidate.upperBound].isWhitespace || html[candidate.upperBound] == ">") {
                nextOpen = html.range(of: open, options: .caseInsensitive, range: candidate.upperBound ..< html.endIndex)
            }
            guard let closeRange = nextClose else { return nil }
            if let openRange = nextOpen, openRange.lowerBound < closeRange.lowerBound {
                depth += 1
                cursor = openRange.upperBound
            } else {
                depth -= 1
                if depth == 0 { return closeRange }
                cursor = closeRange.upperBound
            }
        }
        return nil
    }

    /// `<br>` → newline, block ends → newline, other tags dropped, entities decoded.
    static func plainText(_ html: String) -> String {
        var text = html.replacingOccurrences(of: #"<br\s*/?>"#, with: "\n", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: #"</(p|div)>"#, with: "\n", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        return decodeEntities(text)
    }

    static func decodeEntities(_ text: String) -> String {
        var result = text
        let named = [
            "&amp;": "&", "&quot;": "\"", "&#x27;": "'", "&#39;": "'", "&apos;": "'",
            "&lt;": "<", "&gt;": ">", "&nbsp;": " ",
        ]
        for (entity, value) in named where entity != "&amp;" {
            result = result.replacingOccurrences(of: entity, with: value)
        }
        // Numeric entities: &#228; and &#xE4;
        if let regex = try? NSRegularExpression(pattern: #"&#(x?)([0-9a-fA-F]+);"#) {
            let matches = regex.matches(in: result, range: NSRange(result.startIndex..., in: result)).reversed()
            for match in matches {
                guard let whole = Range(match.range, in: result),
                      let hexFlag = Range(match.range(at: 1), in: result),
                      let digits = Range(match.range(at: 2), in: result),
                      let code = UInt32(result[digits], radix: result[hexFlag].isEmpty ? 10 : 16),
                      let scalar = Unicode.Scalar(code)
                else { continue }
                result.replaceSubrange(whole, with: String(Character(scalar)))
            }
        }
        // Decode &amp; last so "&amp;lt;" stays "&lt;" literally.
        return result.replacingOccurrences(of: "&amp;", with: "&")
    }
}
