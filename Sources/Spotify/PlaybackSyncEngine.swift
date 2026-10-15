import Combine
import Foundation
import QuartzCore

/// Maintains a high-precision interpolated playback position.
///
/// AppleScript polls every ~200ms and provides a "calibration anchor".
/// Between polls a display-link timer linearly interpolates the position
/// so lyric scrolling stays smooth.
@MainActor
final class PlaybackSyncEngine: ObservableObject {
    @Published private(set) var isPlaying: Bool = false
    @Published private(set) var currentTrackId: String?
    @Published private(set) var artworkURL: URL?
    @Published private(set) var trackTitle: String?
    @Published private(set) var trackArtist: String?

    /// Monotonically incrementing tick used internally to update position.
    /// NOT @Published — views should depend on `currentLineIndex` or other
    /// published properties instead of rebuilding every frame.
    private(set) var tick: UInt64 = 0

    /// Cached current line index — only published when it actually changes,
    /// so views that only care about line identity don't redraw every tick.
    @Published private(set) var currentLineIndex: Int?

    /// The current interpolated position (seconds). Read this in view bodies.
    private(set) var position: TimeInterval = 0

    /// Reference to lyrics for line index caching.
    weak var lyricsManager: LyricsManager? {
        didSet {
            lyricsSubscription = lyricsManager?.$currentLyrics.sink { [weak self] lyrics in
                self?.lyricsDidChange(lyrics)
            }
        }
    }

    private var lyricsSubscription: AnyCancellable?

    /// Reference to Spotify service for playback commands.
    var spotifyService: SpotifyAppleScriptService?

    /// The most recent anchor: (system timestamp, playback position in seconds).
    private var anchor: (date: Date, position: TimeInterval)?

    private var displayLink: CVDisplayLink?
    private var tickTimer: Timer?

    init() {
        startTickTimer()
    }

    deinit {
        tickTimer?.invalidate()
    }

    /// Drift (seconds) below which a new sample is blended into the running clock
    /// instead of replacing it. AppleScript jitter is a few tens of milliseconds;
    /// snapping to every sample made the active line flicker at line boundaries.
    nonisolated static let softCorrectionThreshold: TimeInterval = 0.3

    /// Fraction of a small drift corrected per sample.
    nonisolated static let softCorrectionFactor: Double = 0.35

    /// Called by the AppleScript polling timer.
    /// - Parameter sampledAt: When Spotify reported `position` (defaults to now).
    func calibrate(position: TimeInterval, isPlaying: Bool, sampledAt: Date = Date()) {
        anchor = Self.nextAnchor(
            previous: anchor,
            wasPlaying: self.isPlaying,
            position: position,
            isPlaying: isPlaying,
            sampledAt: sampledAt
        )

        // Only publish when play state actually changes to avoid unnecessary view rebuilds
        if self.isPlaying != isPlaying {
            self.isPlaying = isPlaying
            startTickTimer()
        }
    }

    /// Pure anchor update: hard re-anchor on seeks, pauses and track changes;
    /// gently converge on small drift while playback runs continuously.
    nonisolated static func nextAnchor(
        previous: (date: Date, position: TimeInterval)?,
        wasPlaying: Bool,
        position: TimeInterval,
        isPlaying: Bool,
        sampledAt: Date
    ) -> (date: Date, position: TimeInterval) {
        guard let previous, wasPlaying, isPlaying else {
            return (sampledAt, position)
        }
        let predicted = previous.position + sampledAt.timeIntervalSince(previous.date)
        let drift = position - predicted
        guard abs(drift) < softCorrectionThreshold else {
            return (sampledAt, position)
        }
        return (sampledAt, predicted + drift * softCorrectionFactor)
    }

    func setTrackId(_ id: String?) {
        if id != currentTrackId {
            logInfo("Track changed: \(id ?? "nil")")
            currentTrackId = id
        }
    }

    func setArtworkURL(_ urlString: String?) {
        let url = urlString.flatMap { URL(string: $0) }
        if url != artworkURL {
            artworkURL = url
        }
    }

    func setTrackInfo(title: String?, artist: String?) {
        if title != trackTitle { trackTitle = title }
        if artist != trackArtist { trackArtist = artist }
    }

    // MARK: - Playback Controls

    func playPause() {
        Task { await spotifyService?.playPause() }
    }

    func nextTrack() {
        Task { await spotifyService?.nextTrack() }
    }

    func previousTrack() {
        Task { await spotifyService?.previousTrack() }
    }

    /// Linearly interpolated position.
    var interpolatedPosition: TimeInterval {
        guard let anchor, isPlaying else {
            return anchor?.position ?? 0
        }
        return anchor.position + Date().timeIntervalSince(anchor.date)
    }

    // MARK: - Tick Timer

    /// Use a Timer on the main run loop at ~30 fps when playing, paused when not.
    /// Each tick updates `position` and the cached `currentLineIndex`.
    /// Only `currentLineIndex` is @Published, so views update only on line changes.
    private func startTickTimer() {
        tickTimer?.invalidate()

        guard isPlaying else {
            // One final update so the UI shows the paused position
            updatePosition()
            return
        }

        // ~30 fps is enough for line-level lyrics scrolling
        tickTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updatePosition()
            }
        }
        // Keep firing even during tracking loops (e.g. window drag)
        RunLoop.main.add(tickTimer!, forMode: .common)
    }

    /// Recompute the line index against newly loaded lyrics right away.
    /// The tick timer is stopped while paused, so a track change during pause would otherwise keep
    /// the previous track's index and views would read past the end of the new lines (crash).
    /// `$currentLyrics` emits before the property is set, so the new value is passed in.
    func lyricsDidChange(_ lyrics: SyncedLyrics?) {
        let newIdx = lyrics?.lineIndex(at: interpolatedPosition)
        if newIdx != currentLineIndex {
            currentLineIndex = newIdx
        }
    }

    private func updatePosition() {
        position = interpolatedPosition
        tick &+= 1

        // Update cached line index — only publishes when it actually changes
        let newIdx = lyricsManager?.currentLyrics?.lineIndex(at: position)
        if newIdx != currentLineIndex {
            currentLineIndex = newIdx
        }
    }
}
