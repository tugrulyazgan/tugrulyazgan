import Foundation

/// The visual expansion state of the Dynamic Island.
enum IslandState: Equatable {
    /// Compact pill — shows song title + mini waveform
    case compact
    /// Expanded — shows current lyric line with context
    case expanded
    /// Full — shows scrollable lyrics list + album art
    case full
}
