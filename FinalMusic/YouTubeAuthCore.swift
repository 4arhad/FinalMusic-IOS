import Foundation
import CryptoKit

// YouTube Music account credentials, kept separate from the UI so the parsing
// and the SAPISIDHASH signing can be unit-tested (see LastWaveCoreChecks).
//
// Signing follows YouTube's own scheme, the same one the Android client and
// ytmusicapi use:
//     Authorization: SAPISIDHASH <unix-seconds>_<sha1("<seconds> <SAPISID> <origin>")>

public struct YouTubeCredential: Equatable {
    public static let origin = "https://music.youtube.com"

    public let cookies: [String: String]

    /// Parses either a raw `Cookie:` header ("SID=…; SAPISID=…") or a JSON
    /// object of name → value (what browser cookie-export extensions emit).
    public init?(rawCookies: String) {
        let trimmed = rawCookies.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var parsed: [String: String] = [:]
        if trimmed.hasPrefix("{") {
            guard let data = trimmed.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            for (key, value) in object {
                if let text = value as? String, !text.isEmpty {
                    parsed[key] = text
                } else if let nested = value as? [String: Any], let text = nested["value"] as? String {
                    parsed[key] = text
                }
            }
        } else {
            var header = trimmed
            if let range = header.range(of: "cookie:", options: .caseInsensitive) {
                header = String(header[range.upperBound...])
            }
            for pair in header.split(separator: ";") {
                let parts = pair.split(separator: "=", maxSplits: 1).map {
                    $0.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                guard parts.count == 2, !parts[0].isEmpty else { continue }
                parsed[parts[0]] = parts[1]
            }
        }
        guard parsed["SAPISID"] != nil || parsed["__Secure-3PAPISID"] != nil else { return nil }
        self.cookies = parsed
    }

    public var sapisid: String? {
        cookies["SAPISID"] ?? cookies["__Secure-3PAPISID"]
    }

    public var cookieHeader: String {
        cookies.keys.sorted().map { "\($0)=\(cookies[$0] ?? "")" }.joined(separator: "; ")
    }

    /// `SAPISIDHASH <seconds>_<sha1 hex>` for the current (or supplied) instant.
    public func authorization(now: Date = Date()) -> String? {
        guard let sapisid, !sapisid.isEmpty else { return nil }
        let seconds = Int(now.timeIntervalSince1970)
        let payload = "\(seconds) \(sapisid) \(Self.origin)"
        let digest = Insecure.SHA1.hash(data: Data(payload.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "SAPISIDHASH \(seconds)_\(hex)"
    }

    /// Headers every authenticated InnerTube call needs.
    public func requestHeaders(now: Date = Date()) -> [String: String] {
        var headers: [String: String] = [
            "Cookie": cookieHeader,
            "Origin": Self.origin,
            "X-Origin": Self.origin,
            "X-Goog-AuthUser": "0",
        ]
        if let authorization = authorization(now: now) {
            headers["Authorization"] = authorization
        }
        return headers
    }
}

// MARK: - OAuth (browser device-code flow)

/// Response of `oauth2.googleapis.com/device/code`: the user types `userCode`
/// into `verificationURL` in their own browser, the app polls for the token.
public struct DeviceCodeResponse: Equatable {
    public let deviceCode: String
    public let userCode: String
    public let verificationURL: URL
    public let interval: Int
    public let expiresIn: Int

    public init?(json: [String: Any]) {
        guard let deviceCode = json["device_code"] as? String,
              let userCode = json["user_code"] as? String,
              let urlString = json["verification_url"] as? String,
              let url = URL(string: urlString) else { return nil }
        self.deviceCode = deviceCode
        self.userCode = userCode
        self.verificationURL = url
        self.interval = (json["interval"] as? Int) ?? 5
        self.expiresIn = (json["expires_in"] as? Int) ?? 1800
    }

    public static func decode(_ data: Data) -> DeviceCodeResponse? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return DeviceCodeResponse(json: object)
    }
}

/// An OAuth access token plus the refresh token that keeps it alive.
public struct YouTubeToken: Equatable, Codable {
    public var accessToken: String
    public var refreshToken: String?
    public var expiresAt: Date
    public var scope: String?

    public init(accessToken: String, refreshToken: String?, expiresAt: Date, scope: String? = nil) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.scope = scope
    }

    /// `now` is injectable so the expiry logic is testable.
    public init?(json: [String: Any], now: Date = Date(), keepingRefreshToken: String? = nil) {
        guard let accessToken = json["access_token"] as? String, !accessToken.isEmpty else { return nil }
        let lifetime = (json["expires_in"] as? NSNumber)?.doubleValue ?? 3600
        self.accessToken = accessToken
        // A refresh response carries no refresh_token — keep the stored one.
        self.refreshToken = (json["refresh_token"] as? String) ?? keepingRefreshToken
        self.expiresAt = now.addingTimeInterval(lifetime)
        self.scope = json["scope"] as? String
    }

    public func isExpired(now: Date = Date(), leeway: TimeInterval = 60) -> Bool {
        now.addingTimeInterval(leeway) >= expiresAt
    }

    public var json: [String: Any] {
        ["access_token": accessToken,
         "refresh_token": refreshToken as Any,
         "expires_at": expiresAt.timeIntervalSince1970,
         "scope": scope as Any]
    }

    public static func from(json: [String: Any]) -> YouTubeToken? {
        guard let accessToken = json["access_token"] as? String,
              let expiresAt = (json["expires_at"] as? NSNumber)?.doubleValue else { return nil }
        return YouTubeToken(accessToken: accessToken,
                            refreshToken: json["refresh_token"] as? String,
                            expiresAt: Date(timeIntervalSince1970: expiresAt),
                            scope: json["scope"] as? String)
    }
}

/// How an authenticated InnerTube call proves who it is: web cookies (the music
/// web client) or an OAuth bearer token (the browser device-code flow).
public struct InnerTubeAuth: Equatable {
    public var credential: YouTubeCredential?
    public var bearer: String?

    public init(credential: YouTubeCredential? = nil, bearer: String? = nil) {
        self.credential = credential
        self.bearer = bearer
    }

    public var isEmpty: Bool { credential == nil && bearer == nil }
    public var hasBearer: Bool { !(bearer ?? "").isEmpty }

    public func headers(now: Date = Date()) -> [String: String] {
        var headers = credential?.requestHeaders(now: now) ?? [:]
        if let bearer, !bearer.isEmpty {
            headers["Authorization"] = "Bearer \(bearer)"
            // Cookie sign-in sends these; an OAuth call must not claim to be the
            // web-origin session, so the cookie headers are dropped here.
            headers.removeValue(forKey: "Cookie")
            headers.removeValue(forKey: "X-Goog-AuthUser")
            headers["X-Origin"] = YouTubeCredential.origin
        }
        return headers
    }
}
