import Foundation

/// Raw playback state returned from Spotify via AppleScript.
struct SpotifyPlaybackState {
    let trackId: String
    let title: String
    let artist: String
    let album: String
    let durationMs: Int
    let position: TimeInterval // seconds
    let isPlaying: Bool
    let artworkURL: String?
    /// When `position` was sampled — the midpoint of the AppleScript round trip,
    /// so the sync engine's anchor is not skewed by the script's own latency.
    var sampledAt = Date()
}

/// Reads Spotify playback state using AppleScript (low-latency, no auth needed).
final class SpotifyAppleScriptService {
    // Position and duration are returned as integer milliseconds (`div 1`): coercing a
    // real to text uses the system decimal separator ("83,45" on Turkish or German
    // macOS), which made the position unparseable and froze the lyrics on one line.
    private let script: String = """
    if application "Spotify" is running then
        tell application "Spotify"
            set trackId to id of current track
            set trackName to name of current track
            set trackArtist to artist of current track
            set trackAlbum to album of current track
            set trackDuration to duration of current track
            set playerPos to player position
            set playerState to player state as string
            set artURL to artwork url of current track
        end tell
        set posMs to (playerPos * 1000) div 1
        set durMs to trackDuration div 1
        return trackId & "||" & trackName & "||" & trackArtist & "||" & trackAlbum & "||" & (durMs as string) & "||" & (posMs as string) & "||" & playerState & "||" & artURL
    else
        return "NOT_RUNNING"
    end if
    """

    private let queue = DispatchQueue(label: "com.lyrisland.applescript", qos: .userInitiated)

    func fetchPlaybackState() async -> SpotifyPlaybackState? {
        await withCheckedContinuation { continuation in
            queue.async { [script] in
                let start = Date()
                var result = Self.executeScript(script)
                let end = Date()
                result?.sampledAt = start.addingTimeInterval(end.timeIntervalSince(start) / 2)
                continuation.resume(returning: result)
            }
        }
    }

    // MARK: - Playback Controls

    func playPause() async {
        await executeCommand("playpause")
    }

    func nextTrack() async {
        await executeCommand("next track")
    }

    func previousTrack() async {
        await executeCommand("previous track")
    }

    private func executeCommand(_ command: String) async {
        await withCheckedContinuation { continuation in
            queue.async {
                let source = """
                if application "Spotify" is running then
                    tell application "Spotify" to \(command)
                end if
                """
                guard let script = NSAppleScript(source: source) else {
                    continuation.resume()
                    return
                }
                var error: NSDictionary?
                script.executeAndReturnError(&error)
                if let error { logDebug("AppleScript command failed: \(error)") }
                continuation.resume()
            }
        }
    }

    /// Synchronous execution on the caller's thread — use only from background context.
    private static func executeScript(_ source: String) -> SpotifyPlaybackState? {
        guard let appleScript = NSAppleScript(source: source) else { return nil }

        var error: NSDictionary?
        let result = appleScript.executeAndReturnError(&error)

        if let error {
            logDebug("AppleScript execution failed: \(error)")
        }

        guard error == nil, let raw = result.stringValue, raw != "NOT_RUNNING" else {
            return nil
        }

        let parts = raw.components(separatedBy: "||")
        guard parts.count >= 7 else { return nil }

        let durationMs = Int(parseNumber(parts[4]) ?? 0)
        let position = normalizedPosition(milliseconds: parseNumber(parts[5]) ?? 0, durationMs: durationMs)
        let isPlaying = parts[6] == "playing"
        let artworkURL = parts.count > 7 ? parts[7] : nil

        return SpotifyPlaybackState(
            trackId: parts[0],
            title: parts[1],
            artist: parts[2],
            album: parts[3],
            durationMs: durationMs,
            position: position,
            isPlaying: isPlaying,
            artworkURL: artworkURL
        )
    }

    // MARK: - Number Parsing

    /// Parse a number coming out of AppleScript regardless of the system locale.
    /// Accepts both "83.45" and "83,45" (AppleScript localizes the decimal separator).
    static func parseNumber(_ raw: String) -> Double? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let value = Double(trimmed) { return value }
        return Double(trimmed.replacingOccurrences(of: ",", with: "."))
    }

    /// Convert the script's millisecond position to seconds. Guards against Spotify
    /// builds that already report milliseconds (the value would then be 1000× too large).
    static func normalizedPosition(milliseconds: Double, durationMs: Int) -> TimeInterval {
        var seconds = milliseconds / 1000
        if durationMs > 0, seconds > Double(durationMs) / 1000 + 5 {
            seconds /= 1000
        }
        return max(0, seconds)
    }
}
