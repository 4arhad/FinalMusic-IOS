import Foundation

struct LastFmSession {
    let username: String
    let sessionKey: String
}

// Port of AuthRepository + ScrobbleRepository on top of the single generic
// ws.audioscrobbler.com/2.0/ endpoint (GET unsigned reads, POST signed writes).
final class LastFmClient: Equatable {
    static let baseURL = "https://ws.audioscrobbler.com/2.0/"

    let apiKey: String
    let apiSecret: String
    private(set) var session: LastFmSession?

    init(apiKey: String, apiSecret: String, session: LastFmSession? = nil) {
        self.apiKey = LastFmSigner.normalizeKey(apiKey)
        self.apiSecret = LastFmSigner.normalizeKey(apiSecret)
        self.session = session
    }

    var isSignedIn: Bool { session != nil && !apiKey.isEmpty && !apiSecret.isEmpty }

    // MARK: Generic calls

    private func get(_ params: [String: String]) async throws -> [String: Any] {
        var query = params
        query["format"] = "json"
        var components = URLComponents(string: Self.baseURL)!
        components.queryItems = query.map { URLQueryItem(name: $0, value: $1) }
        let (data, response) = try await URLSession.shared.data(from: components.url!)
        guard (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? false else {
            throw LastFmError.requestFailed(String(decoding: data, as: UTF8.self))
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LastFmError.requestFailed("Invalid JSON")
        }
        try checkError(object)
        return object
    }

    private func post(_ params: [String: String]) async throws -> [String: Any] {
        var body = params
        body["format"] = "json"
        var request = URLRequest(url: URL(string: Self.baseURL)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
            .map { "\(enc($0))=\(enc($1))" }
            .joined(separator: "&")
            .data(using: .utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? false else {
            throw LastFmError.requestFailed(String(decoding: data, as: UTF8.self))
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LastFmError.requestFailed("Invalid JSON")
        }
        try checkError(object)
        return object
    }

    private func enc(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? value
    }

    private func checkError(_ object: [String: Any]) throws {
        if let code = object["error"] as? Int, code != 0 {
            let message = object["message"] as? String ?? "Last.fm error \(code)"
            throw LastFmError.api(code: code, message: message)
        }
    }

    // MARK: Auth (mirrors AuthRepository)

    func authURL() -> URL? {
        guard !apiKey.isEmpty else { return nil }
        var components = URLComponents(string: "https://www.last.fm/api/auth/")!
        components.queryItems = [
            URLQueryItem(name: "api_key", value: apiKey),
            URLQueryItem(name: "cb", value: "lastwave://lastfm/callback"),
        ]
        return components.url
    }

    func requestAuthToken() async throws -> String {
        let object = try await get([
            "method": "auth.getToken",
            "api_key": apiKey,
        ])
        guard let token = object["token"] as? String else {
            throw LastFmError.requestFailed("No token in response")
        }
        return token
    }

    @discardableResult
    func completeWebAuth(token: String) async throws -> String {
        guard !apiKey.isEmpty, !apiSecret.isEmpty else {
            throw LastFmError.api(code: -1, message: "Add your Last.fm API key and secret in Settings first")
        }
        let signParams = [
            "method": "auth.getSession",
            "token": token,
            "api_key": apiKey,
        ]
        var body = signParams
        body["api_sig"] = LastFmSigner.sign(params: signParams, secret: apiSecret)
        let object = try await post(body)
        guard let sessionObject = object["session"] as? [String: Any],
              let key = sessionObject["key"] as? String,
              let name = sessionObject["name"] as? String else {
            throw LastFmError.requestFailed("Last.fm didn't return a session")
        }
        session = LastFmSession(username: name, sessionKey: key)
        return name
    }

    // MARK: Scrobbling (mirrors ScrobbleRepository)

    func updateNowPlaying(track: String, artist: String, album: String?, duration: TimeInterval?) async throws {
        guard let session else { return }
        var params: [String: String] = [
            "method": "track.updateNowPlaying",
            "artist": artist,
            "track": track,
            "sk": session.sessionKey,
            "api_key": apiKey,
        ]
        if let album, !album.isEmpty { params["album"] = album }
        if let duration, duration > 0 { params["duration"] = String(Int(duration)) }
        params["api_sig"] = LastFmSigner.sign(params: params, secret: apiSecret)
        _ = try await post(params)
    }

    func scrobble(track: String, artist: String, album: String?, startTime: Date) async throws {
        guard let session else { return }
        var params: [String: String] = [
            "method": "track.scrobble",
            "artist": artist,
            "track": track,
            "timestamp": String(Int(startTime.timeIntervalSince1970)),
            "sk": session.sessionKey,
            "api_key": apiKey,
        ]
        if let album, !album.isEmpty { params["album"] = album }
        params["api_sig"] = LastFmSigner.sign(params: params, secret: apiSecret)
        _ = try await post(params)
    }

    func love(track: String, artist: String) async throws {
        guard let session else { return }
        var params: [String: String] = [
            "method": "track.love",
            "track": track,
            "artist": artist,
            "sk": session.sessionKey,
            "api_key": apiKey,
        ]
        params["api_sig"] = LastFmSigner.sign(params: params, secret: apiSecret)
        _ = try await post(params)
    }

    static func == (lhs: LastFmClient, rhs: LastFmClient) -> Bool { lhs === rhs }
}

enum LastFmError: LocalizedError {
    case api(code: Int, message: String)
    case requestFailed(String)

    var errorDescription: String? {
        switch self {
        case .api(_, let message): return message
        case .requestFailed(let detail): return "Last.fm request failed: \(detail.prefix(120))"
        }
    }
}
