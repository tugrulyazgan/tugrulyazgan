import Foundation
@testable import Lyrisland
import Testing

struct LRCParserTests {
    @Test("Parses standard LRC lines with two-digit centiseconds")
    func parseStandardLines() {
        let lrc = """
        [00:12.34] Hello world
        [01:05.67] Second line
        """
        let lines = LRCParser.parse(lrc)

        #expect(lines.count == 2)
        #expect(lines[0].text == "Hello world")
        #expect(lines[0].time == 12.34)
        #expect(lines[1].text == "Second line")
        #expect(lines[1].time == 65.67)
    }

    @Test("Parses three-digit milliseconds")
    func parseThreeDigitMs() {
        let lrc = "[02:30.456] Three digits"
        let lines = LRCParser.parse(lrc)

        #expect(lines.count == 1)
        #expect(lines[0].text == "Three digits")
        #expect(lines[0].time == 150.456)
    }

    @Test("Skips blank text lines")
    func skipBlankLines() {
        let lrc = """
        [00:01.00]
        [00:02.00]
        [00:03.00] Actual text
        """
        let lines = LRCParser.parse(lrc)

        #expect(lines.count == 1)
        #expect(lines[0].text == "Actual text")
    }

    @Test("Returns lines sorted by time")
    func sortsByTime() {
        let lrc = """
        [00:30.00] Later
        [00:10.00] Earlier
        [00:20.00] Middle
        """
        let lines = LRCParser.parse(lrc)

        #expect(lines.count == 3)
        #expect(lines[0].text == "Earlier")
        #expect(lines[1].text == "Middle")
        #expect(lines[2].text == "Later")
    }

    @Test("Merges translations by matching time")
    func mergesTranslations() {
        let lrc = "[00:05.00] Hello"
        let translations: [TimeInterval: String] = [5.0: "你好"]
        let lines = LRCParser.parse(lrc, translations: translations)

        #expect(lines.count == 1)
        #expect(lines[0].translation == "你好")
    }

    @Test("Returns empty array for invalid input")
    func emptyForInvalid() {
        let lines = LRCParser.parse("no timestamps here")
        #expect(lines.isEmpty)
    }
}
