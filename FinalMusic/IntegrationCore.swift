import Foundation
import Foundation

public struct YouTubeVideo: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let channelTitle: String
    public let thumbnailURL: URL?

    public init(id: String, title: String, channelTitle: String, thumbnailURL: URL?) {
        self.id = id
        self.title = title
        self.channelTitle = channelTitle
        self.thumbnailURL = thumbnailURL
    }
}

public enum YouTubeDataClientError: Error, LocalizedError, Equatable {
    case missingAPIKey
    case emptyQuery
    case invalidResponse
    case httpStatus(Int, message: String?)

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Add a YouTube Data API key in Settings to search videos."
        case .emptyQuery:
            return "Enter a search term first."
        case .invalidResponse:
            return "YouTube returned an invalid search response."
        case .httpStatus(let status, let message):
            return message ?? "YouTube search failed (HTTP \(status))."
        }
    }
}

public struct YouTubeDataClient {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public static func searchURL(query: String, apiKey: String) throws -> URL {
        let normalizedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedKey.isEmpty else { throw YouTubeDataClientError.missingAPIKey }

        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedQuery.isEmpty else { throw YouTubeDataClientError.emptyQuery }

        guard var components = URLComponents(string: "https://www.googleapis.com/youtube/v3/search") else {
            throw YouTubeDataClientError.invalidResponse
        }
        components.queryItems = [
            URLQueryItem(name: "part", value: "snippet"),
            URLQueryItem(name: "type", value: "video"),
            URLQueryItem(name: "videoCategoryId", value: "10"),
            URLQueryItem(name: "maxResults", value: "20"),
            URLQueryItem(name: "q", value: normalizedQuery),
            URLQueryItem(name: "key", value: normalizedKey)
        ]
        guard let url = components.url else { throw YouTubeDataClientError.invalidResponse }
        return url
    }

    public func searchVideos(query: String, apiKey: String) async throws -> [YouTubeVideo] {
        let url = try Self.searchURL(query: query, apiKey: apiKey)
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("LastWave-iOS/1.0", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw YouTubeDataClientError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? JSONDecoder().decode(APIErrorEnvelope.self, from: data)).flatMap { envelope in
                envelope.error.message
            }
            throw YouTubeDataClientError.httpStatus(http.statusCode, message: message)
        }
        return try Self.decodeSearchResponse(data)
    }

    public static func decodeSearchResponse(_ data: Data) throws -> [YouTubeVideo] {
        let response: SearchResponse
        do {
            response = try JSONDecoder().decode(SearchResponse.self, from: data)
        } catch {
            throw YouTubeDataClientError.invalidResponse
        }
        return response.items.compactMap { item in
            guard let id = item.id.videoId, !id.isEmpty else { return nil }
            let thumbnail = item.snippet.thumbnails?.high?.url
                ?? item.snippet.thumbnails?.medium?.url
                ?? item.snippet.thumbnails?.default?.url
            return YouTubeVideo(
                id: id,
                title: item.snippet.title,
                channelTitle: item.snippet.channelTitle,
                thumbnailURL: thumbnail.flatMap(URL.init(string:))
            )
        }
    }
}

private struct SearchResponse: Decodable {
    let items: [Item]

    struct Item: Decodable {
        let id: ItemID
        let snippet: Snippet
    }

    struct ItemID: Decodable {
        let videoId: String?
    }

    struct Snippet: Decodable {
        let title: String
        let channelTitle: String
        let thumbnails: Thumbnails?
    }

    struct Thumbnails: Decodable {
        let `default`: Thumbnail?
        let medium: Thumbnail?
        let high: Thumbnail?
    }

    struct Thumbnail: Decodable {
        let url: String
    }
}

private struct APIErrorEnvelope: Decodable {
    let error: APIError

    struct APIError: Decodable {
        let message: String
    }
}

public struct TimedLyricLine: Equatable, Identifiable, Sendable {
    public let timestamp: TimeInterval
    public let text: String

    public var id: String { "\(timestamp)-\(text)" }

    public init(timestamp: TimeInterval, text: String) {
        self.timestamp = timestamp
        self.text = text
    }
}

public enum SyncedLyricsParser {
    private static let timestampExpression = try! NSRegularExpression(
        pattern: #"^\[(\d+):(\d{2})(?:\.(\d{1,3}))?\]"#
    )

    public static func parse(_ source: String) -> [TimedLyricLine] {
        var parsed: [(order: Int, line: TimedLyricLine)] = []
        var order = 0

        for sourceLine in source.components(separatedBy: .newlines) {
            var remainder = sourceLine
            var timestamps: [TimeInterval] = []

            while let match = timestampExpression.firstMatch(
                in: remainder,
                range: NSRange(remainder.startIndex..., in: remainder)
            ),
            let prefixRange = Range(match.range, in: remainder),
            let minuteRange = Range(match.range(at: 1), in: remainder),
            let secondRange = Range(match.range(at: 2), in: remainder) {
                let minutes = Double(remainder[minuteRange]) ?? 0
                let seconds = Double(remainder[secondRange]) ?? 0
                var milliseconds = 0
                if let fractionRange = Range(match.range(at: 3), in: remainder) {
                    let digits = String(remainder[fractionRange])
                    milliseconds = Int(digits) ?? 0
                    for _ in digits.count..<3 { milliseconds *= 10 }
                }
                timestamps.append(minutes * 60 + seconds + Double(milliseconds) / 1_000)
                remainder.removeSubrange(prefixRange)
            }

            let text = remainder.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            for timestamp in timestamps {
                parsed.append((order, TimedLyricLine(timestamp: timestamp, text: text)))
                order += 1
            }
        }

        return parsed.sorted {
            $0.line.timestamp == $1.line.timestamp
                ? $0.order < $1.order
                : $0.line.timestamp < $1.line.timestamp
        }.map(\.line)
    }

    public static func activeLineIndex(in lines: [TimedLyricLine], at time: TimeInterval) -> Int? {
        guard time.isFinite else { return nil }
        return lines.lastIndex { $0.timestamp <= time }
    }
}

public enum ScrobblePolicy {
    public static func shouldScrobble(elapsed: TimeInterval, duration: TimeInterval) -> Bool {
        guard elapsed.isFinite, duration.isFinite, elapsed >= 0, duration > 30 else { return false }
        return elapsed >= min(duration / 2, 240)
    }
}
