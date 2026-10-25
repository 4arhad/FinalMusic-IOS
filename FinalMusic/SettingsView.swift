import SwiftUI
import SafariServices

struct SettingsView: View {
    @EnvironmentObject var lastfm: LastfmAuthStore
    @EnvironmentObject var youtube: YouTubeAccount
    @EnvironmentObject var liked: LikedStore
    @EnvironmentObject var playlists: PlaylistStore
    @State private var authURL: URL?
    @State private var showSafari = false
    var body: some View {
        Form {
            YouTubeSyncSection()

            Section("Last.fm") {
                LabeledContent("Status") {
                    Text(lastfm.isConnected
                         ? "Signed in as \(lastfm.username)"
                         : "Not connected")
                        .foregroundStyle(lastfm.isConnected ? .green : .secondary)
                }

                SecureField("API key", text: $lastfm.apiKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("API secret", text: $lastfm.apiSecret)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                if lastfm.isConnected {
                    Button("Sign out", role: .destructive) { lastfm.signOut() }
                } else {
                    Button {
                        Task {
                            authURL = await lastfm.startAuth()
                            showSafari = authURL != nil
                        }
                    } label: {
                        Text("Connect Last.fm")
                    }
                    .disabled(lastfm.apiKey.isEmpty || lastfm.apiSecret.isEmpty)
                }

                if let status = lastfm.statusMessage {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("About") {
                LabeledContent("Catalog", value: "YouTube Music (InnerTube)")
                LabeledContent("Lyrics", value: "LRCLIB, synced")
                LabeledContent("Scrobbler", value: "track.updateNowPlaying + track.scrobble")
                Text("LastWave for iOS is an independent port of the open-source LastWave Android client. Not affiliated with YouTube or Last.fm.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Section {
                Button("Save") { lastfm.save() }
            } footer: {
                Text("Bring your own keys: create them at last.fm/settings/appspot and paste the API key and shared secret above.")
            }
        }
        .navigationTitle("Settings")
        .sheet(isPresented: $showSafari) {
            if let authURL {
                LastFmAuthWebView(url: authURL)
                    .ignoresSafeArea()
            }
        }
    }
}


/// The YouTube Music account block, shared by Settings and the Library entry so
/// both places carry the same Connect / Sync / Sign out controls.
struct YouTubeSyncSection: View {
    @EnvironmentObject var youtube: YouTubeAccount
    @EnvironmentObject var liked: LikedStore
    @EnvironmentObject var playlists: PlaylistStore
    @State private var cookieInput = ""
    @State private var showCookieHelp = false

    var body: some View {
        Section {
            LabeledContent("Status") {
                switch youtube.status {
                case .connected(let name):
                    Text("Signed in as \(name)").foregroundStyle(.green)
                case .connecting:
                    Text("Starting browser sign-in…").foregroundStyle(.secondary)
                case .awaitingBrowser:
                    Text("Waiting for approval in the browser").foregroundStyle(.secondary)
                case .failed(let reason):
                    Text(reason).foregroundStyle(.orange)
                case .disconnected:
                    Text("Not connected").foregroundStyle(.secondary)
                }
            }

            if youtube.isConnected {
                if youtube.usingOAuth {
                    Text("Signed in through the browser (Google OAuth).")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Toggle("Sync liked songs at launch", isOn: $youtube.autoSyncLiked)

                Button {
                    Task { await youtube.syncLikedSongs(into: liked) }
                } label: {
                    Label("Sync liked songs now", systemImage: "heart.text.square")
                }
                .disabled(youtube.busy)

                Button {
                    Task { await youtube.importPlaylists(into: playlists) }
                } label: {
                    Label("Import my playlists", systemImage: "square.stack.3d.down.right")
                }
                .disabled(youtube.busy)

                Button("Sign out of YouTube Music", role: .destructive) {
                    youtube.disconnect()
                }
            } else {
                // Browser-first: Google blocks sign-in inside app web views, so the
                // account is verified in the real browser and the app picks up the
                // approved session by polling.
                Button {
                    Task { await youtube.connectWithBrowser() }
                } label: {
                    Label("Connect with YouTube", systemImage: "safari")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(youtube.status == .connecting)

                if let code = youtube.pendingUserCode {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Your browser is open — enter this code to verify the account:")
                            .font(.footnote)
                        Text(code)
                            .font(.system(.title2, design: .monospaced).weight(.semibold))
                            .textSelection(.enabled)
                        HStack(spacing: 12) {
                            Button("Open browser again") { youtube.reopenVerificationPage() }
                            Button("Get a new code") { Task { await youtube.getNewCode() } }
                            Button("Cancel") { youtube.cancelBrowserSignIn() }
                        }
                        .font(.footnote)
                        Text("The code is single-use and expires in about 30 minutes. Seeing \"User code already redeemed\" in the browser means an old code was entered — use the one shown above.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Waiting for approval…").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }

                DisclosureGroup("Sign in with a cookie header instead") {
                    SecureField("Cookie header", text: $cookieInput)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button {
                        let trimmed = cookieInput.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else {
                            youtube.message = "Paste the Cookie header from a signed-in browser first."
                            return
                        }
                        Task {
                            await youtube.connect(rawCookies: trimmed)
                            cookieInput = ""
                        }
                    } label: {
                        Label("Connect with cookies", systemImage: "person.badge.key")
                    }
                    Button("How do I get the cookies?") { showCookieHelp = true }
                        .font(.footnote)
                }

                if let message = youtube.message {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("YouTube Music sync")
        } footer: {
            Text("Verify your YouTube Music account in the browser to import liked songs and playlists and to mirror likes. \(YouTubeKeychain.storageDescription)")
        }
        .sheet(isPresented: $showCookieHelp) { CookieHelpView() }
    }
}

/// Pushable page with the same controls, reached from the Library.
struct YouTubeSyncView: View {
    var body: some View {
        Form { YouTubeSyncSection() }
            .navigationTitle("YouTube Music")
            .navigationBarTitleDisplayMode(.inline)
    }
}

/// Explains the cookie fallback. The primary path is the browser (button above):
/// Google blocks sign-in inside app web views, and SFSafariViewController
/// sessions cannot be read by the app by design, so the app verifies the account
/// through the device-code flow instead.
struct CookieHelpView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Browser sign-in (recommended)") {
                    Text("Tap Connect with YouTube: the browser opens at google.com/device, you approve the account there, and the app picks up the session automatically.")
                }
                Section("Cookie header (fallback)") {
                    Text("1. Sign in to music.youtube.com in Safari or Chrome on a computer.")
                    Text("2. Open Developer Tools → Network, reload the page, click any request to music.youtube.com.")
                    Text("3. Copy the whole value of its Cookie: request header (it starts with SID= or __Secure-3PAPISID=).")
                    Text("4. Paste it into the cookie field and press Connect. A JSON cookie export from a cookie extension works too.")
                }
                Section {
                    Text("Either credential is stored on this device only and sent solely to YouTube Music. Sign out to delete it.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Signing in")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

/// Safari view used for the Last.fm web-auth step (the app hands the user to
/// last.fm to approve access, then completes the token exchange).
struct LastFmAuthWebView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}
