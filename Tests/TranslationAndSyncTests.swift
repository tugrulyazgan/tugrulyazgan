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
