import SwiftUI

/// Where the full-view lyric rows currently are on screen, so `DynamicIslandPanel`
/// (which handles all plain clicks itself) can tell a click on a lyric line apart
/// from a click that should cycle the island size.
final class LyricTapTargets {
    static let shared = LyricTapTargets()

    struct Row: Equatable {
        /// Frame in the hosting view's (top-left origin) coordinates.
        let frame: CGRect
        let time: TimeInterval
    }

    /// The scroll view's visible frame; rows scrolled out of it don't count.
    var visibleArea: CGRect = .null
    var rows: [Int: Row] = [:]

    /// Start time of the lyric line under `point`, if any.
    func lineTime(at point: CGPoint) -> TimeInterval? {
        guard visibleArea.contains(point) else { return nil }
        return rows.values.first { $0.frame.contains(point) }?.time
    }

    func clear() {
        visibleArea = .null
        rows = [:]
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
                value: [id: LyricTapTargets.Row(frame: geo.frame(in: .global), time: time)]
            )
        })
    }
}
