import Foundation
@testable import Lyrisland
import Testing

struct AppleScriptNumberParsingTests {
    @Test("parses dot and comma decimal separators")
    func parsesLocalizedDecimals() {
        #expect(SpotifyAppleScriptService.parseNumber("83.45") == 83.45)
        #expect(SpotifyAppleScriptService.parseNumber("83,45") == 83.45)
        #expect(SpotifyAppleScriptService.parseNumber(" 83450 ") == 83450)
        #expect(SpotifyAppleScriptService.parseNumber("missing value") == nil)
    }

    @Test("millisecond position is converted to seconds")
    func normalizesMilliseconds() {
        #expect(SpotifyAppleScriptService.normalizedPosition(milliseconds: 83450, durationMs: 200_000) == 83.45)
        #expect(SpotifyAppleScriptService.normalizedPosition(milliseconds: 0, durationMs: 200_000) == 0)
    }

    @Test("a position already in milliseconds is scaled down once")
    func guardsAgainstDoubleMilliseconds() {
        // Script multiplied an ms value by 1000 → 83_450_000 "ms"
        let seconds = SpotifyAppleScriptService.normalizedPosition(milliseconds: 83_450_000, durationMs: 200_000)
        #expect(abs(seconds - 83.45) < 0.001)
    }
}

struct PlaybackAnchorTests {
    private let t0 = Date(timeIntervalSince1970: 1000)

    @Test("first sample, pauses and resumes re-anchor exactly")
    func hardAnchors() {
        let first = PlaybackSyncEngine.nextAnchor(previous: nil, wasPlaying: false, position: 10, isPlaying: true, sampledAt: t0)
        #expect(first.position == 10)

        let resumed = PlaybackSyncEngine.nextAnchor(
            previous: (t0, 10), wasPlaying: false, position: 50, isPlaying: true, sampledAt: t0.addingTimeInterval(1)
        )
        #expect(resumed.position == 50)
    }

    @Test("small jitter is blended, not snapped")
    func blendsJitter() {
        let next = PlaybackSyncEngine.nextAnchor(
            previous: (t0, 10), wasPlaying: true, position: 10.3, isPlaying: true, sampledAt: t0.addingTimeInterval(0.2)
        )
        // predicted 10.2, drift +0.1 → 10.2 + 0.1 * factor
        #expect(abs(next.position - (10.2 + 0.1 * PlaybackSyncEngine.softCorrectionFactor)) < 0.0001)
    }

    @Test("seeks snap immediately")
    func snapsOnSeek() {
        let next = PlaybackSyncEngine.nextAnchor(
            previous: (t0, 10), wasPlaying: true, position: 95, isPlaying: true, sampledAt: t0.addingTimeInterval(0.2)
        )
        #expect(next.position == 95)
    }
}

struct LyricsTranslatorTests {
    @Test("parses Google gtx response with newline-joined lines")
    func parsesResponse() throws {
        let json = #"[[["Seni seviyorum\n","Ich liebe dich\n",null,null,10],["Sen benim yıldızımsın","Du bist mein Stern",null,null,10]],null,"de"]"#
        let parsed = try #require(LyricsTranslator.parseResponse(Data(json.utf8)))
        #expect(parsed.text == "Seni seviyorum\nSen benim yıldızımsın")
        #expect(parsed.source == "de")
    }

    @Test("rejects malformed responses")
    func rejectsGarbage() {
        #expect(LyricsTranslator.parseResponse(Data("<html>".utf8)) == nil)
        #expect(LyricsTranslator.parseResponse(Data("[]".utf8)) == nil)
    }

    @Test("dedupes repeated lines and skips symbol-only lines")
    func uniqueLines() {
        let lines = ["Ich liebe dich", "♪", "  Ich liebe dich ", "...", "Du bist mein Stern"]
        #expect(LyricsTranslator.uniqueTranslatableLines(lines) == ["Ich liebe dich", "Du bist mein Stern"])
    }

    @Test("batches respect the character budget")
    func batching() {
        let lines = Array(repeating: String(repeating: "a", count: 40), count: 10)
        let batches = LyricsTranslator.batches(lines, maxCharacters: 100)
        #expect(batches.flatMap { $0 } == lines)
        #expect(batches.allSatisfy { $0.joined(separator: "\n").count <= 100 })
    }

    @Test("identical translations are dropped")
    func pairUpDropsIdentical() {
        let map = LyricsTranslator.pairUp(["Hallo", "Berlin"], ["Merhaba", "berlin"])
        #expect(map == ["Hallo": "Merhaba"])
    }

    @Test("language comparison ignores region subtags")
    func sameLanguage() {
        #expect(LyricsTranslator.isSameLanguage("zh-CN", "zh"))
        #expect(LyricsTranslator.isSameLanguage("tr", "tr"))
        #expect(!LyricsTranslator.isSameLanguage("de", "tr"))
        #expect(!LyricsTranslator.isSameLanguage(nil, "tr"))
    }

    @Test("translations are applied to matching lines, keeping timing")
    func applyTranslations() {
        let lyrics = SyncedLyrics(
            lines: [
                LyricLine(id: 0, time: 1, text: "Ich liebe dich", translation: nil),
                LyricLine(id: 1, time: 2, text: "♪", translation: nil),
            ],
            source: "test",
            globalOffset: 0.5
        )
        let translated = lyrics.applyingTranslations(["Ich liebe dich": "Seni seviyorum"])
        #expect(translated.lines[0].translation == "Seni seviyorum")
        #expect(translated.lines[0].time == 1)
        #expect(translated.lines[1].translation == nil)
        #expect(translated.globalOffset == 0.5)
    }
}

struct PlainLyricsFallbackTests {
    @Test("plain lyrics are spread over the song in order, skipping headers")
    func estimatesTiming() throws {
        let plain = "[Strophe 1]\nIch geh nach Haus\nDie Nacht ist lang\n\n[Refrain]\nWir tanzen\n"
        let lyrics = try #require(PlainLyricsFallback.estimatedLyrics(from: plain, durationSeconds: 200, source: "x"))
        #expect(lyrics.lines.map(\.text) == ["Ich geh nach Haus", "Die Nacht ist lang", "Wir tanzen"])
        #expect(lyrics.lines.map(\.id) == [0, 1, 2])
        let times = lyrics.lines.map(\.time)
        #expect(times == times.sorted())
        #expect(times[0] >= 10 && times[0] < 20) // after a short intro
        #expect(times.last! < 200)
    }

    @Test("empty text yields no lyrics")
    func emptyText() {
        #expect(PlainLyricsFallback.estimatedLyrics(from: " \n\n[Intro]\n", durationSeconds: 180, source: "x") == nil)
    }

    @Test("titles and artists are cleaned for searching")
    func cleansQuery() {
        #expect(PlainLyricsFallback.cleanTitle("Du hast - Remastered 2011") == "Du hast")
        #expect(PlainLyricsFallback.cleanTitle("Chöre (feat. Someone)") == "Chöre")
        #expect(PlainLyricsFallback.primaryArtist("Zsá Zsá, Other") == "Zsá Zsá")
        #expect(PlainLyricsFallback.primaryArtist("Mark Forster & Lena") == "Mark Forster")
    }
}

struct WebLyricsScraperTests {
    private let track = TrackInfo(id: "1", title: "Du hast", artist: "Rammstein", album: "Sehnsucht", durationMs: 234_000)

    @Test("Genius lyrics containers are joined and headers/annotations removed")
    func geniusHTML() throws {
        let html = """
        <html><body><div data-lyrics-container="true" class="Lyrics__Container">\
        <div data-exclude-from-selection="true"><div>12 Contributors</div>Du hast Lyrics</div>\
        [Strophe 1]<br/>Du<br><a href="/x"><span>Du hast</span></a><br/>Du hast mich</div>\
        <div class="Other">ignore me</div>\
        <div data-lyrics-container="true">Willst du bis der Tod euch sch&#x27;eidet<br/>Treu ihr sein f&#252;r alle Tage</div>
        </body></html>
        """
        let text = try #require(WebLyricsScrapers.geniusLyrics(fromHTML: html))
        #expect(text == "[Strophe 1]\nDu\nDu hast\nDu hast mich\nWillst du bis der Tod euch sch'eidet\nTreu ihr sein für alle Tage")
    }

    @Test("Genius search picks the matching song and skips translation pages")
    func geniusSearch() throws {
        let json = """
        {"response":{"sections":[{"type":"top_hit","hits":[
          {"type":"song","result":{"title":"Du hast (English Translation)","primary_artist":{"name":"Genius English Translations"},"url":"https://genius.com/translation"}}]},
          {"type":"song","hits":[
          {"type":"song","result":{"title":"Sonne","primary_artist":{"name":"Rammstein"},"url":"https://genius.com/sonne"}},
          {"type":"song","result":{"title":"Du hast","primary_artist":{"name":"Rammstein"},"url":"https://genius.com/Rammstein-du-hast-lyrics"}}]}]}}
        """
        let url = WebLyricsScrapers.bestGeniusSongURL(fromSearch: Data(json.utf8), for: track)
        #expect(url?.absoluteString == "https://genius.com/Rammstein-du-hast-lyrics")
    }

    @Test("Songtexte.com search links, page title and lyrics are parsed")
    func songtexte() throws {
        let search = #"<a href="songtext/rammstein/du-hast-23d4a4b3.html">Du hast</a><a href="/songtext/rammstein/du-hast-23d4a4b3.html">x</a>"#
        #expect(WebLyricsScrapers.songtexteSongURLs(fromSearchHTML: search).map(\.absoluteString)
            == ["https://www.songtexte.com/songtext/rammstein/du-hast-23d4a4b3.html"])

        let page = #"<title>Du hast Songtext von Rammstein Lyrics</title><div id="lyrics">Du<br/>Du hast<br/>Du hast mich<br/><div class="x">Du hast mich gefragt</div></div>"#
        let info = try #require(WebLyricsScrapers.songtexteTitleAndArtist(fromHTML: page))
        #expect(info.title == "Du hast" && info.artist == "Rammstein")
        #expect(WebLyricsScrapers.songtexteLyrics(fromHTML: page) == "Du\nDu hast\nDu hast mich\nDu hast mich gefragt")
    }
}

struct KaraokeProgressTests {
    @Test("without word timing a line fills over its estimated singing time")
    func estimatedProgress() {
        let lyrics = SyncedLyrics(
            lines: [
                LyricLine(id: 0, time: 10, text: "Ich geh nach Haus", translation: nil),
                LyricLine(id: 1, time: 20, text: "Die Nacht ist lang", translation: nil),
            ],
            source: "test",
            globalOffset: 0
        )
        #expect(lyrics.progress(ofLine: 0, at: 9) == 0)
        let mid = lyrics.progress(ofLine: 0, at: 11)
        #expect(mid > 0 && mid < 1)
        #expect(lyrics.progress(ofLine: 0, at: 19) == 1)
        #expect(lyrics.progress(ofLine: 5, at: 11) == 0)
    }

    @Test("singing time never exceeds the gap to the next line")
    func estimateCappedByGap() {
        #expect(SyncedLyrics.estimatedSingingDuration(characters: 200, gapToNextLine: 4) <= 4)
        #expect(SyncedLyrics.estimatedSingingDuration(characters: 10, gapToNextLine: 30) < 3)
    }

    @Test("word timings drive progress word by word")
    func wordProgress() {
        let words = [LyricWord(offset: 0, text: "Du"), LyricWord(offset: 0.5, text: " "), LyricWord(offset: 1.0, text: "hast")]
        let lyrics = SyncedLyrics(
            lines: [
                LyricLine(id: 0, time: 10, text: "Du hast", translation: nil, words: words),
                LyricLine(id: 1, time: 14, text: "Du hast mich", translation: nil),
            ],
            source: "test",
            globalOffset: 0
        )
        #expect(abs(lyrics.progress(ofLine: 0, at: 10.5) - 2.0 / 7.0) < 0.001) // "Du" done
        #expect(abs(lyrics.progress(ofLine: 0, at: 11.0) - 3.0 / 7.0) < 0.001) // "Du " done
        #expect(lyrics.progress(ofLine: 0, at: 13.9) == 1)
    }

    @Test("Musixmatch richsync words are parsed")
    func richsyncParsing() throws {
        let raw: [[String: Any]] = [["c": "Du", "o": 0], ["c": " ", "o": 0.42], ["c": "hast", "o": 0.5]]
        let words = try #require(MusixmatchProvider.richsyncWords(raw))
        #expect(words.map(\.text).joined() == "Du hast")
        #expect(words[1].offset == 0.42)
    }
}

struct TapToSyncTests {
    @Test("clicking a line makes it the active line at the current position")
    func offsetMakesClickedLineCurrent() {
        let lyrics = SyncedLyrics(
            lines: (0 ..< 10).map { LyricLine(id: $0, time: Double($0) * 5, text: "line \($0)", translation: nil) },
            source: "test",
            globalOffset: 1.5
        )
        // Lyrics ran ahead: playback is at 22s but the singer is only at line 3 (15s).
        let delta = LyricsManager.offsetDelta(toStartLineAt: 15, position: 22, currentOffset: lyrics.globalOffset)
        let shifted = SyncedLyrics(lines: lyrics.lines, source: "test", globalOffset: lyrics.globalOffset + delta)
        #expect(shifted.lineIndex(at: 22) == 3)
        #expect(shifted.lineIndex(at: 27.1) == 4) // keeps following from there
    }
}
