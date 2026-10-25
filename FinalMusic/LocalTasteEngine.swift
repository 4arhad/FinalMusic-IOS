import Foundation

// Local "For You" mix builder — the iOS counterpart of the Android client's
// `LocalTasteSuggestionEngine`: score the user's real playback signal, take the
// top few as seeds, then expand each seed through YouTube Music's own related
// songs (`/next` with playlistId RDAMVM<videoId>) with the same de-duplication,
// per-artist cap and junk-title filter. No account or Last.fm needed.
//
// Scoring, limits and filters live in LocalTasteCore (LocalTaste) so they can be
// checked exactly; this file only supplies real data and network calls.

@MainActor
enum LocalTasteEngine {
    struct Outcome {
        var tracks: [MusicTrack] = []
        var seeds: [String] = []
        var summary: String = ""
        var usedLikedFallback = false
    }

    static func build(limit: Int = LocalTaste.maxSuggestions, now: Date = Date()) async -> Outcome {
        let partOfDay = LocalTaste.PartOfDay.forHour(Calendar.current.component(.hour, from: now))
        let liked = LikedStore.shared.tracks
        let likedKeys = Set(liked.map(\.videoId))
        let recentKeys = Set(HistoryStore.shared.tracks.prefix(LocalTaste.recentKeyLimit).map(\.videoId))
        let since = now.addingTimeInterval(-Double(LocalTaste.recentWindowDays) * 86_400)

        // Android falls back from "most played in 30 days" to "recently played".
        var pool = PlayStatsStore.shared.mostPlayed(since: since, limit: LocalTaste.recentStatsLimit)
        if pool.isEmpty { pool = PlayStatsStore.shared.recentlyPlayed(LocalTaste.fallbackRecentLimit) }

        let scored = pool
            .filter { LocalTaste.isEligible(playTimeMs: $0.playTimeMs, skipCount: $0.skips) }
            .map { entry -> (entry: TrackPlayStats, score: Double) in
                let score = LocalTaste.score(playTimeMs: entry.playTimeMs,
                                             skipCount: entry.skips,
                                             isLiked: likedKeys.contains(entry.videoId),
                                             isRecent: recentKeys.contains(entry.videoId),
                                             partOfDay: partOfDay)
                return (entry, score)
            }
            .sorted { $0.score > $1.score }

        var outcome = Outcome()
        outcome.seeds = LocalTaste.seedVideoIds(scored.prefix(LocalTaste.seedCandidates).map {
            (videoId: $0.entry.videoId, score: $0.score)
        })
        if outcome.seeds.isEmpty, !liked.isEmpty {
            outcome.seeds = Array(liked.shuffled().prefix(LocalTaste.maxSeeds).map(\.videoId))
            outcome.usedLikedFallback = true
        }
        guard !outcome.seeds.isEmpty else {
            outcome.summary = "No local listening history yet — play a few songs first."
            return outcome
        }

        var suggestions: [MusicTrack] = []
        var seenKeys = Set<String>()
        var artistCounts: [String: Int] = [:]

        // Seed expansions run concurrently (they are independent network calls);
        // results are then admitted in seed order so the per-artist cap and
        // de-duplication stay deterministic.
        for candidates in await relatedForAll(outcome.seeds) {
            guard suggestions.count < limit else { break }
            suggestions.append(contentsOf: admit(candidates,
                                                 seenKeys: &seenKeys,
                                                 artistCounts: &artistCounts,
                                                 limit: min(LocalTaste.perSeedTake, limit - suggestions.count)))
        }

        // Android tops the list up from liked songs; the fan-out is bounded here
        // (see LocalTaste.maxLikedFillSeeds) and also fetched concurrently.
        if suggestions.count < limit, !liked.isEmpty {
            let fillSeeds = liked.shuffled().prefix(LocalTaste.maxLikedFillSeeds).map(\.videoId)
            for candidates in await relatedForAll(fillSeeds) {
                guard suggestions.count < limit else { break }
                suggestions.append(contentsOf: admit(candidates,
                                                     seenKeys: &seenKeys,
                                                     artistCounts: &artistCounts,
                                                     limit: limit - suggestions.count))
            }
        }

        outcome.tracks = Array(suggestions.prefix(limit))
        outcome.summary = "\(outcome.tracks.count) picks from \(outcome.seeds.count) seed"
            + (outcome.seeds.count == 1 ? "" : "s")
            + (outcome.usedLikedFallback ? " (seeded from liked songs — not enough play history yet)" : "")
            + "."
        return outcome
    }

    /// One seed's related songs, as (candidate, track) pairs, de-duplicated by
    /// track identity and shuffled — the Android code shuffles before slicing.
    private static func relatedPairs(_ seedVideoId: String) async -> [(candidate: LocalTaste.Candidate, track: MusicTrack)] {
        let related: [MusicTrack]
        do {
            related = try await InnerTube.radio(videoId: seedVideoId).tracks
        } catch {
            NSLog("LFY related_failed seed=%@ error=%@", seedVideoId, String(describing: error))
            return []
        }
        var seen = Set<String>()
        var pairs: [(candidate: LocalTaste.Candidate, track: MusicTrack)] = []
        for track in related.prefix(LocalTaste.relatedLimit) {
            let key = LocalTaste.trackKey(videoId: track.videoId, title: track.title, artist: track.artist)
            guard seen.insert(key).inserted else { continue }
            pairs.append((LocalTaste.Candidate(key: key, title: track.title,
                                               artist: track.artist, videoId: track.videoId), track))
        }
        return pairs.shuffled()
    }

    /// Related songs for several seeds, fetched concurrently and returned in the
    /// order the seeds were given (so the caps stay deterministic).
    private static func relatedForAll(_ seeds: [String]) async -> [[(candidate: LocalTaste.Candidate, track: MusicTrack)]] {
        guard !seeds.isEmpty else { return [] }
        return await withTaskGroup(of: (Int, [(candidate: LocalTaste.Candidate, track: MusicTrack)]).self) { group in
            for (index, seed) in seeds.enumerated() {
                group.addTask { (index, await relatedPairs(seed)) }
            }
            var buckets: [Int: [(candidate: LocalTaste.Candidate, track: MusicTrack)]] = [:]
            for await (index, pairs) in group { buckets[index] = pairs }
            return seeds.indices.map { buckets[$0] ?? [] }
        }
    }

    /// The accept step, keeping the tracks attached to the admitted candidates.
    private static func admit(_ pairs: [(candidate: LocalTaste.Candidate, track: MusicTrack)],
                              seenKeys: inout Set<String>,
                              artistCounts: inout [String: Int],
                              limit: Int) -> [MusicTrack] {
        let accepted = LocalTaste.admit(pairs.map(\.candidate),
                                        seenKeys: &seenKeys,
                                        artistCounts: &artistCounts,
                                        limit: limit)
        let acceptedKeys = Set(accepted.map(\.key))
        return pairs.filter { acceptedKeys.contains($0.candidate.key) }.map(\.track)
    }
}
