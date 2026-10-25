import Foundation

public struct LRCLIBClient {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public static func lyricsURL(artist: String, title: String) -> URL? {
        let normalizedArtist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedArtist.isEmpty, !normalizedTitle.isEmpty else { return nil }
        guard var components = URLComponents(string: "https://lrclib.net/api/search") else { return nil }
        components.queryItems = [
            URLQueryItem(name: "artist_name", value: normalizedArtist),
            URLQueryItem(name: "track_name", value: normalizedTitle)
        ]
        return components.url
    }

    public static func decodeSyncedLyrics(_ data: Data) -> String {
        struct SearchItem: Decodable { let syncedLyrics: String? }
        guard let items = try? JSONDecoder().decode([SearchItem].self, from: data) else {
            return ""
        }
        return items.compactMap(\.syncedLyrics).first ?? ""
    }

    public func fetchSyncedLyrics(artist: String, title: String) async throws -> String {
        guard let url = Self.lyricsURL(artist: artist, title: title) else { return "" }
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            return ""
        }
        return Self.decodeSyncedLyrics(data)
    }
}
