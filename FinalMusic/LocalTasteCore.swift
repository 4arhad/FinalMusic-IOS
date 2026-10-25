import Foundation

// Local "For You" taste scoring — a faithful port of the Android client's
// `data/generate/LocalTasteSuggestionEngine.kt` (itself a port of Nocturne's
// ForYouSuggestionEngine). Every weight, window and threshold below is the
// Android constant of the same name; the shipped behaviour is described, not
// guessed. Kept free of UI and of any InnerTube calls so the scoring can be
// checked exactly (see LastWaveCoreChecks).
//
// Provenance: https://github.com/Clash-Projects/LastWave-native
//   app/src/main/java/com/lastwave/app/data/generate/LocalTasteSuggestionEngine.kt
// The released v4.3.1 APK this was read alongside is the artifact REA inspected
// (signature evidence ev_02d7371b…, inventory evidence ev_d2c4130d…).

public enum LocalTaste {
    // MARK: Weights (Android: PLAY_WEIGHT, SKIP_PENALTY, LIKED_BONUS, …)
    public static let playWeight = 2.0
    public static let skipPenalty = 3.0
    public static let likedBonus = 5.0
    public static let recencyBonus = 1.5
    public static let timeOfDayBonus = 1.3

    // MARK: Selection limits (Android: MAX_SUGGESTIONS, MAX_TRACK_SEEDS, …)
    public static let maxSuggestions = 50
    public static let seedCandidates = 8
    public static let maxSeeds = 5
    public static let perSeedTake = 10
    public static let relatedLimit = 40
    public static let likedRelatedLimit = 30
    public static let maxPerArtist = 3
    public static let recentWindowDays = 30
    public static let recentStatsLimit = 100
    public static let fallbackRecentLimit = 50
    public static let recentKeyLimit = 20

    /// Upper bound on how many liked songs may be expanded while topping the list
    /// up. The Android engine loops over every liked song, which on a phone is a
    /// long tail of sequential related-songs calls; iOS bounds the fan-out so a
    /// mix build stays a few seconds instead of half a minute. Behaviour is
    /// otherwise the same (same filters, same order).
    public static let maxLikedFillSeeds = 12

    /// A track needs either fewer than 2 skips or real listening time to be
    /// eligible: `skipCount < 2 || totalPlayTimeMs > 45_000`.
    public static let significantPlayMs = 45_000.0

    /// Android's `isJunkTitle` keyword list, verbatim.
    public static let junkTitleKeywords = [
        "mashup", "mash up", "mash-up", "jukebox", "mega mix", "megamix",
        "non stop", "nonstop", "audio jukebox", "full album", "full songs", "compilation",
        "slowed + reverb", "slowed reverb", "slowed & reverb", "bass boosted", "8d audio",
        "karaoke", "ringtone", "instrumental", "1 hour", "10 hour", "clean version", "sped up",
    ]

    public enum PartOfDay: String, Equatable {
        case morning, afternoon, evening, night

        /// Android: MORNING 6..11, AFTERNOON 12..17, EVENING 18..21, else night.
        public static func forHour(_ hour: Int) -> PartOfDay {
            switch hour {
            case 6...11: return .morning
            case 12...17: return .afternoon
            case 18...21: return .evening
            default: return .night
            }
        }
    }

    /// Port of the Android `scoreStats` (Nocturne's `scoreSong`).
    ///
    /// `playTimeMs * 2 - skips * 3 + liked * 5 + recent * 1.5`, then multiplied by
    /// 1.3 at the edges of the day (recent in the morning, liked at night), and
    /// clamped at zero. Note the scale: play time is milliseconds, so the additive
    /// bonuses only decide between tracks with near-identical listening time —
    /// that is the shipped behaviour and is preserved deliberately.
    public static func score(playTimeMs: Double,
                             skipCount: Int,
                             isLiked: Bool,
                             isRecent: Bool,
                             partOfDay: PartOfDay) -> Double {
        var score = playTimeMs * playWeight
        score -= Double(skipCount) * skipPenalty
        if isLiked { score += likedBonus }
        if isRecent { score += recencyBonus }

        let hourBonus: Double
        switch partOfDay {
        case .morning: hourBonus = isRecent ? timeOfDayBonus : 1.0
        case .night: hourBonus = isLiked ? timeOfDayBonus : 1.0
        case .afternoon, .evening: hourBonus = 1.0
        }
        return max(0, score * hourBonus)
    }

    /// Android's eligibility filter before scoring.
    public static func isEligible(playTimeMs: Double, skipCount: Int) -> Bool {
        skipCount < 2 || playTimeMs > significantPlayMs
    }

    /// Android's `isJunkTitle`: case-insensitive substring match on any keyword.
    public static func isJunkTitle(_ title: String) -> Bool {
        let lowered = title.lowercased()
        return junkTitleKeywords.contains { lowered.contains($0) }
    }

    /// Android normalizes artists with `trim().lowercase()` for the per-artist cap.
    public static func artistKey(_ artist: String) -> String {
        artist.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// A stable identity for de-duplication: the video id when there is one,
    /// otherwise `title|artist` (Android's `GeneratedTrack.key` shape).
    public static func trackKey(videoId: String?, title: String, artist: String) -> String {
        if let videoId, !videoId.isEmpty { return videoId }
        return "\(title.lowercased())|\(artist.lowercased())"
    }

    /// One candidate for the suggestion list, carrying only what the filters need.
    public struct Candidate: Equatable, Sendable {
        public var key: String
        public var title: String
        public var artist: String
        public var videoId: String

        public init(key: String, title: String, artist: String, videoId: String) {
            self.key = key
            self.title = title
            self.artist = artist
            self.videoId = videoId
        }
    }

    /// The Android accept loop, as a function: rejects already-seen keys, junk
    /// titles and artists already at the cap, and records what it accepted.
    /// `candidates` are pre-shuffled by the caller, exactly as the Android code
    /// shuffles related results before taking a slice.
    public static func admit(_ candidates: [Candidate],
                             seenKeys: inout Set<String>,
                             artistCounts: inout [String: Int],
                             limit: Int,
                             blacklist: Set<String> = []) -> [Candidate] {
        var accepted: [Candidate] = []
        for candidate in candidates {
            if accepted.count >= limit { break }
            guard !blacklist.contains(candidate.key), !seenKeys.contains(candidate.key) else { continue }
            if isJunkTitle(candidate.title) { continue }
            let artist = artistKey(candidate.artist)
            let count = artistCounts[artist] ?? 0
            guard count < maxPerArtist else { continue }
            accepted.append(candidate)
            seenKeys.insert(candidate.key)
            artistCounts[artist] = count + 1
        }
        return accepted
    }

    /// Ranks scored stats and returns at most `maxSeeds` seed video ids,
    /// skipping blanks and duplicates (Android breaks out as soon as it has 5).
    public static func seedVideoIds(_ ranked: [(videoId: String, score: Double)],
                                    limit: Int = LocalTaste.maxSeeds) -> [String] {
        var seeds: [String] = []
        for entry in ranked {
            let id = entry.videoId.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty, !seeds.contains(id) else { continue }
            seeds.append(id)
            if seeds.count >= limit { break }
        }
        return seeds
    }
}
