import SwiftUI

/// Auto-scrolling lyrics list that tracks the current playback position.
/// Only re-renders when the current line index changes, not on every tick.
struct LyricsScrollView: View {
    @ObservedObject var syncEngine: PlaybackSyncEngine
    let lyrics: SyncedLyrics
    let currentLineIndex: Int
    var alignment: Alignment = .leading
    @Environment(\.rootFontSize) private var rootFontSize
    @Environment(\.contentColor) private var contentColor
    @Environment(\.translationColor) private var translationColor

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 6) {
                    Spacer(minLength: 40)

                    ForEach(lyrics.lines) { line in
                        if line.id == currentLineIndex {
                            currentRow(line)
                                .lyricTapTarget(id: line.id, time: line.time)
                                .frame(maxWidth: .infinity, alignment: alignment)
                                .environment(\.layoutDirection, line.text.isRTL ? .rightToLeft : .leftToRight)
                                .id(line.id)
                        } else {
                            LyricLineRow(
                                text: line.text,
                                translation: line.translation,
                                isCurrent: line.id == currentLineIndex,
                                distance: abs(line.id - currentLineIndex),
                                lineDuration: lineDuration(for: line.id),
                                rootFontSize: rootFontSize,
                                contentColor: contentColor,
                                translationColor: translationColor
                            )
                            .lyricTapTarget(id: line.id, time: line.time)
                            .frame(maxWidth: .infinity, alignment: alignment)
                            .environment(\.layoutDirection, line.text.isRTL ? .rightToLeft : .leftToRight)
                            .id(line.id)
                        }
                    }

                    Spacer(minLength: 40)
                }
                .padding(.horizontal, 20)
            }
            // Clicking a line says "the singer is here now" (handled by DynamicIslandPanel).
            .lyricTapArea(owner: "full")
            .onAppear {
                proxy.scrollTo(currentLineIndex, anchor: .center)
            }
            .onChange(of: currentLineIndex) { _, newIdx in
                withAnimation(.easeInOut(duration: 0.3)) {
                    proxy.scrollTo(newIdx, anchor: .center)
                }
            }
        }
    }

    /// The line being sung: fills and scrolls with the vocals, translation underneath.
    private func currentRow(_ line: LyricLine) -> some View {
        VStack(spacing: 2) {
            LiveLyricLine(
                syncEngine: syncEngine,
                lyrics: lyrics,
                index: line.id,
                font: .system(size: .rem(0.9375, root: rootFontSize), weight: .bold),
                color: contentColor
            )
            if let translation = line.translation {
                MarqueeText(
                    text: translation,
                    font: .system(size: .rem(0.75, root: rootFontSize), weight: .medium),
                    color: translationColor,
                    loops: false,
                    lineDuration: lineDuration(for: line.id)
                )
            }
        }
    }

    private func lineDuration(for index: Int) -> Double? {
        guard index + 1 < lyrics.lines.count else { return nil }
        return lyrics.lines[index + 1].time - lyrics.lines[index].time
    }
}

/// Individual lyric line — Equatable so SwiftUI skips body evaluation
/// when this line's state hasn't changed (only ~2 lines change per index shift).
private struct LyricLineRow: View, Equatable {
    let text: String
    let translation: String?
    let isCurrent: Bool
    let distance: Int
    let lineDuration: Double?
    let rootFontSize: CGFloat
    let contentColor: Color
    let translationColor: Color

    var body: some View {
        VStack(spacing: 2) {
            if isCurrent {
                MarqueeText(
                    text: text,
                    font: .system(size: .rem(0.9375, root: rootFontSize), weight: .bold),
                    color: contentColor,
                    loops: false,
                    lineDuration: lineDuration
                )
            } else {
                Text(text)
                    .font(.system(size: .rem(0.75, root: rootFontSize)))
                    .foregroundStyle(contentColor.opacity(0.35))
                    .lineLimit(1)
                    .blur(radius: blurAmount)
                    .scaleEffect(0.95)
            }

            if let translation {
                if isCurrent {
                    MarqueeText(
                        text: translation,
                        font: .system(size: .rem(0.75, root: rootFontSize), weight: .medium),
                        color: translationColor,
                        loops: false,
                        lineDuration: lineDuration
                    )
                } else {
                    Text(translation)
                        .font(.system(size: .rem(0.6875, root: rootFontSize)))
                        .foregroundStyle(translationColor.opacity(0.3))
                        .lineLimit(1)
                        .blur(radius: blurAmount)
                }
            }
        }
        .animation(.smooth(duration: 0.35), value: isCurrent)
    }

    private var blurAmount: CGFloat {
        if distance == 0 { return 0 }
        if distance <= 2 { return 0.3 }
        return 0.8
    }
}
