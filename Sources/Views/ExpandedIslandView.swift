import SwiftUI

/// Expanded state: shows the current lyric line with surrounding context.
/// Uses push transitions (like Compact mode) for smooth line-by-line scrolling.
struct ExpandedIslandView: View {
    @ObservedObject var syncEngine: PlaybackSyncEngine
    @ObservedObject var lyricsManager: LyricsManager
    @ObservedObject var appState: AppState
    @Environment(\.rootFontSize) private var rootFontSize
    @Environment(\.translationColor) private var translationColor

    /// Five lines normally; four when the current line's translation takes a row.
    private func visibleLineCount(showsTranslation: Bool) -> Int {
        showsTranslation ? 4 : 5
    }

    private func translation(for index: Int, in lyrics: SyncedLyrics) -> String? {
        guard appState.translationEnabled, lyrics.lines.indices.contains(index) else { return nil }
        return lyrics.lines[index].translation
    }

    var body: some View {
        VStack(spacing: 4) {
            // Track info header
            if let title = syncEngine.trackTitle {
                HStack(spacing: 4) {
                    Text(title)
                        .font(.system(size: .rem(0.6875, root: rootFontSize), weight: .semibold))
                        .foregroundStyle(appState.contentColor.opacity(0.5))
                        .lineLimit(1)
                    if let artist = syncEngine.trackArtist {
                        Text("—")
                            .font(.system(size: .rem(0.6875, root: rootFontSize)))
                            .foregroundStyle(appState.contentColor.opacity(0.3))
                        Text(artist)
                            .font(.system(size: .rem(0.6875, root: rootFontSize)))
                            .foregroundStyle(appState.contentColor.opacity(0.4))
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()
                .background(appState.contentColor.opacity(0.15))

            if let lyrics = lyricsManager.currentLyrics {
                let currentIdx = syncEngine.currentLineIndex ?? 0
                let currentTranslation = translation(for: currentIdx, in: lyrics)
                let range = contextRange(
                    around: currentIdx,
                    total: lyrics.lines.count,
                    visible: visibleLineCount(showsTranslation: currentTranslation != nil)
                )

                ForEach(lyrics.lines[range]) { line in
                    let isCurrent = line.id == currentIdx
                    let distance = abs(line.id - currentIdx)
                    let lineDirection: LayoutDirection = line.text.isRTL ? .rightToLeft : .leftToRight

                    if isCurrent {
                        VStack(spacing: 0) {
                            LiveLyricLine(
                                syncEngine: syncEngine,
                                lyrics: lyrics,
                                index: currentIdx,
                                font: .system(size: .rem(0.9375, root: rootFontSize), weight: .bold),
                                color: appState.contentColor
                            )
                            .frame(height: 20)
                            .frame(maxWidth: .infinity, alignment: appState.resolvedLyricsAlignment)
                            .environment(\.layoutDirection, lineDirection)

                            if let currentTranslation {
                                MarqueeText(
                                    text: currentTranslation,
                                    font: .system(size: .rem(0.75, root: rootFontSize), weight: .medium),
                                    color: translationColor,
                                    loops: false,
                                    lineDuration: lineDuration(for: currentIdx, in: lyrics)
                                )
                                .frame(height: 18)
                                .frame(maxWidth: .infinity, alignment: appState.resolvedLyricsAlignment)
                                .environment(\.layoutDirection, currentTranslation.isRTL ? .rightToLeft : .leftToRight)
                            }
                        }
                        .lyricTapTarget(id: line.id, time: line.time)
                        .transition(.push(from: .bottom))
                    } else {
                        Text(line.text)
                            .font(.system(
                                size: .rem(distance == 1 ? 0.8125 : 0.75, root: rootFontSize),
                                weight: distance == 1 ? .medium : .regular
                            ))
                            .foregroundStyle(appState.contentColor.opacity(opacityFor(distance: distance)))
                            .lineLimit(1)
                            .blur(radius: blurFor(distance: distance))
                            .frame(height: 20)
                            .frame(maxWidth: .infinity, alignment: appState.resolvedLyricsAlignment)
                            .environment(\.layoutDirection, lineDirection)
                            .lyricTapTarget(id: line.id, time: line.time)
                            .transition(.push(from: .bottom))
                    }
                }
                .id(currentIdx)
            } else {
                Text("lyrics.no_lyrics")
                    .font(.system(size: .rem(0.8125, root: rootFontSize)))
                    .foregroundStyle(appState.contentColor.opacity(0.4))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // Clicking a line says "the singer is here now" (handled by DynamicIslandPanel).
        .lyricTapArea(owner: "expanded")
        .animation(.smooth(duration: 0.35), value: syncEngine.currentLineIndex)
    }

    private func contextRange(around index: Int, total: Int, visible: Int) -> ClosedRange<Int> {
        let half = visible / 2
        let start = max(0, index - half)
        let end = min(total - 1, start + visible - 1)
        let adjustedStart = max(0, end - visible + 1)
        return adjustedStart ... end
    }

    private func opacityFor(distance: Int) -> Double {
        switch distance {
        case 1: 0.55
        case 2: 0.3
        default: 0.15
        }
    }

    private func blurFor(distance: Int) -> CGFloat {
        switch distance {
        case 1: 0
        case 2: 0.3
        default: 0.8
        }
    }

    private func lineDuration(for index: Int, in lyrics: SyncedLyrics) -> Double? {
        guard index + 1 < lyrics.lines.count else { return nil }
        return lyrics.lines[index + 1].time - lyrics.lines[index].time
    }
}
