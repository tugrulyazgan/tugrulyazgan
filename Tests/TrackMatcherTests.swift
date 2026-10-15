@testable import Lyrisland
import Testing

struct TrackMatcherTests {
    let target = TrackInfo(
        id: "test-track",
        title: "Bohemian Rhapsody",
        artist: "Queen",
        album: "A Night at the Opera",
        durationMs: 354_000
    )

    @Test("Exact match yields perfect confidence")
    func exactMatch() {
        let candidate = TrackMatcher.Candidate(
            title: "Bohemian Rhapsody",
            artist: "Queen",
            album: "A Night at the Opera",
            durationMs: 354_000
        )
        let result = TrackMatcher.score(target: target, candidate: candidate)
        #expect(result.confidence == .perfect)
    }

    @Test("Different track yields noMatch or veryLow")
    func differentTrack() {
        let candidate = TrackMatcher.Candidate(
            title: "Stairway to Heaven",
            artist: "Led Zeppelin",
            album: "Led Zeppelin IV",
            durationMs: 482_000
        )
        let result = TrackMatcher.score(target: target, candidate: candidate)
        #expect(result.confidence <= TrackMatcher.Confidence.veryLow)
    }

    @Test("Title with bracket suffix still matches well")
    func bracketSuffix() {
        let candidate = TrackMatcher.Candidate(
            title: "Bohemian Rhapsody (Remastered 2011)",
            artist: "Queen",
            album: nil,
            durationMs: nil
        )
        let result = TrackMatcher.score(target: target, candidate: candidate)
        #expect(result.confidence >= TrackMatcher.Confidence.high)
    }

    @Test("Duration within 300ms is veryHigh")
    func durationClose() {
        let score = TrackMatcher.compareDuration(354_000, 354_200)
        #expect(score == TrackMatcher.FieldScore.veryHigh)
    }

    @Test("Duration exact match is perfect")
    func durationExact() {
        let score = TrackMatcher.compareDuration(354_000, 354_000)
        #expect(score == TrackMatcher.FieldScore.perfect)
    }

    @Test("Multiple artists with shared member scores well")
    func multipleArtists() {
        let score = TrackMatcher.compareArtist("Queen & David Bowie", "Queen")
        #expect(score.rawValue >= TrackMatcher.FieldScore.high.rawValue)
    }

    @Test("Name comparison is case-insensitive")
    func caseInsensitive() {
        let score = TrackMatcher.compareName("bohemian rhapsody", "BOHEMIAN RHAPSODY")
        #expect(score == TrackMatcher.FieldScore.perfect)
    }
}
