import Foundation

// Model mirroring Android's YouTubeMusicTrack.
struct MusicTrack: Identifiable, Hashable, Codable {
    let videoId: String
    let title: String
    let artist: String
    let album: String?
    let artwork: String?
    let durationSeconds: Int?

    var id: String { videoId }
}

// Port of InnerTubeMusicApi's client config + search/browse surface.
public enum InnerTube {
    static let musicAPI = "https://music.youtube.com/youtubei/v1"
    static let fallbackWebKey = "AIzaSyAO_FJ2SlqU8Q4STEHLGCilw_Y9_11qcW8"
    static let webClientVersion = "1.20260707.12.00"
    static let webUserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:140.0) Gecko/20100101 Firefox/140.0"
    static let songSearchParams = "EgWKAQIIAWoKEAkQBRAKEAMQBA=="

    struct WebConfig {
        let apiKey: String
        let clientVersion: String
        let visitorData: String?
    }

    private static var cachedConfig: WebConfig?
    private static var bootstrapDate: Date?
    private static var ongoingBootstrapTask: Task<WebConfig, Never>?

    private static let userDefaultsKeyApiKey = "yt.innertube.apiKey"
    private static let userDefaultsKeyClientVersion = "yt.innertube.clientVersion"
    private static let userDefaultsKeyVisitorData = "yt.innertube.visitorData"
    private static let userDefaultsKeyBootstrapDate = "yt.innertube.bootstrapDate"

    static let scrapeUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

    private static func loadPersistedConfig() -> (WebConfig, Date)? {
        let defaults = UserDefaults.standard
        guard let key = defaults.string(forKey: userDefaultsKeyApiKey),
              let version = defaults.string(forKey: userDefaultsKeyClientVersion),
              let date = defaults.object(forKey: userDefaultsKeyBootstrapDate) as? Date else {
            return nil
        }
        let visitor = defaults.string(forKey: userDefaultsKeyVisitorData)
        return (WebConfig(apiKey: key, clientVersion: version, visitorData: visitor), date)
    }

    private static func savePersistedConfig(_ config: WebConfig, date: Date) {
        let defaults = UserDefaults.standard
        defaults.set(config.apiKey, forKey: userDefaultsKeyApiKey)
        defaults.set(config.clientVersion, forKey: userDefaultsKeyClientVersion)
        defaults.set(config.visitorData, forKey: userDefaultsKeyVisitorData)
        defaults.set(date, forKey: userDefaultsKeyBootstrapDate)
    }

    // Bootstraps apiKey + visitorData from music.youtube.com's page source,
    // cached in memory and persisted in UserDefaults across launches.
    static func webConfig() async -> WebConfig {
        // 1. In-memory cache (< 4 hours)
        if let cached = cachedConfig,
           let bootstrapDate,
           Date().timeIntervalSince(bootstrapDate) < 4 * 3600,
           cached.visitorData != nil {
            return cached
        }

        // 2. Persisted cache from previous launches (< 24 hours)
        if cachedConfig == nil, let (persisted, date) = loadPersistedConfig() {
            cachedConfig = persisted
            bootstrapDate = date
            if Date().timeIntervalSince(date) < 24 * 3600, persisted.visitorData != nil {
                // If nearing 4 hours, refresh in background without blocking caller
                if Date().timeIntervalSince(date) >= 4 * 3600 {
                    Task.detached { _ = await refreshWebConfig() }
                }
                return persisted
            }
        }

        // 3. Deduplicate concurrent requests so only one bootstrap scrape runs
        if let ongoing = ongoingBootstrapTask {
            return await ongoing.value
        }

        let task = Task<WebConfig, Never> {
            await refreshWebConfig()
        }
        ongoingBootstrapTask = task
        let result = await task.value
        ongoingBootstrapTask = nil
        return result
    }

    @discardableResult
    private static func refreshWebConfig() async -> WebConfig {
        var config = WebConfig(
            apiKey: cachedConfig?.apiKey ?? String(fallbackWebKey),
            clientVersion: cachedConfig?.clientVersion ?? webClientVersion,
            visitorData: cachedConfig?.visitorData
        )
        if let html = try? await fetchText(
            URL(string: "https://music.youtube.com")!,
            headers: [
                "User-Agent": scrapeUserAgent,
                // SOCS=CAI skips the EU consent interstitial, which otherwise
                // serves a page with no visitorData at all.
                "Cookie": "SOCS=CAI",
            ],
            timeout: 6
        ) {
            let key = firstMatch(in: html, pattern: "\"INNERTUBE_API_KEY\":\"([^\"]+)\"") ?? config.apiKey
            let version = firstMatch(in: html, pattern: "\"INNERTUBE_CLIENT_VERSION\":\"([^\"]+)\"") ?? config.clientVersion
            let visitor = firstMatch(in: html, pattern: "\"visitorData\":\"([^\"]+)\"")
                ?? firstMatch(in: html, pattern: "\\\"visitorData\\\":\\\"([^\\\"]+)\\\"")
                ?? firstMatch(in: html, pattern: "\"visitor\":\"([^\"]+)\"")
                ?? firstMatch(in: html, pattern: "visitorData=([^\"&]+)")
            config = WebConfig(apiKey: key, clientVersion: version, visitorData: visitor)
        }
        let now = Date()
        cachedConfig = config
        bootstrapDate = now
        savePersistedConfig(config, date: now)
        return config
    }

    static func context(_ name: String, _ version: String, visitorData: String?) -> [String: Any] {
        var client: [String: Any] = [
            "clientName": name,
            "clientVersion": version,
            "hl": "en",
            "gl": "US",
        ]
        if let visitorData, !visitorData.isEmpty {
            client["visitorData"] = visitorData
        }
        return ["client": client]
    }

    static func searchSongs(query: String, limit: Int = 30) async throws -> [MusicTrack] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let config = await webConfig()

        func runSearch(params: String?) async throws -> [MusicTrack] {
            var body: [String: Any] = [
                "context": context("WEB_REMIX", config.clientVersion, visitorData: config.visitorData),
                "query": trimmed,
            ]
            if let params { body["params"] = params }
            let root = try await postJSON(
                url: "\(musicAPI)/search?key=\(config.apiKey)&prettyPrint=false",
                body: body,
                headers: [
                    "User-Agent": webUserAgent,
                    "Content-Type": "application/json",
                    "X-YouTube-Client-Name": "WEB_REMIX",
                    "X-YouTube-Client-Version": config.clientVersion,
                ]
            )
            return parseSongRenderers(root)
        }

        let filtered = (try? await runSearch(params: songSearchParams)) ?? []
        if !filtered.isEmpty { return Array(filtered.prefix(limit)) }
        let unfiltered = (try? await runSearch(params: nil)) ?? []
        if !unfiltered.isEmpty { return Array(unfiltered.prefix(limit)) }
        // Region-block fallback: plain YouTube WEB client, as in the Android app.
        var body: [String: Any] = [
            "context": context("WEB", "2.20261011.05.00", visitorData: nil),
            "query": trimmed,
        ]
        body["params"] = "EgIQAQ=="
        let root = try await postJSON(
            url: "https://www.youtube.com/youtubei/v1/search?key=\(config.apiKey)&prettyPrint=false",
            body: body,
            headers: ["User-Agent": webUserAgent, "Content-Type": "application/json"]
        )
        return Array(parseSongRenderers(root).prefix(limit))
    }

    static func browseHome(limit: Int = 24) async throws -> [MusicTrack] {
        let config = await webConfig()
        let body: [String: Any] = [
            "context": context("WEB_REMIX", config.clientVersion, visitorData: config.visitorData),
            "browseId": "FEmusic_home",
        ]
        let root = try await postJSON(
            url: "\(musicAPI)/browse?key=\(config.apiKey)&prettyPrint=false",
            body: body,
            headers: [
                "User-Agent": webUserAgent,
                "Content-Type": "application/json",
                "X-YouTube-Client-Name": "WEB_REMIX",
                "X-YouTube-Client-Version": config.clientVersion,
            ]
        )
        let songs = parseSongRenderers(root)
        return Array(songs.prefix(limit))
    }

    // MARK: - Parsing (port of parseSongRenderers / parseSong)

    static func parseSongRenderers(_ root: Any) -> [MusicTrack] {
        var songs: [MusicTrack] = []
        for renderer in collectObjects(root, key: "musicResponsiveListItemRenderer") {
            if let song = parseSong(renderer) { songs.append(song) }
        }
        if songs.isEmpty {
            for renderer in collectObjects(root, key: "playlistVideoRenderer") {
                if let song = parseGenericVideo(renderer) { songs.append(song) }
            }
        }
        if songs.isEmpty {
            for renderer in collectObjects(root, key: "videoRenderer") {
                if let song = parseGenericVideo(renderer) { songs.append(song) }
            }
        }
        var seen = Set<String>()
        return songs.filter { seen.insert($0.videoId).inserted }
    }

    private static func parseSong(_ renderer: [String: Any]) -> MusicTrack? {
        let videoId = directWatchVideoId(renderer)
            ?? findString(in: renderer, key: "videoId")
        guard let videoId, !videoId.isEmpty else { return nil }

        let columns = renderer["flexColumns"] as? [Any] ?? []
        func columnText(_ index: Int) -> String? {
            guard let column = columns[safe: index] as? [String: Any],
                  let flex = column["musicResponsiveListItemFlexColumnRenderer"] as? [String: Any],
                  let text = flex["text"] as? [String: Any] else { return nil }
            if let runs = text["runs"] as? [[String: Any]] {
                let joined = runs.compactMap { $0["text"] as? String }.joined()
                if !joined.isEmpty { return joined }
            }
            return text["simpleText"] as? String
        }
        guard let title = columnText(0)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty else { return nil }

        var detailRuns: [[String: Any]] = []
        for index in 1..<columns.count {
            if let column = columns[safe: index] as? [String: Any],
               let flex = column["musicResponsiveListItemFlexColumnRenderer"] as? [String: Any],
               let text = flex["text"] as? [String: Any],
               let runs = text["runs"] as? [[String: Any]] {
                detailRuns.append(contentsOf: runs)
            }
        }
        if let fixed = renderer["fixedColumns"] as? [[String: Any]] {
            for column in fixed {
                if let fc = column["musicResponsiveListItemFixedColumnRenderer"] as? [String: Any],
                   let text = fc["text"] as? [String: Any],
                   let runs = text["runs"] as? [[String: Any]] {
                    detailRuns.append(contentsOf: runs)
                }
            }
        }

        func browseID(_ run: [String: Any]) -> String? {
            let endpoint = run["navigationEndpoint"] as? [String: Any]
            let browse = endpoint?["browseEndpoint"] as? [String: Any]
            return browse?["browseId"] as? String
        }
        let artist = detailRuns.first { (browseID($0)?.hasPrefix("UC")) ?? false }
            .flatMap { $0["text"] as? String }
            ?? detailRuns.compactMap { $0["text"] as? String }.first(where: looksLikeArtist)
            ?? "Unknown artist"

        let album = detailRuns.first { (browseID($0)?.hasPrefix("MPRE")) ?? false }
            .flatMap { $0["text"] as? String }

        let texts = detailRuns.compactMap { $0["text"] as? String }
        let duration = texts.firstNotNull { parseDuration($0) }

        let artwork = extractThumbnailsURL(renderer)
        return MusicTrack(
            videoId: videoId,
            title: title,
            artist: artist,
            album: album,
            artwork: artwork,
            durationSeconds: duration
        )
    }

    private static func parseGenericVideo(_ renderer: [String: Any]) -> MusicTrack? {
        guard let videoId = renderer["videoId"] as? String, !videoId.isEmpty else { return nil }
        let title = textOf(renderer["title"]) ?? "Unknown title"
        let artist = (renderer["ownerText"] as? [String: Any])
            .flatMap { ($0["runs"] as? [[String: Any]])?.first?["text"] as? String }
            ?? (renderer["shortBylineText"] as? [String: Any])
                .flatMap { ($0["runs"] as? [[String: Any]])?.first?["text"] as? String }
            ?? "Unknown artist"
        let duration = (renderer["lengthText"] as? [String: Any])
            .flatMap { $0["simpleText"] as? String }
            .flatMap(parseDuration)
        return MusicTrack(
            videoId: videoId,
            title: title,
            artist: artist,
            album: nil,
            artwork: extractThumbnailsURL(renderer),
            durationSeconds: duration
        )
    }

    static func textOf(_ value: Any?) -> String? {
        guard let object = value as? [String: Any] else { return nil }
        if let runs = object["runs"] as? [[String: Any]] {
            let joined = runs.compactMap { $0["text"] as? String }.joined()
            return joined.isEmpty ? nil : joined
        }
        return object["simpleText"] as? String
    }

    private static func directWatchVideoId(_ renderer: [String: Any]) -> String? {
        if let overlay = findObject(renderer, key: "musicItemThumbnailOverlayRenderer"),
           let button = overlay["content"] as? [String: Any],
           let play = button["musicPlayButtonRenderer"] as? [String: Any],
           let watch = (play["playNavigationEndpoint"] as? [String: Any])?["watchEndpoint"] as? [String: Any],
           let id = watch["videoId"] as? String {
            return id
        }
        if let endpoint = renderer["onTap"] as? [String: Any],
           let watch = endpoint["watchEndpoint"] as? [String: Any],
           let id = watch["videoId"] as? String {
            return id
        }
        return nil
    }

    private static func looksLikeArtist(_ text: String) -> Bool {
        if text.contains("•") { return false }
        if parseDuration(text) != nil { return false }
        let lower = text.lowercased()
        if lower.contains("play") || lower.contains("view") { return false }
        return text.count > 1 && text.count < 120
    }

    public static func parseDuration(_ raw: String) -> Int? {
        let parts = raw.split(separator: ":").map(String.init)
        guard !parts.isEmpty, parts.count <= 3 else { return nil }
        guard parts.allSatisfy({ Int($0) != nil }) else { return nil }
        let numbers = parts.compactMap { Int($0) }
        if numbers.count == 2 { return numbers[0] * 60 + numbers[1] }
        if numbers.count == 3 { return numbers[0] * 3600 + numbers[1] * 60 + numbers[2] }
        return nil
    }

    static func extractThumbnailsURL(_ element: Any) -> String? {
        // The "thumbnails" value is an array, not an object, so walk the
        // singular "thumbnail" renderers instead and index into the array.
        for group in collectObjects(element, key: "thumbnail") {
            let candidates = group["thumbnails"] as? [[String: Any]] ?? []
            // Parenthesized: a trailing closure inside an `if let` condition
            // reads as the condition's body (Swift 6.2 warns, Xcode 27 flags it).
            if let url = candidates.compactMap({ $0["url"] as? String }).last {
                return highResolutionArtwork(url, size: 300, quality: 80)
            }
        }
        return nil
    }

    public static func highResolutionArtwork(_ raw: String, size: Int = 512, quality: Int = 90) -> String {
        var url = raw
        if url.hasPrefix("//") { url = "https:" + url }
        if (url.contains("googleusercontent.com") || url.contains("ggpht.com")) && url.contains("=") {
            url = String(url.prefix(upTo: url.lastIndex(of: "=")!)) + "=w\(size)-h\(size)-l\(quality)-rj"
        }
        return url
    }

    // MARK: - Generic JSON walking (port of collectObjects/findString)

    public static func collectObjects(_ element: Any, key: String) -> [[String: Any]] {
        var output: [[String: Any]] = []
        collectObjectsHelper(element, key: key, into: &output)
        return output
    }

    private static func collectObjectsHelper(_ element: Any, key: String, into output: inout [[String: Any]]) {
        switch element {
        case let object as [String: Any]:
            for (name, child) in object {
                if name == key, let dict = child as? [String: Any] {
                    output.append(dict)
                }
                collectObjectsHelper(child, key: key, into: &output)
            }
        case let array as [Any]:
            for child in array {
                collectObjectsHelper(child, key: key, into: &output)
            }
        default:
            break
        }
    }

    private static func findObject(_ element: Any, key: String) -> [String: Any]? {
        collectObjects(element, key: key).first
    }

    public static func findString(in element: Any, key: String) -> String? {
        switch element {
        case let object as [String: Any]:
            if let value = object[key] as? String { return value }
            for child in object.values {
                if let found = findString(in: child, key: key) { return found }
            }
        case let array as [Any]:
            for child in array {
                if let found = findString(in: child, key: key) { return found }
            }
        default:
            break
        }
        return nil
    }

    // MARK: - Networking

    static func postJSON(url: String, body: [String: Any], headers: [String: String]) async throws -> Any {
        guard let requestURL = URL(string: url) else { throw InnerTubeError.invalidURL }
        var request = URLRequest(url: requestURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw InnerTubeError.httpStatus(((response as? HTTPURLResponse)?.statusCode) ?? -1)
        }
        return try JSONSerialization.jsonObject(with: data)
    }

    static func fetchText(_ url: URL, headers: [String: String], timeout: TimeInterval = 20) async throws -> String {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let (data, _) = try await URLSession.shared.data(for: request)
        return String(decoding: data, as: UTF8.self)
    }

    private static func firstMatch(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let group = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[group])
    }
}

enum InnerTubeError: LocalizedError {
    case invalidURL
    case httpStatus(Int)
    case noStream

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid InnerTube request URL."
        case .httpStatus(let code): return "YouTube returned HTTP \(code)."
        case .noStream: return "No playable audio stream was found for this track."
        }
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

extension Sequence {
    func firstNotNull<T>(_ transform: (Element) -> T?) -> T? {
        for element in self {
            if let value = transform(element) { return value }
        }
        return nil
    }
}
