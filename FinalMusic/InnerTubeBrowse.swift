import Foundation

// Port of InnerTubeMusicApi's browse/search/radio surface.
//
// Everything here talks to the anonymous WEB_REMIX client with the API key and
// visitorData scraped from music.youtube.com (see InnerTube.webConfig()).
// Endpoint recipes taken verbatim from the Android app:
//   * shelves           browse  FEmusic_home | FEmusic_charts | FEmusic_new_releases
//   * search            search  + filter params (songs/albums/artists/videos/community)
//   * album/artist/pl.  browse  MPREb… | UC… | VL…
//   * remix / radio     next    playlistId = RDAMVM<videoId>, params wAEB, isAudioOnly

// MARK: - Models

/// Anything the home feed can show: a playable song or a collection to open.
enum HomeItem: Identifiable, Codable {
    case track(MusicTrack)
    case collection(SearchEntity)

    var id: String {
        switch self {
        case .track(let track): return "t:" + track.videoId
        case .collection(let entity): return "c:" + entity.browseId
        }
    }

    enum CodingKeys: String, CodingKey {
        case itemType, track, collection
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .itemType)
        if type == "track" {
            self = .track(try container.decode(MusicTrack.self, forKey: .track))
        } else {
            self = .collection(try container.decode(SearchEntity.self, forKey: .collection))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .track(let t):
            try container.encode("track", forKey: .itemType)
            try container.encode(t, forKey: .track)
        case .collection(let c):
            try container.encode("collection", forKey: .itemType)
            try container.encode(c, forKey: .collection)
        }
    }
}

struct HomeShelf: Identifiable, Codable {
    let title: String
    let items: [HomeItem]
    var id: String { title + "|" + (items.first?.id ?? "") }

    var hasPlayableTracks: Bool {
        items.contains { item in
            if case .track = item { return true } else { return false }
        }
    }
}

enum EntityKind: String, CaseIterable, Identifiable, Codable {
    case song = "Songs"
    case album = "Albums"
    case artist = "Artists"
    case video = "Videos"
    case playlist = "Playlists"

    var id: String { rawValue }

    /// Parse a launch-argument value ("album", "Artists", …).
    static func parse(_ name: String?) -> EntityKind? {
        guard let name, !name.isEmpty else { return nil }
        return EntityKind.allCases.first { $0.rawValue.lowercased() == name.lowercased() }
            ?? EntityKind.allCases.first { $0.rawValue.lowercased().hasPrefix(name.lowercased()) }
    }

    /// WEB_REMIX search filter param; empty = no filter (mixed results).
    var filterParam: String {
        switch self {
        case .song: return "EgWKAQIIAWoKEAkQBRAKEAMQBA=="
        case .album: return "EgWKAQIYAWoKEAkQBRAKEAMQBA=="
        case .artist: return "EgWKAQIgAWoKEAkQBRAKEAMQBA=="
        case .video: return "EgWKAQIQAVoKEAkQBRAKEAMQBA=="
        case .playlist: return "EgWKAQIoAWoKEAkQBRAKEAMQBA=="
        }
    }
}

struct SearchEntity: Identifiable, Codable {
    let browseId: String
    let kind: EntityKind
    let title: String
    let subtitle: String
    let artwork: String?
    var id: String { browseId }
}

enum HomeFeedCache {
    private static let keyPrefix = "lastwave.homefeed.cache."
    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()

    static func load(browseId: String) -> [HomeShelf] {
        guard let data = UserDefaults.standard.data(forKey: keyPrefix + browseId),
              let shelves = try? decoder.decode([HomeShelf].self, from: data) else {
            return []
        }
        return shelves
    }

    static func save(_ shelves: [HomeShelf], browseId: String) {
        guard !shelves.isEmpty, let data = try? encoder.encode(shelves) else { return }
        UserDefaults.standard.set(data, forKey: keyPrefix + browseId)
    }
}

struct CollectionDetail {
    let browseId: String
    let kind: EntityKind
    let title: String
    let subtitle: String
    let artwork: String?
    let radioPlaylistId: String?
    let shelves: [HomeShelf]

    var allTracks: [MusicTrack] {
        shelves.flatMap { shelf in
            shelf.items.compactMap { if case .track(let t) = $0 { return t } else { return nil } }
        }
    }
}

/// Result of /next with playlistId = RDAMVM<videoId> — YouTube Music's own radio.
struct RadioQueue {
    let tracks: [MusicTrack]
    let continuation: String?
    let automixPlaylistId: String?
}

// MARK: - Requests

extension InnerTube {
    static let remixParams = "wAEB"

    static func webHeaders(_ version: String) -> [String: String] {
        [
            "User-Agent": webUserAgent,
            "Content-Type": "application/json",
            "X-YouTube-Client-Name": "WEB_REMIX",
            "X-YouTube-Client-Version": version,
        ]
    }

    static func webContext(_ visitorData: String?) -> [String: Any] {
        context("WEB_REMIX", webClientVersion, visitorData: visitorData)
    }

    static func postMusic(_ path: String, body: [String: Any]) async throws -> Any {
        let config = await webConfig()
        return try await postJSON(
            url: "\(musicAPI)/\(path)?key=\(config.apiKey)&prettyPrint=false",
            body: body,
            headers: webHeaders(config.clientVersion)
        )
    }

    private static func browseBody(_ browseId: String, visitor: String?) -> [String: Any] {
        ["context": webContext(visitor), "browseId": browseId]
    }

    // MARK: Browse

    /// Home / charts / new releases → shelves of songs and collections.
    static func browseShelves(_ browseId: String, formData: [String: Any]? = nil) async throws -> [HomeShelf] {
        let config = await webConfig()
        var body = browseBody(browseId, visitor: config.visitorData)
        if let formData { body["formData"] = formData }
        let root = try await postMusic("browse", body: body)
        return parseShelves(root)
    }

    /// Album (MPREb…), artist (UC…) or playlist (VL…) detail.
    static func browseCollection(_ browseId: String) async throws -> CollectionDetail {
        let config = await webConfig()
        let root = try await postMusic("browse", body: browseBody(browseId, visitor: config.visitorData))
        let header = parseHeader(root)
        let shelves = parseShelves(root)
        let trackShelfIndices = shelves.indices.filter { index in
            shelves[index].items.contains { item in
                if case .track = item { return true } else { return false }
            }
        }
        var kept: [HomeShelf]
        // The page id is the reliable kind signal — chart playlists send an
        // empty subtitle, so the header alone would call them albums.
        var kind = header.kind
        if browseId.hasPrefix("VL") || browseId.hasPrefix("PL") || browseId.hasPrefix("RD") {
            kind = .playlist
        } else if browseId.hasPrefix("MPRE") {
            kind = .album
        } else if browseId.hasPrefix("UC") {
            kind = .artist
        }
        if kind == .artist {
            // "Top songs" first, then the album/single/video carousels.
            let trackShelves = trackShelfIndices.map { shelves[$0] }
            let collections = shelves.indices
                .filter { !trackShelfIndices.contains($0) }
                .map { shelves[$0] }
            kept = Array(trackShelves.prefix(1)) + collections
        } else if let first = trackShelfIndices.first {
            // Album/playlist: only its own track list, no "you might also like".
            kept = [shelves[first]]
        } else {
            kept = shelves
        }
        var radio = findString(in: root, key: "playlistId") as String?
        if let candidate = radio, !candidate.hasPrefix("RD") { radio = nil }
        if kind == .album || kind == .playlist, let cover = header.artwork {
            // Album/playlist rows carry no per-track thumbnail (the header
            // holds the art), which rendered as grey squares. Backfill every
            // trackless row with the page cover — every track here IS on it.
            kept = kept.map { shelf in
                HomeShelf(title: shelf.title, items: shelf.items.map { item in
                    if case .track(let t) = item, t.artwork == nil || t.artwork?.isEmpty == true {
                        return .track(MusicTrack(videoId: t.videoId, title: t.title, artist: t.artist,
                                                 album: t.album, artwork: cover, durationSeconds: t.durationSeconds))
                    }
                    return item
                })
            }
        }
        NSLog("LWCOLL %@ kind=%@ title=%@ shelves=%d tracks=%d [%@]", browseId, kind.rawValue,
              header.title, kept.count, kept.reduce(0) { $0 + $1.items.count },
              kept.map { "\($0.title):\($0.items.count)" }.joined(separator: ","))
        return CollectionDetail(
            browseId: browseId,
            kind: kind,
            title: header.title,
            subtitle: header.subtitle,
            artwork: header.artwork ?? kept.first?.items.first.flatMap { item -> String? in
                if case .track(let t) = item { return t.artwork } else { return nil }
            },
            radioPlaylistId: radio,
            shelves: kept
        )
    }

    // MARK: Search

    static func searchEntities(query: String, kind: EntityKind, limit: Int = 30) async throws -> [SearchEntity] {
        let config = await webConfig()
        var body: [String: Any] = ["context": webContext(config.visitorData), "query": query]
        body["params"] = kind.filterParam
        let root = try await postMusic("search", body: body)
        return parseEntities(root, kind: kind).prefix(limit).map { $0 }
    }

    /// Songs only — searchSongs above keeps the Android behaviour of falling
    /// back to unfiltered results; this is the strict filtered variant.
    static func searchTracksFiltered(query: String, kind: EntityKind, limit: Int = 30) async throws -> [MusicTrack] {
        let config = await webConfig()
        var body: [String: Any] = ["context": webContext(config.visitorData), "query": query]
        body["params"] = kind.filterParam
        let root = try await postMusic("search", body: body)
        return Array(parseSongRenderers(root).prefix(limit))
    }

    // MARK: Remix / radio (/next)

    static func radio(videoId: String) async throws -> RadioQueue {
        let config = await webConfig()
        let body: [String: Any] = [
            "context": webContext(config.visitorData),
            "videoId": videoId,
            "playlistId": "RDAMVM\(videoId)",
            "params": remixParams,
            "isAudioOnly": true,
        ]
        return parseRadio(try await postMusic("next", body: body))
    }

    static func radioContinuation(_ token: String) async throws -> RadioQueue {
        let config = await webConfig()
        let body: [String: Any] = ["context": webContext(config.visitorData), "continuation": token]
        return parseRadio(try await postMusic("next", body: body))
    }

    static func radioByPlaylistId(_ playlistId: String) async throws -> RadioQueue {
        let config = await webConfig()
        let body: [String: Any] = [
            "context": webContext(config.visitorData),
            "playlistId": playlistId,
            "params": remixParams,
            "isAudioOnly": true,
        ]
        return parseRadio(try await postMusic("next", body: body))
    }

    // MARK: - Parsing

    static func parseRadio(_ root: Any) -> RadioQueue {
        var tracks: [MusicTrack] = []
        var seen = Set<String>()

        func add(_ track: MusicTrack?) {
            guard let track, !track.videoId.isEmpty, seen.insert(track.videoId).inserted else { return }
            tracks.append(track)
        }

        var panels = collectObjects(root, key: "playlistPanelRenderer")
        if let continuation = collectObjects(root, key: "playlistPanelContinuation").first {
            panels.append(continuation)
        }
        for panel in panels {
            for item in panel["contents"] as? [[String: Any]] ?? [] {
                add(parsePanelItem(item))
            }
        }
        if tracks.isEmpty {
            for renderer in collectObjects(root, key: "playlistPanelVideoRenderer") {
                add(parsePanelSong(renderer))
            }
        }

        var continuation: String?
        for key in ["nextRadioContinuationData", "nextContinuationData"] {
            if let value = collectObjects(root, key: key).first?["continuation"] as? String, !value.isEmpty {
                continuation = value
                break
            }
        }
        if continuation == nil,
           let token = collectObjects(root, key: "continuationCommand").first?["token"] as? String,
           !token.isEmpty {
            continuation = token
        }

        var automix: String?
        for renderer in collectObjects(root, key: "automixPreviewVideoRenderer") {
            let content = renderer["content"] as? [String: Any]
            let endpoint = (content?["automixPlaylistVideoRenderer"] as? [String: Any])?["navigationEndpoint"] as? [String: Any]
            if let id = (endpoint?["watchPlaylistEndpoint"] as? [String: Any])?["playlistId"] as? String, !id.isEmpty {
                automix = id
                break
            }
        }

        return RadioQueue(tracks: tracks, continuation: continuation, automixPlaylistId: automix)
    }

    private static func parsePanelItem(_ element: [String: Any]) -> MusicTrack? {
        if let renderer = element["playlistPanelVideoRenderer"] as? [String: Any] {
            return parsePanelSong(renderer)
        }
        if let wrapper = element["playlistPanelVideoWrapperRenderer"] as? [String: Any],
           let primary = wrapper["primaryRenderer"] as? [String: Any],
           let renderer = primary["playlistPanelVideoRenderer"] as? [String: Any] {
            return parsePanelSong(renderer)
        }
        return nil
    }

    private static func parsePanelSong(_ renderer: [String: Any]) -> MusicTrack? {
        if renderer["unplayableText"] != nil { return nil }
        let videoId = (renderer["videoId"] as? String)
            ?? ((renderer["navigationEndpoint"] as? [String: Any])?["watchEndpoint"] as? [String: Any])?["videoId"] as? String
        guard let videoId, !videoId.isEmpty else { return nil }
        guard let title = textOf(renderer["title"])?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty else { return nil }

        let runs = ((renderer["longBylineText"] as? [String: Any])?["runs"] as? [[String: Any]])
            ?? ((renderer["shortBylineText"] as? [String: Any])?["runs"] as? [[String: Any]])
            ?? []
        func browseId(_ run: [String: Any]) -> String? {
            ((run["navigationEndpoint"] as? [String: Any])?["browseEndpoint"] as? [String: Any])?["browseId"] as? String
        }
        let artist = runs.first { (browseId($0)?.hasPrefix("UC")) ?? false }?["text"] as? String
            ?? runs.compactMap { $0["text"] as? String }.first(where: { !$0.contains("•") && parseDuration($0) == nil })
            ?? "Unknown artist"
        let album = runs.first { (browseId($0)?.hasPrefix("MPRE")) ?? false }?["text"] as? String
        let duration = ((renderer["lengthText"] as? [String: Any])?["runs"] as? [[String: Any]])?
            .compactMap { $0["text"] as? String }
            .firstNotNull { parseDuration($0) }

        return MusicTrack(
            videoId: videoId,
            title: title,
            artist: artist,
            album: album,
            artwork: extractThumbnailsURL(renderer),
            durationSeconds: duration
        )
    }

    /// musicShelfRenderer (lists) + musicCarouselShelfRenderer (cards).
    static func parseShelves(_ root: Any) -> [HomeShelf] {
        var shelves: [HomeShelf] = []

        for renderer in collectObjects(root, key: "musicShelfRenderer") {
            let title = textOf(renderer["title"]) ?? ""
            var items: [HomeItem] = parseSongRenderers(renderer).map { HomeItem.track($0) }
            if items.isEmpty {
                items = (renderer["contents"] as? [[String: Any]] ?? []).compactMap { twoRowCard($0) }
            }
            guard !items.isEmpty else { continue }
            shelves.append(HomeShelf(title: title.isEmpty ? "Songs" : title, items: items))
        }

        for renderer in collectObjects(root, key: "musicCarouselShelfRenderer") {
            let header = renderer["header"] as? [String: Any]
            let basic = header?["musicCarouselShelfBasicHeaderRenderer"] as? [String: Any]
            let title = textOf(basic?["title"]) ?? textOf(header?["title"]) ?? ""
            let items = (renderer["contents"] as? [[String: Any]] ?? []).compactMap { twoRowCard($0) }
            guard !items.isEmpty else { continue }
            shelves.append(HomeShelf(title: title.isEmpty ? "More" : title, items: items))
        }

        // Playlist pages keep their track list in musicPlaylistShelfRenderer,
        // not musicShelfRenderer — without this, every playlist renders a
        // header with no songs and nothing in it can be played.
        for renderer in collectObjects(root, key: "musicPlaylistShelfRenderer") {
            let parsed = parseSongRenderers(renderer)
            let items: [HomeItem] = parsed.isEmpty
                ? (renderer["contents"] as? [[String: Any]] ?? []).compactMap { twoRowCard($0) }
                : parsed.map { HomeItem.track($0) }
            guard !items.isEmpty else { continue }
            let title = textOf(renderer["title"]) ?? ""
            shelves.append(HomeShelf(title: title.isEmpty ? "Songs" : title, items: items))
        }

        return shelves
    }

    /// A carousel card is either a playable song or a collection page. Song
    /// cards carry their videoId in the thumbnail's play button (or the item's
    /// own watch endpoint) and their artist/album/plays in the subtitle, so
    /// they must not be mistaken for collections.
    static func twoRowCard(_ element: [String: Any]) -> HomeItem? {
        // A carousel entry can be a song row (playable) or an entity — the row
        // renderer is the same for both, only its endpoints differ.
        if element["musicResponsiveListItemRenderer"] != nil {
            if let track = parseSongRenderers(element).first { return .track(track) }
            if let renderer = element["musicResponsiveListItemRenderer"] as? [String: Any],
               let entity = entityFromResponsiveItem(renderer) {
                return .collection(entity)
            }
            return nil
        }
        guard let renderer = element["musicTwoRowItemRenderer"] as? [String: Any] else { return nil }
        let title = textOf(renderer["title"]) ?? ""
        guard !title.isEmpty else { return nil }
        let endpoint = renderer["navigationEndpoint"] as? [String: Any]
        let artwork = extractThumbnailsURL(renderer)

        var videoId = (endpoint?["watchEndpoint"] as? [String: Any])?["videoId"] as? String
        if videoId == nil {
            for overlay in collectObjects(renderer, key: "musicItemThumbnailOverlayRenderer") {
                let content = overlay["content"] as? [String: Any]
                let play = content?["musicPlayButtonRenderer"] as? [String: Any]
                let watch = (play?["playNavigationEndpoint"] as? [String: Any])?["watchEndpoint"] as? [String: Any]
                if let id = watch?["videoId"] as? String {
                    videoId = id
                    break
                }
            }
        }
        let subtitle = textOf(renderer["subtitle"]) ?? ""
        let browseId = (endpoint?["browseEndpoint"] as? [String: Any])?["browseId"] as? String

        if let videoId, !videoId.isEmpty {
            let segments = subtitle.components(separatedBy: " • ")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter {
                    !$0.isEmpty && parseDuration($0) == nil
                        && !$0.hasSuffix(" plays") && !$0.hasSuffix(" views")
                        && !$0.hasSuffix(" subscribers")
                }
            let duration = subtitle.components(separatedBy: " • ")
                .compactMap { parseDuration($0.trimmingCharacters(in: .whitespaces)) }
                .first
            return .track(MusicTrack(
                videoId: videoId,
                title: title,
                artist: segments.first ?? "Unknown artist",
                album: segments.count > 1 ? segments[1] : nil,
                artwork: artwork,
                durationSeconds: duration
            ))
        }

        // No playable id means this card opens a page (album/artist/playlist).
        guard let browseId, !browseId.isEmpty else { return nil }
        return .collection(SearchEntity(
            browseId: browseId,
            kind: kindForBrowseId(browseId),
            title: title,
            subtitle: subtitle,
            artwork: artwork
        ))
    }

    static func parseEntities(_ root: Any, kind: EntityKind) -> [SearchEntity] {
        collectObjects(root, key: "musicResponsiveListItemRenderer").compactMap { renderer in
            guard let entity = entityFromResponsiveItem(renderer) else { return nil }
            // A filtered search can still return mixed rows; label them by what
            // the navigation endpoint actually points at.
            return SearchEntity(browseId: entity.browseId, kind: entity.kind, title: entity.title,
                                subtitle: entity.subtitle, artwork: entity.artwork)
        }
    }

    private static func entityFromResponsiveItem(_ renderer: [String: Any]) -> SearchEntity? {
        // The row's own navigation endpoint decides what it is; a plain
        // depth-first search for "browseId" would also find the artist link
        // inside an album row and mislabel it as an artist.
        let direct = ((renderer["navigationEndpoint"] as? [String: Any])?["browseEndpoint"] as? [String: Any])?["browseId"] as? String
        var resolved = direct
        if resolved == nil || resolved?.isEmpty == true {
            resolved = findString(in: renderer, key: "browseId")
        }
        guard let browseId = resolved, !browseId.isEmpty else { return nil }
        let columns = renderer["flexColumns"] as? [[String: Any]] ?? []
        func columnText(_ index: Int) -> String? {
            guard let column = columns[safe: index],
                  let flex = column["musicResponsiveListItemFlexColumnRenderer"] as? [String: Any] else { return nil }
            return textOf(flex["text"])
        }
        guard let title = columnText(0), !title.isEmpty else { return nil }
        var details: [String] = []
        for index in 1..<max(columns.count, 1) {
            if let text = columnText(index) { details.append(text) }
        }
        return SearchEntity(
            browseId: browseId,
            kind: kindForBrowseId(browseId),
            title: title,
            subtitle: details.joined(separator: " • "),
            artwork: extractThumbnailsURL(renderer)
        )
    }

    static func kindForBrowseId(_ browseId: String) -> EntityKind {
        if browseId.hasPrefix("UC") { return .artist }
        if browseId.hasPrefix("MPRE") { return .album }
        if browseId.hasPrefix("VL") || browseId.hasPrefix("PL") || browseId.hasPrefix("RD") { return .playlist }
        return .album
    }

    struct Header {
        let title: String
        let subtitle: String
        let artwork: String?
        let kind: EntityKind
        let trackCount: Int?
    }

    static func parseHeader(_ root: Any) -> Header {
        if let renderer = collectObjects(root, key: "musicResponsiveHeaderRenderer").first {
            // Albums and playlists: "Album • 2013" + "13 songs • 1 hour, 14 minutes"
            let subtitle = textOf(renderer["subtitle"]) ?? ""
            let kind: EntityKind = subtitle.lowercased().contains("playlist") ? .playlist : .album
            return Header(
                title: textOf(renderer["title"]) ?? "",
                subtitle: [subtitle, textOf(renderer["secondSubtitle"])].compactMap { $0 }
                    .filter { !$0.isEmpty }.joined(separator: " • "),
                artwork: extractThumbnailsURL(renderer),
                kind: kind,
                trackCount: textOf(renderer["secondSubtitle"]).flatMap { firstInt($0) }
            )
        }
        if let renderer = collectObjects(root, key: "musicDetailHeaderRenderer").first {
            let count = textOf(renderer["secondSubtitle"]).flatMap { firstInt($0) }
            let kind: EntityKind = renderer["subtitle"] != nil && count == nil ? .album : .album
            return Header(
                title: textOf(renderer["title"]) ?? "",
                subtitle: [textOf(renderer["subtitle"]), textOf(renderer["secondSubtitle"])]
                    .compactMap { $0 }.joined(separator: " • "),
                artwork: extractThumbnailsURL(renderer),
                kind: kind,
                trackCount: count
            )
        }
        if let renderer = collectObjects(root, key: "musicImmersiveHeaderRenderer").first {
            return Header(
                title: textOf(renderer["title"]) ?? "",
                subtitle: textOf(renderer["description"]).map { stripTags($0) } ?? "",
                artwork: extractThumbnailsURL(renderer),
                kind: .artist,
                trackCount: nil
            )
        }
        if let renderer = collectObjects(root, key: "musicEditablePlaylistDetailHeaderRenderer").first {
            let inner = renderer["header"] as? [String: Any] ?? renderer
            return Header(
                title: textOf(inner["title"]) ?? "",
                subtitle: textOf(inner["subtitle"]) ?? "",
                artwork: extractThumbnailsURL(inner),
                kind: .playlist,
                trackCount: nil
            )
        }
        if let renderer = collectObjects(root, key: "musicVisualHeaderRenderer").first {
            return Header(title: textOf(renderer["title"]) ?? "", subtitle: "",
                          artwork: extractThumbnailsURL(renderer), kind: .artist, trackCount: nil)
        }
        return Header(title: "", subtitle: "", artwork: nil, kind: .album, trackCount: nil)
    }

    private static func firstInt(_ text: String) -> Int? {
        let digits = text.split(whereSeparator: { !$0.isNumber }).first
        return digits.flatMap { Int($0) }
    }

    private static func stripTags(_ text: String) -> String {
        text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
    }
}
