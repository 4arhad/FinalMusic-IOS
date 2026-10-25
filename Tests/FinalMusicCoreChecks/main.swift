import Foundation
import FinalMusicCore

let url = try YouTubeDataClient.searchURL(query: "dream pop", apiKey: "test key")
let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
precondition(url.host == "www.googleapis.com")
precondition(url.path == "/youtube/v3/search")
precondition(queryItems.first(where: { $0.name == "q" })?.value == "dream pop")
precondition(queryItems.first(where: { $0.name == "key" })?.value == "test key")

do {
    _ = try YouTubeDataClient.searchURL(query: "track", apiKey: " ")
    preconditionFailure("An empty API key must be rejected.")
} catch {}

let response = Data(#"{"items":[{"id":{"videoId":"abcdefghijk"},"snippet":{"title":"Dream Song","channelTitle":"Artist","thumbnails":{"medium":{"url":"https://i.ytimg.com/vi/abcdefghijk/mqdefault.jpg"}}}},{"id":{},"snippet":{"title":"Not a video","channelTitle":"Channel"}}]}"#.utf8)
let videos = try YouTubeDataClient.decodeSearchResponse(response)
precondition(videos == [YouTubeVideo(
    id: "abcdefghijk",
    title: "Dream Song",
    channelTitle: "Artist",
    thumbnailURL: URL(string: "https://i.ytimg.com/vi/abcdefghijk/mqdefault.jpg")
)])

let timedLyrics = SyncedLyricsParser.parse("""
[00:02.50][00:04.00]Second phrase
[00:01.2]First phrase
[ar:Artist]
""")
precondition(timedLyrics.map(\.text) == ["First phrase", "Second phrase", "Second phrase"])
precondition(abs(timedLyrics[0].timestamp - 1.2) < 0.000_001)
precondition(SyncedLyricsParser.activeLineIndex(in: timedLyrics, at: 3.0) == 1)
precondition(SyncedLyricsParser.parse("[ti:Song]\n[00:01.00]").isEmpty)

precondition(!ScrobblePolicy.shouldScrobble(elapsed: 59.9, duration: 120))
precondition(ScrobblePolicy.shouldScrobble(elapsed: 60, duration: 120))
precondition(!ScrobblePolicy.shouldScrobble(elapsed: 239, duration: 600))
precondition(ScrobblePolicy.shouldScrobble(elapsed: 240, duration: 600))
precondition(!ScrobblePolicy.shouldScrobble(elapsed: 1, duration: 0))
print("YouTube, lyrics, and scrobble core checks passed.")

// Last.fm signing (authspec semantics: sorted, skip api_sig/format/callback,
// append secret, MD5) verified against an independently computed hashlib vector.
precondition(LastFmSigner.md5("abc") == "900150983cd24fb0d6963f7d28e17f72")
precondition(LastFmSigner.md5("a1b2methodtrack.scrobble3cr3t") == "4a64d3e8d30b24bdce1eae8e3fe4c8b8")
precondition(
    LastFmSigner.sign(
        params: ["b": "2", "a": "1", "callback": "x", "format": "json", "api_sig": "y", "method": "track.scrobble"],
        secret: "3cr3t"
    ) == "4a64d3e8d30b24bdce1eae8e3fe4c8b8"
)
precondition(LastFmSigner.normalizeKey(" A1b2\u{200B}-Gx!9 ") == "a1b29")
print("Last.fm signer checks passed.")

// InnerTube parser port checks (duration, artwork, collector).
precondition(InnerTube.parseDuration("3:45") == 225)
precondition(InnerTube.parseDuration("1:02:03") == 3723)
precondition(InnerTube.parseDuration("not a time") == nil)
precondition(
    InnerTube.highResolutionArtwork("https://lh3.googleusercontent.com/x=cd") ==
    "https://lh3.googleusercontent.com/x=w512-h512-l90-rj"
)
let nested: Any = ["a": ["musicResponsiveListItemRenderer": ["videoId": "abc"]]]
precondition(InnerTube.collectObjects(nested, key: "musicResponsiveListItemRenderer").count == 1)
precondition(InnerTube.findString(in: nested, key: "videoId") == "abc")
precondition(LRCLIBClient.lyricsURL(artist: " Beach House ", title: "") == nil)
print("InnerTube parser checks passed.")

// YouTube Music account credentials: cookie parsing + SAPISIDHASH signing.
// The expected hashes were computed independently with hashlib.
let cookieHeader = "SID=abc; HSID=def; SAPISID=AbCdEf123; __Secure-3PAPISID=Zz9-xQ"
precondition(YouTubeCredential(rawCookies: cookieHeader)?.sapisid == "AbCdEf123")
precondition(YouTubeCredential(rawCookies: "Cookie: \(cookieHeader)")?.sapisid == "AbCdEf123")
precondition(YouTubeCredential(rawCookies: #"{"SAPISID":"AbCdEf123","SID":"abc"}"#)?.sapisid == "AbCdEf123")
precondition(YouTubeCredential(rawCookies: "SID=abc; HSID=def") == nil)
precondition(YouTubeCredential(rawCookies: "   ") == nil)

let credential = YouTubeCredential(rawCookies: cookieHeader)!
let stamp = Date(timeIntervalSince1970: 1_750_000_000)
precondition(credential.authorization(now: stamp)
    == "SAPISIDHASH 1750000000_6768ad0ce0eb22c90e65a0bf46bdfad218dc8465")
let headers = credential.requestHeaders(now: stamp)
precondition(headers["Cookie"]?.contains("SAPISID=AbCdEf123") == true)
precondition(headers["X-Goog-AuthUser"] == "0")
precondition(headers["Origin"] == "https://music.youtube.com")
precondition(headers["X-Origin"] == "https://music.youtube.com")
precondition(credential.cookieHeader.contains("SAPISID=AbCdEf123"))
// Falls back to the 3P cookie when plain SAPISID is absent.
precondition(YouTubeCredential(rawCookies: "__Secure-3PAPISID=Zz9-xQ")?
    .authorization(now: stamp) == "SAPISIDHASH 1750000000_aec3b4b71c18e838e1094d8be642beb32d9327df")
print("YouTube credential checks passed.")

// OAuth device-code flow + token handling (the shape of Google's responses is
// taken from a live /device/code call and the documented token responses).
let deviceJSON = #"{"device_code":"DC-1","user_code":"RXQ-PBM-BVSH","verification_url":"https://www.google.com/device","expires_in":1800,"interval":5}"#.data(using: .utf8)!
let device = DeviceCodeResponse.decode(deviceJSON)!
precondition(device.userCode == "RXQ-PBM-BVSH")
precondition(device.interval == 5 && device.expiresIn == 1800)
precondition(device.verificationURL.absoluteString == "https://www.google.com/device")
precondition(DeviceCodeResponse.decode(Data("{}".utf8)) == nil)
precondition(DeviceCodeResponse.decode(Data("not json".utf8)) == nil)

let now = Date(timeIntervalSince1970: 1_750_000_000)
let token = YouTubeToken(json: ["access_token": "ya29.abc", "expires_in": 3600,
                               "refresh_token": "1//refresh", 
                               "scope": "https://www.googleapis.com/auth/youtube"], now: now)!
precondition(token.accessToken == "ya29.abc" && token.refreshToken == "1//refresh")
precondition(abs(token.expiresAt.timeIntervalSince1970 - 1_750_003_600) < 0.001)
precondition(!token.isExpired(now: now))
precondition(!token.isExpired(now: now.addingTimeInterval(3500)))      // outside the 60 s leeway
precondition(token.isExpired(now: now.addingTimeInterval(3560)))       // inside the 60 s leeway
// A refresh response carries no refresh_token — the stored one must survive.
let refreshed = YouTubeToken(json: ["access_token": "ya29.new", "expires_in": 3600],
                             now: now, keepingRefreshToken: "1//refresh")!
precondition(refreshed.accessToken == "ya29.new" && refreshed.refreshToken == "1//refresh")
precondition(YouTubeToken(json: ["expires_in": 3600], now: now) == nil)
precondition(YouTubeToken(json: ["access_token": ""], now: now) == nil)
// Survives a round trip through the persisted JSON form.
precondition(YouTubeToken.from(json: token.json) == token)
precondition(YouTubeToken.from(json: ["access_token": "x"]) == nil)

// Auth headers: a bearer call must not also claim the cookie identity.
let bearerAuth = InnerTubeAuth(bearer: "ya29.abc")
precondition(bearerAuth.headers()["Authorization"] == "Bearer ya29.abc")
precondition(bearerAuth.headers()["Cookie"] == nil)
precondition(bearerAuth.headers()["X-Goog-AuthUser"] == nil)
precondition(bearerAuth.headers()["X-Origin"] == "https://music.youtube.com")
precondition(bearerAuth.hasBearer && !bearerAuth.isEmpty)
let cookieAuth = InnerTubeAuth(credential: credential)
precondition(cookieAuth.headers(now: stamp)["Authorization"]
    == "SAPISIDHASH 1750000000_6768ad0ce0eb22c90e65a0bf46bdfad218dc8465")
precondition(cookieAuth.headers(now: stamp)["Cookie"]?.contains("SAPISID=AbCdEf123") == true)
precondition(!cookieAuth.hasBearer)
precondition(InnerTubeAuth().isEmpty)
print("YouTube OAuth checks passed.")

// "For You" scoring — a faithful port of the shipped Android engine's weights
// (LocalTasteSuggestionEngine: PLAY_WEIGHT 2.0, SKIP_PENALTY 3.0, LIKED_BONUS 5.0,
// RECENCY_BONUS 1.5, TIME_OF_DAY_BONUS 1.3, eligibility skip<2 || time>45 s).
func approx(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 0.0001 }
precondition(approx(LocalTaste.score(playTimeMs: 30_000, skipCount: 1, isLiked: true,
                                     isRecent: true, partOfDay: .morning), 78_004.55))
precondition(approx(LocalTaste.score(playTimeMs: 30_000, skipCount: 1, isLiked: false,
                                     isRecent: false, partOfDay: .evening), 59_997))
precondition(approx(LocalTaste.score(playTimeMs: 1_000, skipCount: 0, isLiked: true,
                                     isRecent: true, partOfDay: .night), 2_608.45))
// The hour multiplier only applies at the edges of the day.
precondition(approx(LocalTaste.score(playTimeMs: 1_000, skipCount: 0, isLiked: true,
                                     isRecent: true, partOfDay: .afternoon), 2_006.5))
precondition(approx(LocalTaste.score(playTimeMs: 1_000, skipCount: 0, isLiked: false,
                                     isRecent: false, partOfDay: .afternoon), 2_000))
// Scores are clamped at zero, never negative.
precondition(LocalTaste.score(playTimeMs: 0, skipCount: 5, isLiked: false,
                              isRecent: false, partOfDay: .afternoon) == 0)
// Day-part windows: MORNING 6..11, AFTERNOON 12..17, EVENING 18..21, else night.
precondition(LocalTaste.PartOfDay.forHour(5) == .night)
precondition(LocalTaste.PartOfDay.forHour(6) == .morning)
precondition(LocalTaste.PartOfDay.forHour(11) == .morning)
precondition(LocalTaste.PartOfDay.forHour(12) == .afternoon)
precondition(LocalTaste.PartOfDay.forHour(17) == .afternoon)
precondition(LocalTaste.PartOfDay.forHour(18) == .evening)
precondition(LocalTaste.PartOfDay.forHour(21) == .evening)
precondition(LocalTaste.PartOfDay.forHour(22) == .night)
// Eligibility: skipCount < 2 || playTimeMs > 45_000.
precondition(LocalTaste.isEligible(playTimeMs: 0, skipCount: 1))
precondition(!LocalTaste.isEligible(playTimeMs: 20_000, skipCount: 2))
precondition(!LocalTaste.isEligible(playTimeMs: 44_999, skipCount: 2))
precondition(LocalTaste.isEligible(playTimeMs: 46_000, skipCount: 2))
precondition(LocalTaste.isEligible(playTimeMs: 45_001, skipCount: 9))
// Junk-title filter (Android substring list, case-insensitive).
precondition(LocalTaste.isJunkTitle("Song (Slowed + Reverb)"))
precondition(LocalTaste.isJunkTitle("KARAOKE VERSION"))
precondition(LocalTaste.isJunkTitle("Best of 90s 1 hour mix"))
precondition(LocalTaste.isJunkTitle("8D Audio Experience"))
precondition(!LocalTaste.isJunkTitle("Instant Crush"))
precondition(!LocalTaste.isJunkTitle("Veridis Quo"))
// Artist cap (3) and de-duplication, applied in the order candidates arrive.
var seen = Set<String>()
var artists: [String: Int] = [:]
let repeated = (1...6).map {
    LocalTaste.Candidate(key: "v\($0)", title: "Track \($0)", artist: "Daft Punk", videoId: "v\($0)")
}
let admittedArtist = LocalTaste.admit(repeated, seenKeys: &seen, artistCounts: &artists, limit: 10)
precondition(admittedArtist.count == LocalTaste.maxPerArtist)
precondition(artists[LocalTaste.artistKey(" daft punk ")] == LocalTaste.maxPerArtist)
var seen2 = Set(["dup"])
var artists2: [String: Int] = [:]
let dupes = [LocalTaste.Candidate(key: "dup", title: "Dup", artist: "A", videoId: "dup"),
             LocalTaste.Candidate(key: "fresh", title: "Fresh", artist: "A", videoId: "fresh")]
precondition(LocalTaste.admit(dupes, seenKeys: &seen2, artistCounts: &artists2, limit: 10).map(\.key) == ["fresh"])
// Blacklist and junk titles are rejected inside the accept loop.
var seen3 = Set<String>()
var artists3: [String: Int] = [:]
let mixed = [LocalTaste.Candidate(key: "b1", title: "Banned", artist: "A", videoId: "b1"),
             LocalTaste.Candidate(key: "j1", title: "Karaoke Hit", artist: "B", videoId: "j1"),
             LocalTaste.Candidate(key: "ok", title: "Fine", artist: "C", videoId: "ok")]
precondition(LocalTaste.admit(mixed, seenKeys: &seen3, artistCounts: &artists3,
                              limit: 10, blacklist: ["b1"]).map(\.key) == ["ok"])
// Seed selection: blanks dropped, duplicates collapsed, capped at 5.
precondition(LocalTaste.seedVideoIds([("a", 10), ("", 9), ("a", 8), ("b", 7),
                                      ("c", 6), ("d", 5), ("e", 4), ("f", 3)]) == ["a", "b", "c", "d", "e"])
precondition(LocalTaste.seedVideoIds([(" ", 1)]) == [])
// Track identity: video id wins, otherwise title|artist.
precondition(LocalTaste.trackKey(videoId: "abc", title: "T", artist: "A") == "abc")
precondition(LocalTaste.trackKey(videoId: nil, title: "T", artist: "A") == "t|a")
precondition(LocalTaste.trackKey(videoId: "", title: "T", artist: "A") == "t|a")
print("Local taste checks passed.")

// ---------------------------------------------------------------------------
// Artwork cache policy: URL shaping, stable disk keys, eviction, dedupe.
// ---------------------------------------------------------------------------

// yt3-style size tokens clamp at the requested cap, other parts survive.
precondition(ArtworkPolicy.sizedURLString(
    for: "https://yt3.ggpht.com/x/y/Z=s680-c-k-no", maxPixel: 144)
    == "https://yt3.ggpht.com/x/y/Z=s144-c-k-no")
precondition(ArtworkPolicy.sizedURLString(
    for: "https://yt3.ggpht.com/x/y/Z=s100-c-k-no", maxPixel: 144)
    == "https://yt3.ggpht.com/x/y/Z=s100-c-k-no")          // already smaller
precondition(ArtworkPolicy.sizedURLString(
    for: "https://lh3.googleusercontent.com/a/b=w240-h240", maxPixel: 200)
    == "https://lh3.googleusercontent.com/a/b=w200-h200")  // every w/h/s token
precondition(ArtworkPolicy.sizedURLString(
    for: "https://example.com/plain.jpg", maxPixel: 144)
    == "https://example.com/plain.jpg")                    // unrecognised: unchanged
precondition(ArtworkPolicy.sizedURLString(
    for: "https://yt3.googleusercontent.com/no-size-token", maxPixel: 144)
    == "https://yt3.googleusercontent.com/no-size-token")  // no token appended

// i.ytimg named variants map DOWN to the smallest standard size that still
// covers the request; anything already small enough stays put.
precondition(ArtworkPolicy.sizedURLString(
    for: "https://i.ytimg.com/vi/abcdefghijk/hqdefault.jpg", maxPixel: 144)
    == "https://i.ytimg.com/vi/abcdefghijk/mqdefault.jpg")
precondition(ArtworkPolicy.sizedURLString(
    for: "https://i.ytimg.com/vi/abcdefghijk/maxresdefault.jpg", maxPixel: 320)
    == "https://i.ytimg.com/vi/abcdefghijk/mqdefault.jpg")
precondition(ArtworkPolicy.sizedURLString(
    for: "https://i.ytimg.com/vi/abcdefghijk/mqdefault.jpg", maxPixel: 500)
    == "https://i.ytimg.com/vi/abcdefghijk/mqdefault.jpg")
precondition(ArtworkPolicy.sizedURLString(
    for: "https://i.ytimg.com/vi/abcdefghijk/mqdefault.jpg", maxPixel: 100)
    == "https://i.ytimg.com/vi/abcdefghijk/default.jpg")
precondition(ArtworkPolicy.sizedURLString(
    for: "https://i.ytimg.com/hd/other.png", maxPixel: 100)
    == "https://i.ytimg.com/hd/other.png")                 // non-/vi path
precondition(ArtworkPolicy.sizedURLString(
    for: "https://i.ytimg.com/vi/abcdefghijk/unknown.jpg", maxPixel: 100)
    == "https://i.ytimg.com/vi/abcdefghijk/unknown.jpg")   // non-standard name

precondition(ArtworkPolicy.isResizable("https://i.ytimg.com/vi/x/hqdefault.jpg"))
precondition(!ArtworkPolicy.isResizable("https://lrclib.net/api/get?x=1"))

// Disk keys must be stable across processes: Swift's hashValue is seeded per
// launch, so FNV-1a is checked against vectors computed in Python.
precondition(StableHash.fnv1a64("") == 0xcbf2_9ce4_8422_2325)
precondition(StableHash.fnv1a64("a") == 0xaf63_dc4c_8601_ec8c)
precondition(StableHash.fnv1a64("foobar") == 0x8594_4171_f739_67e8)
precondition(StableHash.fnv1a64("48|https://i.ytimg.com/vi/abcdefghijk/mqdefault.jpg")
             == 0x0c79_dbb2_5dfa_4530)

// Eviction: expired entries always go, then oldest-modified until the budget
// fits. A: fresh, B: 31 days old (past a 30-day max age), C: 5 days old.
let refNow = Date(timeIntervalSince1970: 1_800_000_000)
let day: TimeInterval = 86_400
let entries = [
    DiskCacheEntry(name: "A", bytes: 100, modified: refNow),
    DiskCacheEntry(name: "B", bytes: 100, modified: refNow.addingTimeInterval(-31 * day)),
    DiskCacheEntry(name: "C", bytes: 100, modified: refNow.addingTimeInterval(-5 * day)),
]
precondition(CacheEviction.victims(entries: entries, budgetBytes: 150,
                                   maxAge: 30 * day, now: refNow) == ["B", "C"])
precondition(CacheEviction.victims(entries: entries, budgetBytes: 250,
                                   maxAge: 30 * day, now: refNow) == ["B"])
precondition(CacheEviction.victims(entries: entries, budgetBytes: 1_000,
                                   maxAge: 30 * day, now: refNow) == ["B"])
precondition(CacheEviction.victims(entries: entries, budgetBytes: 50,
                                   maxAge: 365 * day, now: refNow) == ["C", "B", "A"])

// Dedupe: a key already in flight must make the second caller skip its fetch.
var ledger = DedupeLedger()
precondition(ledger.begin("k"))
precondition(!ledger.begin("k"))
ledger.end("k")
precondition(ledger.begin("k"))
print("Artwork cache policy checks passed.")

// ---------------------------------------------------------------------------
// Queue ops: reorder/removal arithmetic and the advance decision table.
// ---------------------------------------------------------------------------

precondition(QueueOps.moved([1, 2, 3, 4, 5], fromOffsets: IndexSet([0]), toOffset: 3) == [2, 3, 1, 4, 5])
precondition(QueueOps.moved(["a", "b", "c"], fromOffsets: IndexSet([2]), toOffset: 0) == ["c", "a", "b"])
precondition(QueueOps.removed(["a", "b", "c", "d", "e"], at: IndexSet([1, 3])) == ["a", "c", "e"])
precondition(QueueOps.removalShift(before: 4, offsets: IndexSet([1, 3])) == 2)
precondition(QueueOps.removalShift(before: 2, offsets: IndexSet([1, 3])) == 1)
precondition(QueueOps.removalShift(before: 1, offsets: IndexSet([1, 3])) == 0)

// Sequential play.
precondition(QueueOps.advance(count: 5, current: 1, shuffle: false,
                              randomPick: 0, repeatAll: false, isRadio: false) == .load(2))
// End of a normal queue: repeat restarts, a radio extends, otherwise stop.
precondition(QueueOps.advance(count: 5, current: 4, shuffle: false,
                              randomPick: 0, repeatAll: true, isRadio: false) == .load(0))
precondition(QueueOps.advance(count: 5, current: 4, shuffle: false,
                              randomPick: 0, repeatAll: false, isRadio: true) == .extendRadio)
precondition(QueueOps.advance(count: 5, current: 4, shuffle: false,
                              randomPick: 0, repeatAll: false, isRadio: false) == .stop)
// Shuffle: the pick wins, but never the current track; on collision step once.
precondition(QueueOps.advance(count: 3, current: 1, shuffle: true,
                              randomPick: 0, repeatAll: false, isRadio: false) == .load(0))
precondition(QueueOps.advance(count: 3, current: 1, shuffle: true,
                              randomPick: 1, repeatAll: false, isRadio: false) == .load(2))
// Shuffle with a one-track queue degrades to repeat/stop, exactly like before.
precondition(QueueOps.advance(count: 1, current: 0, shuffle: true,
                              randomPick: 0, repeatAll: true, isRadio: false) == .load(0))
precondition(QueueOps.advance(count: 0, current: 0, shuffle: true,
                              randomPick: 0, repeatAll: true, isRadio: false) == .stop)
print("Queue ops checks passed.")
