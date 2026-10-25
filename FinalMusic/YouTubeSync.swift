import Foundation
import Security
import UIKit

// YouTube Music account sync: browser sign-in (Google device-code flow), cookie
// sign-in as a fallback, importing the account's liked songs and playlists, and
// pushing app likes back to the account. Credentials are only ever stored on
// this device; nothing is uploaded anywhere else.
//
// Authenticated calls use the ordinary WEB_REMIX endpoints. Verified against
// the live API: a bearer token is accepted there (an invalid one answers
// `401 Request had invalid authentication credentials. Expected OAuth 2 access
// token, login cookie or other valid authentication`), and the cookie variant
// signs with SAPISIDHASH.

// MARK: - Credential storage

/// Credential storage. The Keychain is used when it is available; an unsigned
/// simulator/dev build has no keychain-access-group entitlement, so SecItemAdd
/// fails with errSecMissingEntitlement (-34018) — verified on this machine — and
/// we fall back to the app's own container instead of silently losing the login.
/// `lastStatus` records the last Keychain result.
enum YouTubeKeychain {
    private static let service = "app.lastwave.ios.youtube"
    private static let cookieAccount = "cookieHeader"
    private static let tokenAccount = "oauthToken"
    private static let cookieFallback = "yt.cookieHeaderFallback"
    private static let tokenFallback = "yt.oauthTokenFallback"

    private(set) static var lastStatus: OSStatus = errSecSuccess
    private(set) static var usedFallback = false

    private static func save(_ value: String, account: String, fallbackKey: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        var attributes = query
        attributes[kSecValueData as String] = Data(value.utf8)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(attributes as CFDictionary, nil)
        lastStatus = status
        if status == errSecSuccess {
            UserDefaults.standard.removeObject(forKey: fallbackKey)
            usedFallback = false
        } else {
            usedFallback = true
            // Store it anyway so the sign-in survives the next launch.
            UserDefaults.standard.set(value, forKey: fallbackKey)
        }
    }

    private static func load(account: String, fallbackKey: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        lastStatus = status
        if status == errSecSuccess, let data = item as? Data {
            return String(data: data, encoding: .utf8)
        }
        return UserDefaults.standard.string(forKey: fallbackKey)
    }

    private static func clear(account: String, fallbackKey: String) {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ] as CFDictionary)
        UserDefaults.standard.removeObject(forKey: fallbackKey)
    }

    static func saveCookieHeader(_ value: String) { save(value, account: cookieAccount, fallbackKey: cookieFallback) }
    static func loadCookieHeader() -> String? { load(account: cookieAccount, fallbackKey: cookieFallback) }
    static func clearCookieHeader() { clear(account: cookieAccount, fallbackKey: cookieFallback) }

    static func saveToken(_ json: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: json),
              let text = String(data: data, encoding: .utf8) else { return }
        save(text, account: tokenAccount, fallbackKey: tokenFallback)
    }

    static func loadToken() -> [String: Any]? {
        guard let text = load(account: tokenAccount, fallbackKey: tokenFallback),
              let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object
    }

    static func clearToken() { clear(account: tokenAccount, fallbackKey: tokenFallback) }

    static func clearAll() {
        clearCookieHeader()
        clearToken()
    }

    /// Human-readable state for the settings screen.
    static var storageDescription: String {
        if usedFallback || lastStatus == errSecMissingEntitlement {
            return "Keychain unavailable in this build (no entitlement) — stored in the app container instead."
        }
        return "Stored in the Keychain."
    }
}

// MARK: - OAuth device-code flow (opens the browser)

/// Google's device-code flow: the app asks for a short code, the user approves
/// it in their own browser at google.com/device, and the app polls for the
/// token. This is the supported way for an app to send the user to a browser and
/// come back with a real account session (embedded web views are blocked by
/// Google, and `SFSafariViewController` sessions are unreadable by design).
enum YouTubeOAuth {
    /// The public "YouTube on TV" OAuth client identity — the same one yt-dlp
    /// and InnerTubeX use for this flow. TV & Limited Input clients are the ones
    /// allowed to use the device flow for YouTube scopes; the scope must be the
    /// full `youtube` one (`youtube.readonly` is refused with
    /// `restricted_client`, verified live on 2026-10-25).
    static let clientID = "861556708454-d6dlm3lh05idd8npek18k6be8ba3oc68.apps.googleusercontent.com"
    static let clientSecret = "SboVhoG9s0rNafixCSGGKXAT"
    static let scope = "https://www.googleapis.com/auth/youtube"

    static let deviceCodeURL = URL(string: "https://oauth2.googleapis.com/device/code")!
    static let tokenURL = URL(string: "https://oauth2.googleapis.com/token")!

    private static func form(_ fields: [String: String]) async throws -> (Int, [String: Any]) {
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = fields
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")" }
            .joined(separator: "&")
            .data(using: .utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let object = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        return (status, object)
    }

    static func requestDeviceCode() async throws -> DeviceCodeResponse {
        var request = URLRequest(url: deviceCodeURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = [("client_id", clientID), ("scope", scope)]
            .map { "\($0.0)=\($0.1.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")" }
            .joined(separator: "&")
            .data(using: .utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let device = DeviceCodeResponse.decode(data) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let body = String(data: data, encoding: .utf8) ?? ""
            throw YouTubeOAuthError.server(status, body)
        }
        return device
    }

    /// One poll iteration. `nil` means "keep waiting" (authorization_pending).
    static func poll(deviceCode: String) async throws -> YouTubeToken? {
        let (status, object) = try await form([
            "client_id": clientID,
            "client_secret": clientSecret,
            "device_code": deviceCode,
            "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
        ])
        if status == 200 {
            guard let token = YouTubeToken(json: object) else { throw YouTubeOAuthError.server(status, "unreadable token") }
            return token
        }
        switch object["error"] as? String {
        case "authorization_pending": return nil
        case "slow_down": throw YouTubeOAuthError.slowDown
        case "access_denied": throw YouTubeOAuthError.denied
        case "expired_token": throw YouTubeOAuthError.expired
        default: throw YouTubeOAuthError.server(status, (object["error_description"] as? String) ?? "\(object)")
        }
    }

    static func refresh(refreshToken: String) async throws -> YouTubeToken {
        let (status, object) = try await form([
            "client_id": clientID,
            "client_secret": clientSecret,
            "refresh_token": refreshToken,
            "grant_type": "refresh_token",
        ])
        guard status == 200, let token = YouTubeToken(json: object, keepingRefreshToken: refreshToken) else {
            throw YouTubeOAuthError.server(status, (object["error"] as? String) ?? "refresh failed")
        }
        return token
    }
}

enum YouTubeOAuthError: LocalizedError {
    case slowDown
    case denied
    case expired
    case server(Int, String)
    case noSession

    var errorDescription: String? {
        switch self {
        case .slowDown: return "polling too fast"
        case .denied: return "the sign-in was denied in the browser"
        case .expired: return "the sign-in code expired"
        case .server(let status, let body): return "Google answered HTTP \(status): \(body.prefix(120))"
        case .noSession: return "no YouTube Music session is stored"
        }
    }
}

// MARK: - Authenticated InnerTube calls

extension InnerTube {
    static func postMusicAuthenticated(_ path: String, body: [String: Any],
                                       auth: InnerTubeAuth) async throws -> Any {
        let config = await webConfig()
        var headers = webHeaders(config.clientVersion)
        for (name, value) in auth.headers() { headers[name] = value }
        return try await postJSON(
            url: "\(musicAPI)/\(path)?key=\(config.apiKey)&prettyPrint=false",
            body: body,
            headers: headers
        )
    }

    /// Account display name — also used to validate a session.
    static func accountName(auth: InnerTubeAuth) async throws -> String {
        let config = await webConfig()
        let root = try await postMusicAuthenticated(
            "account/account_menu",
            body: ["context": webContext(config.visitorData)],
            auth: auth
        )
        for header in collectObjects(root, key: "activeAccountHeaderRenderer") {
            if let name = textOf(header["accountName"]), !name.isEmpty { return name }
        }
        for header in collectObjects(root, key: "accountItemRenderer") {
            if let name = textOf(header["accountName"]), !name.isEmpty { return name }
        }
        // Signed-out callers still get HTTP 200 here — the page simply has no
        // account header (verified against the live endpoint), so the absence
        // is the signal that the session was not accepted.
        throw YouTubeSyncError.notSignedIn
    }

    /// The account's liked songs (FEmusic_liked_videos).
    static func likedSongs(auth: InnerTubeAuth, limit: Int = 200) async throws -> [MusicTrack] {
        let config = await webConfig()
        let root = try await postMusicAuthenticated(
            "browse",
            body: ["context": webContext(config.visitorData), "browseId": "FEmusic_liked_videos"],
            auth: auth
        )
        try ensureSignedIn(root)
        let shelves = parseShelves(root)
        let trackItems = shelves.first { $0.hasPlayableTracks }?.items ?? []
        var tracks = trackItems.compactMap { item -> MusicTrack? in
            if case .track(let track) = item { return track } else { return nil }
        }
        if tracks.isEmpty { tracks = parseSongRenderers(root) }
        return Array(tracks.prefix(limit))
    }

    /// The account's playlists (FEmusic_liked_playlists) as openable entities.
    static func likedPlaylists(auth: InnerTubeAuth, limit: Int = 100) async throws -> [SearchEntity] {
        let config = await webConfig()
        let root = try await postMusicAuthenticated(
            "browse",
            body: ["context": webContext(config.visitorData), "browseId": "FEmusic_liked_playlists"],
            auth: auth
        )
        try ensureSignedIn(root)
        var entities: [SearchEntity] = []
        var seen = Set<String>()
        for shelf in parseShelves(root) {
            for item in shelf.items {
                if case .collection(let entity) = item, entity.kind == EntityKind.playlist,
                   seen.insert(entity.browseId).inserted {
                    entities.append(entity)
                }
            }
        }
        return Array(entities.prefix(limit))
    }

    /// A signed-out account page answers HTTP 200 with a messageRenderer
    /// ("Sign in …") and no shelves, so emptiness plus that message means the
    /// session is missing or expired — surface it instead of reporting "0 songs".
    private static func ensureSignedIn(_ root: Any) throws {
        if !collectObjects(root, key: "messageRenderer").isEmpty { throw YouTubeSyncError.notSignedIn }
        if parseShelves(root).isEmpty && parseSongRenderers(root).isEmpty {
            throw YouTubeSyncError.notSignedIn
        }
    }

    /// Pushes a like/unlike to the account so the library stays in step.
    static func setLike(videoId: String, liked: Bool, auth: InnerTubeAuth) async throws {
        let config = await webConfig()
        _ = try await postMusicAuthenticated(
            liked ? "like/like" : "like/removelike",
            body: ["context": webContext(config.visitorData), "target": ["videoId": videoId]],
            auth: auth
        )
    }
}

enum YouTubeSyncError: LocalizedError {
    case notSignedIn
    case noAuth

    var errorDescription: String? {
        switch self {
        case .notSignedIn:
            return "YouTube Music did not accept this session as signed in. Sign in again (the cookies or the OAuth token may have expired)."
        case .noAuth:
            return "Not connected to YouTube Music."
        }
    }
}

// MARK: - Account state

@MainActor
final class YouTubeAccount: ObservableObject {
    static let shared = YouTubeAccount()

    enum Status: Equatable {
        case disconnected
        case connecting
        case awaitingBrowser(userCode: String)
        case connected(name: String)
        case failed(String)
    }

    @Published private(set) var status: Status = .disconnected
    @Published private(set) var busy = false
    @Published var message: String?
    @Published var autoSyncLiked: Bool {
        didSet { UserDefaults.standard.set(autoSyncLiked, forKey: Self.autoSyncKey) }
    }

    private static let autoSyncKey = "yt.autoSyncLiked"
    private static let nameKey = "yt.accountName"

    private(set) var credential: YouTubeCredential?
    private(set) var token: YouTubeToken?
    private var pollTask: Task<Void, Never>?

    var isConnected: Bool {
        if case .connected = status { return true }
        return false
    }

    /// The pending browser code, when the user still has to approve it.
    var pendingUserCode: String? {
        if case .awaitingBrowser(let code) = status { return code }
        return nil
    }

    var accountName: String? {
        if case .connected(let name) = status { return name }
        return nil
    }

    var usingOAuth: Bool { token != nil }

    init() {
        autoSyncLiked = UserDefaults.standard.bool(forKey: Self.autoSyncKey)
        restore()
    }

    func restore() {
        if let json = YouTubeKeychain.loadToken(), let token = YouTubeToken.from(json: json) {
            self.token = token
            status = .connected(name: UserDefaults.standard.string(forKey: Self.nameKey) ?? "YouTube Music")
            return
        }
        if let raw = YouTubeKeychain.loadCookieHeader(), let credential = YouTubeCredential(rawCookies: raw) {
            self.credential = credential
            status = .connected(name: UserDefaults.standard.string(forKey: Self.nameKey) ?? "YouTube Music")
        }
    }

    // MARK: Sign-in

    /// Opens the browser for Google sign-in: requests a device code, sends the
    /// user to google.com/device, then polls until the account is approved.
    /// Codes are single-use and Safari often reuses the old tab, so a second tap
    /// must NOT issue a second code — approving the stale one is exactly what
    /// produces Google's "User code already redeemed" page. An explicit
    /// ``getNewCode()`` is the only way to start a fresh attempt.
    func connectWithBrowser() async {
        guard pendingUserCode == nil else {
            NSLog("LWOAUTH connect_reused_pending user_code=%@", pendingUserCode ?? "-")
            return
        }
        status = .connecting
        message = nil
        do {
            let device = try await YouTubeOAuth.requestDeviceCode()
            status = .awaitingBrowser(userCode: device.userCode)
            message = "Enter the code \(device.userCode) in the browser window that just opened."
            NSLog("LWOAUTH device_code user_code=%@ url=%@ interval=%d", device.userCode,
                  device.verificationURL.absoluteString, device.interval)
            if UserDefaults.standard.bool(forKey: "SuppressBrowserOpen") {
                // Test hook: the poll keeps running, the app stays in front so the
                // pending-code UI can be inspected.
                NSLog("LWOAUTH browser_open_suppressed")
            } else {
                await UIApplication.shared.open(device.verificationURL)
            }
            pollTask = Task { [weak self] in await self?.pollForApproval(device) }
        } catch {
            status = .failed("Could not start browser sign-in (\(error.localizedDescription)).")
            NSLog("LWOAUTH device_code_failed error=%@", String(describing: error))
        }
    }

    /// Re-opens the approval page if the user dismissed the browser.
    func reopenVerificationPage() {
        Task { await UIApplication.shared.open(URL(string: "https://www.google.com/device")!) }
    }

    /// Starts over with a brand-new single-use code — needed when the previous
    /// one was approved elsewhere, expired, or the tab was lost.
    func getNewCode() async {
        cancelBrowserSignIn()
        await connectWithBrowser()
    }

    func cancelBrowserSignIn() {
        pollTask?.cancel()
        pollTask = nil
        if pendingUserCode != nil { status = .disconnected }
    }

    private func pollForApproval(_ device: DeviceCodeResponse) async {
        let deadline = Date().addingTimeInterval(TimeInterval(device.expiresIn))
        var interval = max(1, device.interval)
        while Date() < deadline {
            if Task.isCancelled { return }
            do {
                if let token = try await YouTubeOAuth.poll(deviceCode: device.deviceCode) {
                    await finishBrowserSignIn(token)
                    return
                }
            } catch YouTubeOAuthError.slowDown {
                interval += 5
            } catch {
                NSLog("LWOAUTH poll_failed error=%@", String(describing: error))
                status = .failed("Browser sign-in failed: \(error.localizedDescription)")
                return
            }
            try? await Task.sleep(nanoseconds: UInt64(interval) * 1_000_000_000)
        }
        if !Task.isCancelled {
            status = .failed("The sign-in code expired before it was approved.")
            NSLog("LWOAUTH poll_expired")
        }
    }

    private func finishBrowserSignIn(_ token: YouTubeToken) async {
        do {
            // Google approving a device code does not prove that WEB_REMIX
            // accepts its OAuth token. Validate before persisting it or
            // discarding a previously working cookie session.
            let name = try await InnerTube.accountName(auth: InnerTubeAuth(bearer: token.accessToken))
            self.token = token
            YouTubeKeychain.saveToken(token.json)
            credential = nil
            YouTubeKeychain.clearCookieHeader()
            UserDefaults.standard.set(name, forKey: Self.nameKey)
            status = .connected(name: name)
            message = "Signed in as \(name)."
            NSLog("LWOAUTH connected name=%@ auth=bearer", name)
            if autoSyncLiked {
                await syncLikedSongs(into: LikedStore.shared)
            }
        } catch {
            // Do not retain a token that failed the music API validation.
            // In particular, restore() must not report it as connected on
            // the next launch. A pre-existing cookie session is preserved.
            NSLog("LWOAUTH bearer_rejected error=%@", String(describing: error))
            if credential == nil {
                self.token = nil
                YouTubeKeychain.clearToken()
            }
            status = .failed("Google sign-in succeeded, but YouTube Music rejected the OAuth session (\(error.localizedDescription)). Try the cookie sign-in option; repeating Google approval alone may not resolve this.")
        }
    }

    /// Cookie sign-in (fallback path): accepts a raw `Cookie:` header or a JSON
    /// cookie dump.
    func connect(rawCookies: String) async {
        guard let credential = YouTubeCredential(rawCookies: rawCookies) else {
            status = .failed("That does not look like a YouTube Music cookie header (SAPISID is missing).")
            return
        }
        cancelBrowserSignIn()
        status = .connecting
        message = nil
        do {
            let name = try await InnerTube.accountName(auth: InnerTubeAuth(credential: credential))
            self.credential = credential
            token = nil
            YouTubeKeychain.clearToken()
            YouTubeKeychain.saveCookieHeader(credential.cookieHeader)
            UserDefaults.standard.set(name, forKey: Self.nameKey)
            status = .connected(name: name)
            message = "Signed in as \(name)."
            NSLog("LWOAUTH connected name=%@ auth=cookie", name)
        } catch {
            self.credential = nil
            status = .failed("YouTube rejected those cookies (\(error.localizedDescription))")
            NSLog("LWOAUTH cookie_rejected error=%@", String(describing: error))
        }
    }

    func disconnect() {
        cancelBrowserSignIn()
        credential = nil
        token = nil
        YouTubeKeychain.clearAll()
        UserDefaults.standard.removeObject(forKey: Self.nameKey)
        status = .disconnected
        message = "Signed out of YouTube Music."
    }

    // MARK: Session

    /// Refreshes the OAuth token when it is about to expire, then returns the
    /// auth to use for a call.
    private func currentAuth() async -> InnerTubeAuth? {
        if let token {
            var usable = token
            if usable.isExpired(), let refreshToken = usable.refreshToken {
                do {
                    usable = try await YouTubeOAuth.refresh(refreshToken: refreshToken)
                    self.token = usable
                    YouTubeKeychain.saveToken(usable.json)
                    NSLog("LWOAUTH token_refreshed expires_at=%d", Int(usable.expiresAt.timeIntervalSince1970))
                } catch {
                    NSLog("LWOAUTH refresh_failed error=%@", String(describing: error))
                }
            }
            return InnerTubeAuth(bearer: usable.accessToken)
        }
        if let credential { return InnerTubeAuth(credential: credential) }
        return nil
    }

    /// Used by the self-test hook to prove the refresh path works.
    func expireTokenForTesting() {
        guard var token else { return }
        token.expiresAt = Date().addingTimeInterval(-10)
        self.token = token
        YouTubeKeychain.saveToken(token.json)
    }

    // MARK: Sync operations

    /// Imports the account's liked songs into the local library (adds missing
    /// entries, never removes local ones).
    @discardableResult
    func syncLikedSongs(into store: LikedStore) async -> Int {
        guard let auth = await currentAuth() else { return 0 }
        busy = true
        defer { busy = false }
        do {
            let tracks = try await InnerTube.likedSongs(auth: auth)
            let existingIds = Set(store.tracks.map(\.videoId))
            let missing = tracks.reversed().filter { !existingIds.contains($0.videoId) }
            store.addBatch(missing)
            let added = missing.count
            message = "Liked songs: \(tracks.count) on YouTube, \(added) added here."
            NSLog("LWSYNC liked remote=%d added=%d", tracks.count, added)
            return added
        } catch {
            if let syncError = error as? YouTubeSyncError, syncError == .notSignedIn {
                // The stored session is dead (expired/revoked): surface a clean
                // reconnect instead of a cryptic sync failure.
                disconnect()
                message = "The YouTube Music session expired — connect again."
                NSLog("LWSYNC session_dead -> disconnected")
            } else {
                message = "Liked songs sync failed: \(error.localizedDescription)"
            }
            NSLog("LWSYNC liked_failed error=%@", String(describing: error))
            return 0
        }
    }

    /// Imports the account's playlists (new ones only, so local edits survive).
    @discardableResult
    func importPlaylists(into store: PlaylistStore, playlistLimit: Int = 50, trackLimit: Int = 300) async -> Int {
        guard let auth = await currentAuth() else { return 0 }
        busy = true
        defer { busy = false }
        do {
            let playlists = try await InnerTube.likedPlaylists(auth: auth, limit: playlistLimit)
            var imported = 0
            for playlist in playlists {
                guard !store.playlists.contains(where: { $0.title == playlist.title }) else { continue }
                let detail = try await InnerTube.browseCollection(playlist.browseId)
                let tracks = Array(detail.allTracks.prefix(trackLimit))
                guard !tracks.isEmpty else { continue }
                _ = store.create(title: playlist.title, tracks: tracks)
                imported += 1
            }
            message = "Playlists: \(playlists.count) on YouTube, \(imported) imported."
            NSLog("LWSYNC playlists remote=%d imported=%d", playlists.count, imported)
            return imported
        } catch {
            if let syncError = error as? YouTubeSyncError, syncError == .notSignedIn {
                disconnect()
                message = "The YouTube Music session expired — connect again."
                NSLog("LWSYNC session_dead -> disconnected")
            } else {
                message = "Playlist import failed: \(error.localizedDescription)"
            }
            NSLog("LWSYNC playlists_failed error=%@", String(describing: error))
            return 0
        }
    }

    /// Mirrors a like/unlike to the account.
    func pushLike(videoId: String, liked: Bool) {
        guard isConnected else { return }
        Task {
            guard let auth = await currentAuth() else { return }
            do {
                try await InnerTube.setLike(videoId: videoId, liked: liked, auth: auth)
                NSLog("LWSYNC like_pushed video=%@ liked=%@", videoId, liked ? "yes" : "no")
            } catch {
                NSLog("LWSYNC like_failed error=%@", String(describing: error))
            }
        }
    }
}
