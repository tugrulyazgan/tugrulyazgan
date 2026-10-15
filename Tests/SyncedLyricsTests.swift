@testable import Lyrisland
import Testing

struct SyncedLyricsTests {
    let lyrics = SyncedLyrics(
        lines: [
            LyricLine(id: 0, time: 5.0, text: "Line A", translation: nil),
            LyricLine(id: 1, time: 10.0, text: "Line B", translation: nil),
            LyricLine(id: 2, time: 15.0, text: "Line C", translation: nil),
            LyricLine(id: 3, time: 20.0, text: "Line D", translation: nil),
        ],
        source: "test",
        globalOffset: 0
    )

    @Test("Returns nil before first line")
    func beforeFirstLine() {
        #expect(lyrics.lineIndex(at: 2.0) == nil)
    }

    @Test("Returns first line at exact time")
    func exactFirstLine() {
        #expect(lyrics.lineIndex(at: 5.0) == 0)
    }

    @Test("Returns correct line between timestamps")
    func betweenTimestamps() {
        #expect(lyrics.lineIndex(at: 12.5) == 1)
    }

    @Test("Returns last line after all timestamps")
    func afterLastLine() {
        #expect(lyrics.lineIndex(at: 99.0) == 3)
    }

    @Test("Returns exact match on middle line")
    func exactMiddleLine() {
        #expect(lyrics.lineIndex(at: 15.0) == 2)
    }

    @Test("Respects global offset")
    func globalOffset() {
        let offsetLyrics = SyncedLyrics(
            lines: lyrics.lines,
            source: "test",
            globalOffset: -5.0
        )
        // position 10 + offset(-5) = adjusted 5 → line at time 5.0 → index 0
        #expect(offsetLyrics.lineIndex(at: 10.0) == 0)
    }
}
