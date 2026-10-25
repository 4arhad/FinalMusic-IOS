import Foundation
import Combine

@MainActor
final class HomeStore: ObservableObject {
    @Published var tracks: [MusicTrack] = []
    @Published var isLoading = false
    @Published var errorMessage: String?

    func load() async {
        guard tracks.isEmpty, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            tracks = try await InnerTube.browseHome()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func refresh() async {
        tracks = []
        await load()
    }
}

@MainActor
final class SearchStore: ObservableObject {
    @Published var query = ""
    @Published var results: [MusicTrack] = []
    @Published var isSearching = false
    @Published var errorMessage: String?

    func search() async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isSearching = true
        errorMessage = nil
        defer { isSearching = false }
        do {
            results = try await InnerTube.searchSongs(query: trimmed)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// Mirrors SettingsViewModel's BYO-key Last.fm integration state.
@MainActor
final class LastfmAuthStore: ObservableObject {
    @Published var apiKey = ""
    @Published var apiSecret = ""
    @Published var username = ""
    @Published var pendingToken: String?
    @Published var statusMessage: String?
    @Published var client: LastFmClient?

    private let defaults = UserDefaults.standard

    init() {
        apiKey = defaults.string(forKey: "lfm.apiKey") ?? ""
        apiSecret = defaults.string(forKey: "lfm.apiSecret") ?? ""
        username = defaults.string(forKey: "lfm.username") ?? ""
        rebuildClient()
    }

    var isConnected: Bool { !username.isEmpty && client?.session != nil }

    func save() {
        defaults.set(LastFmSigner.normalizeKey(apiKey), forKey: "lfm.apiKey")
        defaults.set(LastFmSigner.normalizeKey(apiSecret), forKey: "lfm.apiSecret")
        rebuildClient()
    }

    private func rebuildClient() {
        let sessionKey = defaults.string(forKey: "lfm.sessionKey")
        var session: LastFmSession?
        if let sessionKey, !sessionKey.isEmpty, !username.isEmpty {
            session = LastFmSession(username: username, sessionKey: sessionKey)
        }
        client = LastFmClient(apiKey: apiKey, apiSecret: apiSecret, session: session)
    }

    // Step 1 of the web-auth flow: mint a token, then open Last.fm's auth page.
    func startAuth() async -> URL? {
        save()
        guard let client, !client.apiKey.isEmpty else {
            statusMessage = "Enter your Last.fm API key first."
            return nil
        }
        do {
            let token = try await client.requestAuthToken()
            pendingToken = token
            statusMessage = "Authorize on Last.fm, then return to the app."
            return client.authURL()
        } catch {
            statusMessage = error.localizedDescription
            return nil
        }
    }

    // Step 2: the deep link hands the token back (cb= parameter) and we
    // exchange it for a session, exactly like completeWebAuth().
    func handleCallback(token: String) async {
        guard let client else { return }
        do {
            let name = try await client.completeWebAuth(token: token)
            username = name
            defaults.set(name, forKey: "lfm.username")
            if let sessionKey = client.session?.sessionKey {
                defaults.set(sessionKey, forKey: "lfm.sessionKey")
            }
            statusMessage = "Signed in as \(name)."
            pendingToken = nil
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func signOut() {
        username = ""
        defaults.removeObject(forKey: "lfm.username")
        defaults.removeObject(forKey: "lfm.sessionKey")
        rebuildClient()
        statusMessage = "Signed out."
    }
}
