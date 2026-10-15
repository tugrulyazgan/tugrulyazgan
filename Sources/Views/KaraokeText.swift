import SwiftUI

/// One lyric line that fills with color as it is sung and, when too wide for its
/// container, scrolls at the singer's pace (driven by `progress`, not a fixed speed).
struct KaraokeText: View {
    let text: String
    let font: Font
    let sungColor: Color
    let unsungColor: Color
    /// 0…1 fraction of the line already sung.
    let progress: Double

    var fadeWidth: CGFloat = 16

    @State private var textWidth: CGFloat = 0
    @State private var containerWidth: CGFloat = 0

    private var overflow: CGFloat {
        max(0, textWidth - containerWidth)
    }

    /// Keep the sung edge around 60% across the container, so the upcoming words stay visible.
    private var offset: CGFloat {
        guard overflow > 0 else { return 0 }
        let sungEdge = textWidth * progress
        return -min(overflow, max(0, sungEdge - containerWidth * 0.6))
    }

    var body: some View {
        Text(text)
            .font(font)
            .lineLimit(1)
            .hidden()
            .overlay(alignment: .leading) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Text(text)
                            .font(font)
                            .foregroundStyle(unsungColor)
                        Text(text)
                            .font(font)
                            .foregroundStyle(sungColor)
                            .mask(alignment: .leading) {
                                Rectangle().frame(width: textWidth * progress)
                            }
                    }
                    .fixedSize(horizontal: true, vertical: false)
                    .background(GeometryReader { textGeo in
                        Color.clear
                            .onAppear { textWidth = textGeo.size.width }
                            .onChange(of: textGeo.size.width) { _, width in textWidth = width }
                    })
                    .offset(x: offset)
                    .onAppear { containerWidth = geo.size.width }
                    .onChange(of: geo.size.width) { _, width in containerWidth = width }
                }
                .clipped()
                .mask(fadeMask)
                .environment(\.layoutDirection, .leftToRight)
            }
    }

    @ViewBuilder
    private var fadeMask: some View {
        if overflow > 0 {
            HStack(spacing: 0) {
                LinearGradient(colors: [.clear, .white], startPoint: .leading, endPoint: .trailing)
                    .frame(width: offset < 0 ? fadeWidth : 0)
                Rectangle().fill(.white)
                LinearGradient(colors: [.white, .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: offset > -overflow ? fadeWidth : 0)
            }
        } else {
            Rectangle().fill(.white)
        }
    }
}

/// The current lyric line, re-rendered every frame while playing so it fills and
/// scrolls in step with the vocals. Right-to-left text keeps the classic marquee.
struct LiveLyricLine: View {
    @ObservedObject var syncEngine: PlaybackSyncEngine
    let lyrics: SyncedLyrics
    let index: Int
    let font: Font
    let color: Color

    var body: some View {
        if let line = lyrics.lines.indices.contains(index) ? lyrics.lines[index] : nil {
            content(for: line)
        }
    }

    @ViewBuilder
    private func content(for line: LyricLine) -> some View {
        if line.text.isRTL {
            MarqueeText(text: line.text, font: font, color: color, loops: false, lineDuration: lineDuration)
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !syncEngine.isPlaying)) { _ in
                KaraokeText(
                    text: line.text,
                    font: font,
                    sungColor: color,
                    unsungColor: color.opacity(0.45),
                    progress: lyrics.progress(ofLine: index, at: syncEngine.interpolatedPosition)
                )
            }
        }
    }

    private var lineDuration: Double? {
        guard index + 1 < lyrics.lines.count else { return nil }
        return lyrics.lines[index + 1].time - lyrics.lines[index].time
    }
}
