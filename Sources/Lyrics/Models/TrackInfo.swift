import Foundation

/// Minimal track metadata used to query lyrics providers.
struct TrackInfo {
    let id: String
    let title: String
    let artist: String
    let album: String
    let durationMs: Int

    var durationSeconds: Double {
        Double(durationMs) / 1000.0
    }
}
