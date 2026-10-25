import Foundation

struct AudioStream {
    let url: URL
    let userAgent: String?
    let mimeType: String?
    let durationSeconds: Double?
    let expiresAt: Date
    let videoTitle: String?
    let videoArtist: String?

    var headers: [String: String] {
        userAgent.map { ["User-Agent": $0] } ?? [:]
    }

    var contentTypeName: String {
        if let mimeType, mimeType.hasPrefix("audio/") { return "audio/mp4" }
        return "video/mp4"
    }
}

// Port of the direct-URL fast path in InnerTubeMusicApi.resolveDirectUrlFastPath:
// rotate player clients (the app orders VISIONOS, ANDROID_VR, TVHTML5), send one
// youtubei/player POST per client, take the first format with a *direct* URL
// (no ciphered signature — allowCipherFormats=false), cache 4 h, cool down
// failed clients 60 s per track.
enum StreamExtractor {
    struct PlayerClient {
        let name: String
        let version: String
        let apiKey: String
        let userAgent: String
        let osName: String?
        let osVersion: String?
        let deviceMake: String?
        let deviceModel: String?
        let androidSdkVersion: String?
    }

    // Keys/versions verbatim from the upstream PLAYER_CLIENTS table.
    // Order = preference. VISIONOS (visionOS 0.1, clientId 101) is first: it is
    // the only anonymous profile that still hands out direct media URLs this
    // network can actually fetch — every ANDROID_VR itag now answers 403 here
    // (player call OK, bytes refused), so VR moved behind it.
    // An empty apiKey means "use the key scraped from music.youtube.com".
    static let clients: [PlayerClient] = [
        PlayerClient(
            name: "VISIONOS",
            version: "0.1",
            apiKey: "",
            userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_6) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Safari/605.1.15",
            osName: "VISION_OS",
            osVersion: "1.3",
            deviceMake: "Apple",
            deviceModel: "RealityDevice14,1",
            androidSdkVersion: nil
        ),
        PlayerClient(
            name: "VISIONOS",
            version: "1.02",
            apiKey: "",
            userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 15_7_3) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15",
            osName: "visionOS",
            osVersion: "26.5.23O471",
            deviceMake: "Apple",
            deviceModel: "RealityDevice17,1",
            androidSdkVersion: nil
        ),
        PlayerClient(
            name: "ANDROID_VR",
            version: "1.65.10",
            apiKey: "AIzaSyD-p045F_WzU-vA_YgX20SCx4KAo",
            userAgent: "com.google.android.apps.youtube.vr.oculus/1.65.10 (Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip",
            osName: "Android",
            osVersion: "12",
            deviceMake: "Oculus",
            deviceModel: "Quest 3",
            androidSdkVersion: "32"
        ),
        PlayerClient(
            name: "ANDROID_TESTSUITE",
            version: "1.9",
            apiKey: "AIzaSyD-p045F_WzU-vA_YgX20SCx4KAo",
            userAgent: "com.google.android.youtube/1.9 (Linux; U; Android 12) gzip",
            osName: "Android",
            osVersion: "12",
            deviceMake: nil,
            deviceModel: nil,
            androidSdkVersion: nil
        ),
    ]

    // Identity = name + version: two VISIONOS profiles share a clientName, so
    // keying health/ban lists on the name alone would disable both at once.
    static func identity(_ client: PlayerClient) -> String { "\(client.name)/\(client.version)" }

    private struct CacheKey: Hashable { let videoId: String }
    private static var streamCache: [CacheKey: (stream: AudioStream, clientKey: String)] = [:]
    private static var failedClients: [String: Date] = [:]
    private static var lastSuccessfulClient: String?

    static let streamTTL: TimeInterval = 4 * 60 * 60
    static let clientCooldown: TimeInterval = 60

    // Clients whose player call succeeded but whose media URLs the CDN then
    // refused. A resolving player call is not proof the URLs are fetchable
    // (that is how ANDROID_VR behaves now), so ban the profile for the session
    // and let the retry fall through to the next one.
    private static var refusedClients: Set<String> = []

    static func markLastClientRefused() {
        guard let name = lastSuccessfulClient else { return }
        refusedClients.insert(name)
        lastSuccessfulClient = nil
        streamCache.removeAll()
        NSLog("LWSTREAM client %@ refused by the CDN; dropping it for this session", name)
    }

    static func resolve(videoId: String, forceRefresh: Bool = false) async throws -> AudioStream {
        let cacheKey = CacheKey(videoId: videoId)
        if !forceRefresh, let cached = streamCache[cacheKey], cached.stream.expiresAt > Date() {
            return cached.stream
        }
        if forceRefresh { streamCache[cacheKey] = nil }

        let config = await InnerTube.webConfig()
        // visitorData is mandatory for these clients; they answer with zero
        // formats without it, exactly like the Android comment describes.
        let visitorData = config.visitorData

        // Put the last successful client first, mirroring the upstream
        // `.sortedByDescending { it.name == lastSuccessfulClientName }`.
        var ordered = clients.filter { !refusedClients.contains(identity($0)) }
        if let last = lastSuccessfulClient {
            ordered.sort { a, b in
                (identity(a) == last ? 1 : 0) > (identity(b) == last ? 1 : 0)
            }
        }

        var errors: [String] = []
        for client in ordered {
            let failureKey = "\(videoId)|\(identity(client))"
            if let until = failedClients[failureKey], until > Date() { continue }
            do {
                let stream = try await requestStream(videoId: videoId, client: client, visitorData: visitorData)
                lastSuccessfulClient = identity(client)
                streamCache[cacheKey] = (stream, identity(client))
                return stream
            } catch {
                failedClients[failureKey] = Date().addingTimeInterval(clientCooldown)
                errors.append("\(identity(client)): \(error.localizedDescription)")
            }
        }

        // Last resort: WEB_REMIX player with the freshly scraped API key;
        // still only accept direct (unciphered) URLs.
        let webClient = PlayerClient(
            name: "WEB_REMIX",
            version: config.clientVersion,
            apiKey: config.apiKey,
            userAgent: InnerTube.webUserAgent,
            osName: nil, osVersion: nil, deviceMake: nil, deviceModel: nil, androidSdkVersion: nil
        )
        if let stream = try? await requestStream(videoId: videoId, client: webClient, visitorData: visitorData) {
            lastSuccessfulClient = identity(webClient)
            streamCache[cacheKey] = (stream, identity(webClient))
            return stream
        }

        throw InnerTubeError.noStream
    }

    private static func requestStream(
        videoId: String,
        client: PlayerClient,
        visitorData: String?
    ) async throws -> AudioStream {
        var clientDict: [String: Any] = [
            "clientName": client.name,
            "clientVersion": client.version,
            "hl": "en",
            "gl": "US",
        ]
        if let visitorData { clientDict["visitorData"] = visitorData }
        if let osName = client.osName { clientDict["osName"] = osName }
        if let osVersion = client.osVersion { clientDict["osVersion"] = osVersion }
        if let deviceMake = client.deviceMake { clientDict["deviceMake"] = deviceMake }
        if let deviceModel = client.deviceModel { clientDict["deviceModel"] = deviceModel }
        if let sdk = client.androidSdkVersion { clientDict["androidSdkVersion"] = Int(sdk) }

        let body: [String: Any] = [
            "context": ["client": clientDict],
            "videoId": videoId,
            "contentCheckOk": true,
            "racyCheckOk": true,
        ]
        let root = try await InnerTube.postJSON(
            url: "https://www.youtube.com/youtubei/v1/player?key=\(client.apiKey.isEmpty ? await InnerTube.webConfig().apiKey : client.apiKey)&prettyPrint=false",
            body: body,
            headers: [
                "User-Agent": client.userAgent,
                "Content-Type": "application/json",
                "X-YouTube-Client-Name": client.name,
                "X-YouTube-Client-Version": client.version,
            ]
        )

        guard let object = root as? [String: Any] else { throw InnerTubeError.noStream }
        if let playability = object["playabilityStatus"] as? [String: Any],
           let status = playability["status"] as? String,
           status != "OK" {
            throw InnerTubeError.httpStatus(-1)
        }
        guard let streaming = object["streamingData"] as? [String: Any] else {
            throw InnerTubeError.noStream
        }
        var formats: [[String: Any]] = []
        if let adaptive = streaming["adaptiveFormats"] as? [[String: Any]] { formats += adaptive }
        if let regular = streaming["formats"] as? [[String: Any]] { formats += regular }

        var durationSeconds: Double?
        if let mf = object["microformat"] as? [String: Any],
           let pmf = mf["playerMicroformatRenderer"] as? [String: Any],
           let seconds = pmf["lengthSeconds"] as? String {
            durationSeconds = Double(seconds)
        }
        if durationSeconds == nil,
           let details = object["videoDetails"] as? [String: Any],
           let seconds = details["lengthSeconds"] as? String {
            durationSeconds = Double(seconds)
        }

        let details = object["videoDetails"] as? [String: Any]
        let videoTitle = details?["title"] as? String
        let videoArtist = (details?["shortBylineText"] as? [String: Any])
            .flatMap { (($0["runs"] as? [[String: Any]])?.first?["text"] as? String) ?? ($0["simpleText"] as? String) }
            ?? (details?["author"] as? String)

        // iOS plays AAC/MP4 progressive audio natively; HLS is the fallback.
        // (Android prefers Opus/WebM; AVPlayer cannot decode WebM, so the
        // ranking differs by platform while the selection shape is identical.)
        // Progressive formats (regular list) are plain MP4 that AVPlayer
        // handles natively; ANDROID_VR exposes itag 18 unciphered.
        var progressive = ((streaming["formats"] as? [[String: Any]]) ?? [])
            .filter { $0["url"] != nil && (($0["mimeType"] as? String) ?? "").hasPrefix("video/mp4") }
        progressive.sort { (($0["bitrate"] as? Int) ?? 0) > (($1["bitrate"] as? Int) ?? 0) }
        if let format = progressive.first,
           let url = (format["url"] as? String).flatMap(URL.init(string:)) {
            return AudioStream(
                url: url,
                userAgent: client.userAgent,
                mimeType: format["mimeType"] as? String,
                durationSeconds: durationSeconds,
                expiresAt: Date().addingTimeInterval(300),
                videoTitle: videoTitle,
                videoArtist: videoArtist
            )
        }

        var bestAudio: (bitrate: Int, format: [String: Any])?
        var bestHLS: (bitrate: Int, url: String)?
        var bestCombined: (bitrate: Int, format: [String: Any])?
        for format in formats {
            guard let urlString = format["url"] as? String,
                  let mime = format["mimeType"] as? String else { continue }
            // "audio/mp4; codecs=\"mp4a.40.2\"" vs combined "video/mp4; …"
            let base = String(mime.split(separator: ";").first ?? Substring(mime))
            let bitrate = (format["bitrate"] as? Int) ?? 0
            if base.hasPrefix("audio/mp4") {
                if bestAudio == nil || bitrate > bestAudio!.bitrate {
                    bestAudio = (bitrate, format)
                }
            } else if base.hasPrefix("application/x-mpegurl") ||
                      (base.hasPrefix("audio/") && urlString.contains("/manifest/unit=")) {
                if bestHLS == nil || bitrate > bestHLS!.bitrate {
                    bestHLS = (bitrate, urlString)
                }
            } else if base.hasPrefix("video/") || base.hasPrefix("audio/") {
                if bestCombined == nil || bitrate > bestCombined!.bitrate {
                    bestCombined = (bitrate, format)
                }
            }
        }

        for candidate in [bestAudio] {
            if let (_, format) = candidate, let url = (format["url"] as? String).flatMap(URL.init(string:)) {
                let expiry = (format["expiries"] as? [Double])?.first
                    ?? (format["expireDates"] as? [Double])?.first
                return AudioStream(
                    url: url,
                    userAgent: client.userAgent,
                    mimeType: format["mimeType"] as? String,
                    durationSeconds: durationSeconds,
                    expiresAt: expiry.map { Date(timeIntervalSince1970: $0) }
                        ?? Date().addingTimeInterval(300),
                    videoTitle: videoTitle,
                    videoArtist: videoArtist
                )
            }
        }
        if let hlsURL = bestHLS?.url, let url = URL(string: hlsURL) {
            return AudioStream(
                url: url,
                userAgent: client.userAgent,
                mimeType: "application/x-mpegURL",
                durationSeconds: durationSeconds,
                expiresAt: Date().addingTimeInterval(300),
                videoTitle: videoTitle,
                videoArtist: videoArtist
            )
        }
        if let (_, format) = bestCombined, let url = (format["url"] as? String).flatMap(URL.init(string:)) {
            return AudioStream(
                url: url,
                userAgent: client.userAgent,
                mimeType: format["mimeType"] as? String,
                durationSeconds: durationSeconds,
                expiresAt: Date().addingTimeInterval(300),
                videoTitle: videoTitle,
                videoArtist: videoArtist
            )
        }
        throw InnerTubeError.noStream
    }
}
