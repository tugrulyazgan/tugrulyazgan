import SwiftUI

/// Where the clickable lyric rows (expanded and full views) currently are, so
/// `DynamicIslandPanel` — which handles all plain clicks itself — can tell a click
/// on a lyric line apart from a click that should cycle the island size.
final class LyricTapTargets {
    static let shared = LyricTapTargets()

    /// Coordinate space on the island's root view, which fills the panel's hosting view.
    static let coordinateSpace = "islandRoot"

    struct Row: Equatable {
        /// Frame in the island root's (top-left origin) coordinates.
        let frame: CGRect
        let time: TimeInterval
    }

    private struct Group {
        var visibleArea: CGRect = .null
        var rows: [Int: Row] = [:]
    }

    /// Keyed by the view that registered them, so one view disappearing
    /// never wipes out the rows of the view replacing it.
    private var groups: [String: Group] = [:]

    func setVisibleArea(_ area: CGRect, owner: String) {
        groups[owner, default: Group()].visibleArea = area
    }

    func setRows(_ rows: [Int: Row], owner: String) {
        groups[owner, default: Group()].rows = rows
    }

    func clear(owner: String) {
        groups[owner] = nil
    }

    /// Start time of the lyric line under `point`, if any.
    func lineTime(at point: CGPoint) -> TimeInterval? {
        for group in groups.values where group.visibleArea.contains(point) {
            if let row = group.rows.values.first(where: { $0.frame.contains(point) }) {
                return row.time
            }
        }
        return nil
    }

    /// Short description for logging when a click finds no line.
    var debugSummary: String {
        groups.map { "\($0.key): area=\($0.value.visibleArea.integral) rows=\($0.value.rows.count)" }
            .joined(separator: "; ")
    }
}

struct LyricRowFramesKey: PreferenceKey {
    static let defaultValue: [Int: LyricTapTargets.Row] = [:]

    static func reduce(value: inout [Int: LyricTapTargets.Row], nextValue: () -> [Int: LyricTapTargets.Row]) {
        value.merge(nextValue()) { _, new in new }
    }
}

extension View {
    /// Publish this lyric row's on-screen frame for click-to-sync.
    func lyricTapTarget(id: Int, time: TimeInterval) -> some View {
        background(GeometryReader { geo in
            Color.clear.preference(
                key: LyricRowFramesKey.self,
                value: [id: LyricTapTargets.Row(frame: geo.frame(in: .named(LyricTapTargets.coordinateSpace)), time: time)]
            )
        })
    }

    /// Collect the rows published inside this view and its visible frame under `owner`.
    func lyricTapArea(owner: String) -> some View {
        onPreferenceChange(LyricRowFramesKey.self) { rows in
            LyricTapTargets.shared.setRows(rows, owner: owner)
        }
        .background(GeometryReader { geo in
            Color.clear
                .onAppear {
                    LyricTapTargets.shared.setVisibleArea(geo.frame(in: .named(LyricTapTargets.coordinateSpace)), owner: owner)
                }
                .onChange(of: geo.frame(in: .named(LyricTapTargets.coordinateSpace))) { _, frame in
                    LyricTapTargets.shared.setVisibleArea(frame, owner: owner)
                }
        })
        .onDisappear { LyricTapTargets.shared.clear(owner: owner) }
    }
}
