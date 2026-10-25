import Foundation
import Combine

// Per-track listening signal — the iOS counterpart of the Android client's
// `song_play_stats` table (SongPlayStatsEntity / SongPlayStatsRepository), which
// is exactly what its local "For You" engine scores:
// accumulated listened time, skip count, play count and last-played time.
// PlayerViewModel feeds this; LocalTasteEngine reads it.

struct TrackPlayStats: Codable, Identifiable, Equatable {
    var key: String              // videoId when known, else "title|artist"
    var videoId: String
    var title: String
    var artist: String
    var album: String?
    var artwork: String?
    var plays: Int = 0
    var skips: Int = 0
    var playTimeMs: Double = 0
    var lastPlayedAt: Date = .distantPast

    var id: String { key }
}

@MainActor
final class PlayStatsStore: ObservableObject {
    static let shared = PlayStatsStore()

    private let key = "lastwave.playStats"
    private let maxEntries = 500
    /// A play shorter than this that the user cuts short counts as a skip —
    /// the same 45 s bar the Android engine uses for "significant" listening.
    static let skipThresholdMs: Double = 45_000

    @Published private(set) var stats: [TrackPlayStats] = []

    init() { stats = Self.load(key) }

    // MARK: Recording

    /// Called when playback of a track actually starts.
    func recordStart(_ track: MusicTrack) {
        update(track) { entry in
            entry.plays += 1
            entry.lastPlayedAt = Date()
        }
    }

    /// Called with the elapsed milliseconds when playback pauses/stops or the
    /// track changes, so listened time accumulates per track.
    func recordListened(track: MusicTrack, elapsedMs: Double, completed: Bool) {
        guard elapsedMs > 0 else { return }
        update(track) { entry in
            entry.playTimeMs += elapsedMs
            entry.lastPlayedAt = Date()
            if !completed && elapsedMs < Self.skipThresholdMs {
                entry.skips += 1
            }
        }
    }

    func addPlayTime(_ track: MusicTrack, milliseconds: Double) {
        guard milliseconds > 0 else { return }
        update(track) { entry in
            entry.playTimeMs += milliseconds
        }
    }

    func recordSkip(_ track: MusicTrack) {
        update(track) { entry in
            entry.skips += 1
        }
    }

    func clear() {
        stats = []
        persistNow()
    }

    // MARK: Queries for the recommendation engine

    /// Tracks played since `since`, ordered by accumulated listened time.
    func mostPlayed(since: Date, limit: Int) -> [TrackPlayStats] {
        stats
            .filter { $0.lastPlayedAt >= since && $0.playTimeMs > 0 }
            .sorted { $0.playTimeMs > $1.playTimeMs }
            .prefix(limit)
            .map { $0 }
    }

    /// Fallback when the 30-day window has too few plays: the most recent tracks.
    func recentlyPlayed(_ limit: Int) -> [TrackPlayStats] {
        stats
            .filter { $0.playTimeMs > 0 }
            .sorted { $0.lastPlayedAt > $1.lastPlayedAt }
            .prefix(limit)
            .map { $0 }
    }

    // MARK: Persistence

    private func update(_ track: MusicTrack, transform: (inout TrackPlayStats) -> Void) {
        let key = track.videoId.isEmpty ? "\(track.title)|\(track.artist)" : track.videoId
        var entry: TrackPlayStats
        if let existing = stats.first(where: { $0.key == key }) {
            entry = existing
            stats.removeAll { $0.key == key }
        } else {
            entry = TrackPlayStats(
                key: key,
                videoId: track.videoId,
                title: track.title,
                artist: track.artist,
                album: track.album,
                artwork: track.artwork
            )
        }
        transform(&entry)
        stats.insert(entry, at: 0)
        if stats.count > maxEntries {
            stats = Array(stats.prefix(maxEntries))
        }
        schedulePersist()
    }

    private var persistTask: Task<Void, Never>?
    private func schedulePersist() {
        persistTask?.cancel()
        persistTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            self?.persistNow()
        }
    }

    private func persistNow() {
        guard let data = try? JSONEncoder().encode(stats) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    private static func load(_ key: String) -> [TrackPlayStats] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([TrackPlayStats].self, from: data) else { return [] }
        return decoded
    }

    /// Test hook: synthesise deterministic history so the engine can be exercised
    /// headlessly (mirrors the app's other -Seed* launch hooks).
    func seedForTesting(_ entries: [TrackPlayStats]) {
        stats = entries
        persistNow()
    }
}

enum LaunchSeed {
    static func playStats() -> [TrackPlayStats] {
        [
            TrackPlayStats(key: "seed1", videoId: "seed1", title: "Seed Track 1", artist: "Seed Artist", plays: 10, skips: 0, playTimeMs: 180_000, lastPlayedAt: Date()),
            TrackPlayStats(key: "seed2", videoId: "seed2", title: "Seed Track 2", artist: "Seed Artist", plays: 5, skips: 1, playTimeMs: 120_000, lastPlayedAt: Date().addingTimeInterval(-3600))
        ]
    }
}
