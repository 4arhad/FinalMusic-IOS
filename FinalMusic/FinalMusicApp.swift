import SwiftUI
import AVKit

@main
struct FinalMusicApp: App {
    @StateObject private var player = PlayerViewModel()
    @StateObject private var lastfm = LastfmAuthStore()
    @StateObject private var liked = LikedStore.shared
    @StateObject private var playlists = PlaylistStore.shared
    @StateObject private var history = HistoryStore.shared
    @StateObject private var youtube = YouTubeAccount.shared

    init() {
        // Configure generous URLCache for image thumbnails and network responses (50 MB memory, 200 MB disk)
        let cache = URLCache(memoryCapacity: 50 * 1024 * 1024, diskCapacity: 200 * 1024 * 1024)
        URLCache.shared = cache
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(player)
                .environmentObject(lastfm)
                .environmentObject(liked)
                .environmentObject(playlists)
                .environmentObject(history)
                .environmentObject(youtube)
                .onChange(of: lastfm.client) { _, newClient in
                    player.attachScrobbler(newClient)
                }
        }
    }
}

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject var player: PlayerViewModel
    @EnvironmentObject var lastfm: LastfmAuthStore
    @EnvironmentObject var youtube: YouTubeAccount

    @State private var selection: Int = {
        switch UserDefaults.standard.string(forKey: "StartTab")?.lowercased() {
        case "search": return 1
        case "library": return 2
        case "settings": return 3
        default: return 0
        }
    }()

    /// One navigation path per tab. The player is pushed as *a layer inside the
    /// tab you are already in*, so the tab bar stays visible and the chevron
    /// pops back to whatever was underneath (full-screen cover hid it before).
    @State private var paths: [NavigationPath] = [NavigationPath(), NavigationPath(),
                                                  NavigationPath(), NavigationPath()]

    private func pathBinding(_ index: Int) -> Binding<NavigationPath> {
        Binding(get: { paths[index] }, set: { paths[index] = $0 })
    }

    private func openPlayer() {
        paths[selection].append(Route.player)
        NSLog("LWNAV openPlayer tab=%d depth=%d", selection, paths[selection].count)
    }

    var body: some View {
        TabView(selection: $selection) {
            NavigationStack(path: pathBinding(0)) {
                // -ForYouRoot makes the local mix the Home tab's root, which is
                // how the screen is screenshotted headlessly.
                tabContent {
                    if UserDefaults.standard.bool(forKey: "ForYouRoot") {
                        ForYouView()
                    } else {
                        HomeFeedView()
                    }
                }
            }
            .tabItem { Label("Home", systemImage: "house") }
            .tag(0)

            NavigationStack(path: pathBinding(1)) {
                tabContent {
                    SearchView(initialQuery: UserDefaults.standard.string(forKey: "AutoSearchQuery") ?? "",
                               autoOpenFirst: UserDefaults.standard.bool(forKey: "AutoOpenFirstEntity"),
                               initialKind: EntityKind.parse(UserDefaults.standard.string(forKey: "AutoSearchKind")),
                               onGoHome: { selection = 0 },
                               path: pathBinding(1))
                }
            }
            .tabItem { Label("Search", systemImage: "magnifyingglass") }
            .tag(1)

            NavigationStack(path: pathBinding(2)) {
                tabContent { LibraryView() }
            }
            .tabItem { Label("Library", systemImage: "music.note.list") }
            .tag(2)

            NavigationStack(path: pathBinding(3)) {
                SettingsView()
            }
            .tabItem { Label("Settings", systemImage: "gear") }
            .tag(3)
        }
        .task { runLaunchHooks() }
        .onChange(of: scenePhase) { _, phase in
            // Book the last partial chunk of listened time before the app is
            // suspended or killed; nothing else flushes it.
            if phase != .active { player.flushPendingPlayStats() }
        }
        .onOpenURL { url in
            if url.scheme == "lastwave", url.host == "play",
               let videoId = url.pathComponents.dropFirst().first {
                Task {
                    await player.play(videoId: videoId)
                    openPlayer()
                }
                return
            }
            guard url.scheme == "lastwave",
                  url.host == "lastfm",
                  let token = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                      .queryItems?.first(where: { $0.name == "token" })?.value
            else { return }
            Task { await lastfm.handleCallback(token: token) }
        }
    }

    /// Shared tab plumbing. The mini player is an inset of the *tab's content*,
    /// not of the TabView: an inset on the TabView lands where the tab bar
    /// lives and hides it (iOS 26's floating bar), and it also appeared under
    /// the pushed player screen.
    @ViewBuilder
    private func tabContent<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .safeAreaInset(edge: .bottom) {
                if player.currentTrack != nil {
                    MiniPlayer(onOpen: openPlayer)
                }
            }
            .navigationDestination(for: Route.self) { route in
                // Pushed pages keep the mini player too (a playing track must
                // stay reachable from a collection page), except the player
                // itself, which would inset under its own screen.
                RouteDestination(route: route).environmentObject(player)
                    .safeAreaInset(edge: .bottom) {
                        if route != .player, player.currentTrack != nil {
                            MiniPlayer(onOpen: openPlayer)
                        }
                    }
            }
    }

    /// Headless-test hooks, set as launch arguments (they land in UserDefaults'
    /// argument domain, e.g. `xcrun simctl launch <udid> <bundle> -StartTab search`):
    ///   -StartTab home|search|library|settings   preselect a tab
    ///   -StartChip home|charts|new releases      which feed chip to open
    ///   -AutoSearchQuery "daft punk"             run a search on launch
    ///   -AutoSearchKind song|album|artist|…      which filter to use
    ///   -AutoOpenFirstEntity 1                   open the first hit of that filter
    ///   -AutoOpenCollection <browseId>           push a page on the Home stack
    ///   -AutoPlayCollection <browseId>           play a page's whole track list
    ///   -AutoSkipAfter <seconds>                 advance the queue after N seconds
    ///   -AutoPlayVideoId <id>                    play one track and open the player
    ///   -StartRadioVideoId <id>                  start a remix/radio
    ///   -AutoLikeVideoId <id>                    play, then like the track
    ///   -AutoConnectCookies "<header>"           try a YouTube cookie sign-in
    ///   -AutoConnectBrowser 1                     browser sign-in (device code)
    ///   -AutoSyncYouTube 1                        pull liked songs + playlists
    ///   -ExpireYouTubeToken 1                     force an OAuth refresh
    ///   -SuppressBrowserOpen 1                    keep the browser closed (test)
    ///   -AutoForYou 1                             build the local For You mix
    ///   -SeedPlayStats 1                          synthetic play stats for tests
    ///   -AutoOpenForYou 1                         push the For You screen
    ///   -ClearPlayStats 1 / -DumpPlayStats 1      reset / print play stats
    ///   -RapidSkipTest 1                          3 quick next() calls at 10 s
    ///   -SeedPlaylist "Name"                     create a playlist from history
    private func runLaunchHooks() {
        player.attachScrobbler(lastfm.client)
        if youtube.isConnected, youtube.autoSyncLiked {
            // Keeps the local library in step with the account without waiting
            // for the user to open Settings.
            Task { await youtube.syncLikedSongs(into: LikedStore.shared) }
        }
        let defaults = UserDefaults.standard
        if let videoId = defaults.string(forKey: "AutoPlayVideoId"), !videoId.isEmpty {
            Task {
                await player.play(videoId: videoId)
                openPlayer()
                // -AutoSkipAfter also works here, so the skip/play-time recording
                // path can be exercised without loading a whole collection.
                let skip = (defaults.object(forKey: "AutoSkipAfter") as? Int)
                    ?? Int(defaults.string(forKey: "AutoSkipAfter") ?? "") ?? 0
                if skip > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(skip) * 1_000_000_000)
                    player.next()
                }
            }
        }
        if let videoId = defaults.string(forKey: "StartRadioVideoId"), !videoId.isEmpty {
            Task {
                await player.startRadio(videoId: videoId)
                openPlayer()
                let skip = (defaults.object(forKey: "AutoSkipAfter") as? Int)
                    ?? Int(defaults.string(forKey: "AutoSkipAfter") ?? "") ?? 0
                if skip > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(skip) * 1_000_000_000)
                    player.next()
                }
            }
        }
        if defaults.bool(forKey: "AutoQueueMutate") {
            // Drives the queue sheet's reorder/remove code paths headlessly:
            // after the radio queue builds, move the last entry to slot 1 and
            // remove the old slot 2, logging the resulting order and which
            // track stays current.
            Task {
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                guard let cur = player.currentIndex else { return }
                let before = player.queue.map(\.videoId)
                player.moveQueue(fromOffsets: IndexSet(integer: before.count - 1), toOffset: 1)
                let moved = player.queue.map(\.videoId)
                let removable = moved.firstIndex { $0 != player.currentTrack?.videoId && $0 != moved.first }
                if let r = removable, r != cur {
                    player.removeFromQueue(atOffsets: IndexSet(integer: r))
                }
                NSLog("LWQUEUE mutate before=%d moved=%d after=%d current=%@ indexNow=%d",
                      before.count, moved.count, player.queue.count,
                      player.currentTrack?.videoId ?? "-", player.currentIndex ?? -1)
            }
        }
        if let videoId = defaults.string(forKey: "AutoLikeVideoId"), !videoId.isEmpty {
            Task {
                await player.play(videoId: videoId)
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                player.toggleLoveCurrentTrack()
            }
        }
        if let name = defaults.string(forKey: "SeedPlaylist"), !name.isEmpty {
            Task {
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                let seeds = Array(HistoryStore.shared.tracks.prefix(3))
                guard !seeds.isEmpty else { return }
                _ = PlaylistStore.shared.create(title: name, tracks: seeds)
            }
        }
        if let browseId = defaults.string(forKey: "AutoOpenCollection"), !browseId.isEmpty {
            // Push after the stack has appeared: a path appended during the
            // first body pass can be reset by the tab shell's initial render.
            Task {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                paths[0].append(Route.collection(browseId))
            }
        }
        if let cookies = defaults.string(forKey: "AutoConnectCookies"), !cookies.isEmpty {
            // Exercises the account sign-in path end to end (used to check that
            // bad cookies are rejected rather than silently accepted).
            Task { await YouTubeAccount.shared.connect(rawCookies: cookies) }
        }
        if defaults.bool(forKey: "RapidSkipTest") {
            // Three near-simultaneous next() calls: only the last resolve may
            // win the player (guards the load-sequencing fix).
            Task {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                player.next()
                try? await Task.sleep(nanoseconds: 80_000_000)
                player.next()
                try? await Task.sleep(nanoseconds: 80_000_000)
                player.next()
            }
        }
        if defaults.bool(forKey: "ClearPlayStats") {
            PlayStatsStore.shared.clear()
            NSLog("LFY stats_cleared")
        }
        if defaults.bool(forKey: "DumpPlayStats") {
            Task {
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                let stats = PlayStatsStore.shared.stats
                NSLog("LFY stats_total=%d", stats.count)
                for entry in stats.prefix(5) {
                    NSLog("LFY stat key=%@ plays=%d skips=%d ms=%.0f", entry.key,
                          entry.plays, entry.skips, entry.playTimeMs)
                }
            }
        }
        if defaults.bool(forKey: "AutoForYou") {
            Task {
                let outcome = await LocalTasteEngine.build()
                NSLog("LFY built picks=%d seeds=%d fallback=%@ summary=%@",
                      outcome.tracks.count, outcome.seeds.count,
                      outcome.usedLikedFallback ? "yes" : "no", outcome.summary)
            }
        }
        if defaults.bool(forKey: "AutoOpenForYou") {
            paths[0].append(Route.forYou)
        }
        if defaults.bool(forKey: "SeedPlayStats") {
            // Deterministic listening history so the engine can be exercised
            // headlessly (same idea as -SeedPlaylist).
            PlayStatsStore.shared.seedForTesting(LaunchSeed.playStats())
            NSLog("LFY stats_seeded")
        }
        if defaults.bool(forKey: "AutoConnectBrowser") {
            Task { await YouTubeAccount.shared.connectWithBrowser() }
        }
        if defaults.bool(forKey: "AutoSyncYouTube") {
            Task {
                await YouTubeAccount.shared.syncLikedSongs(into: LikedStore.shared)
                await YouTubeAccount.shared.importPlaylists(into: PlaylistStore.shared)
            }
        }
        if defaults.bool(forKey: "ExpireYouTubeToken") {
            YouTubeAccount.shared.expireTokenForTesting()
        }
        if defaults.bool(forKey: "ConnectTwiceTest") {
            // Two Connect attempts 3 s apart must share ONE device code
            // (the "already redeemed" guard).
            Task {
                await YouTubeAccount.shared.connectWithBrowser()
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                await YouTubeAccount.shared.connectWithBrowser()
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                await YouTubeAccount.shared.getNewCode()
            }
        }
        if defaults.bool(forKey: "AutoKeychainSelfTest") {
            // Proves the credential actually persists (a silent Keychain failure
            // would lose the sign-in on the next launch).
            let probe = "SID=probe; SAPISID=\(UUID().uuidString)"
            YouTubeKeychain.saveCookieHeader(probe)
            let loaded = YouTubeKeychain.loadCookieHeader()
            NSLog("LWKEYCHAIN status=%d fallback=%@ loaded=%@ matches=%@",
                  YouTubeKeychain.lastStatus, YouTubeKeychain.usedFallback ? "yes" : "no",
                  loaded == nil ? "nil" : "yes", loaded == probe ? "yes" : "no")
            YouTubeKeychain.clearCookieHeader()
            NSLog("LWKEYCHAIN after clear=%@", YouTubeKeychain.loadCookieHeader() == nil ? "empty" : "still-there")
        }
        if let browseId = defaults.string(forKey: "AutoPlayCollection"), !browseId.isEmpty {
            // Drives the list path headlessly: browse a page, then play its tracks
            // exactly like the Play button does.
            Task {
                do {
                    let detail = try await InnerTube.browseCollection(browseId)
                    let tracks = detail.allTracks
                    NSLog("LWAUTO collection %@ -> %d tracks", browseId, tracks.count)
                    guard !tracks.isEmpty else { return }
                    player.playQueue(tracks, startingAt: 0)
                    let skip = (defaults.object(forKey: "AutoSkipAfter") as? Int)
                        ?? Int(defaults.string(forKey: "AutoSkipAfter") ?? "") ?? 0
                    if skip > 0 {
                        try? await Task.sleep(nanoseconds: UInt64(skip) * 1_000_000_000)
                        player.next()   // exercises queue advance, like a track ending
                    }
                } catch {
                    NSLog("LWAUTO collection error %@", error.localizedDescription)
                }
            }
        }
    }
}

struct MiniPlayer: View {
    let onOpen: () -> Void
    @EnvironmentObject var player: PlayerViewModel

    var body: some View {
        HStack(spacing: 10) {
            Artwork(url: player.currentTrack?.artwork, size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(player.currentTrack?.title ?? "")
                    .font(.subheadline).lineLimit(1)
                HStack(spacing: 4) {
                    if player.isRadio {
                        Image(systemName: "dot.radiowaves.left.and.right").font(.caption2)
                    }
                    Text(player.currentTrack?.artist ?? "")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            Button {
                player.togglePlayPause()
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title3)
            }
            Button { player.next() } label: {
                Image(systemName: "forward.fill")
                    .font(.title3)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
        .onTapGesture { onOpen() }
    }
}

struct Artwork: View {
    let url: String?
    let size: CGFloat
    @State private var loaded: UIImage?

    var body: some View {
        Group {
            if let loaded {
                Image(uiImage: loaded).resizable().scaledToFill()
            } else {
                Color.gray.opacity(0.2)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        // task(id:) re-runs on URL/size change and cancels an in-flight load
        // for a row that scrolled away — the obsolete request never lands.
        .task(id: ArtworkKey(url: url, size: size)) {
            guard let url, !url.isEmpty else { loaded = nil; return }
            let image = await ArtworkCache.shared.image(url: url, maxPixel: artworkMaxPixel(displaySize: size))
            if image != nil { loaded = image }
        }
    }
}

/// .task(id:) payload: reload when either the URL or the render size changes.
private struct ArtworkKey: Hashable {
    let url: String?
    let size: CGFloat
}

/// ProMotion Retina sizing: 3x on every current iPhone; capped so a 48 pt row
/// never pulls a 1280 px original.
func artworkMaxPixel(displaySize: CGFloat) -> Int {
    min(Int((displaySize * 3).rounded(.up)), 800)
}

/// One song row with the shared context menu: play, remix/radio, like, add to
/// playlist — plus an optional Remove used inside liked songs and playlists.
struct TrackRow: View {
    let track: MusicTrack
    let onPlay: () -> Void
    var onRemove: (() -> Void)?

    @EnvironmentObject private var player: PlayerViewModel
    @EnvironmentObject private var liked: LikedStore
    @EnvironmentObject private var playlists: PlaylistStore
    @State private var showAddToPlaylist = false

    var body: some View {
        Button(action: onPlay) {
            HStack(spacing: 10) {
                Artwork(url: track.artwork, size: 48)
                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title).font(.body).lineLimit(1)
                    Text(track.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if player.currentTrack?.videoId == track.videoId {
                    Image(systemName: "speaker.wave.2.fill").font(.caption).foregroundStyle(.tint)
                }
                if let seconds = track.durationSeconds {
                    Text(format(seconds))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                player.playQueue([track], startingAt: 0)
            } label: {
                Label("Play now", systemImage: "play.fill")
            }
            Button {
                Task { await player.startRadio(videoId: track.videoId) }
            } label: {
                Label("Start radio", systemImage: "dot.radiowaves.left.and.right")
            }
            Button {
                liked.toggle(track)
            } label: {
                Label(liked.contains(track.videoId) ? "Unlike" : "Like",
                      systemImage: liked.contains(track.videoId) ? "heart.fill" : "heart")
            }
            Button {
                showAddToPlaylist = true
            } label: {
                Label("Add to playlist", systemImage: "text.badge.plus")
            }
            if let onRemove {
                Divider()
                Button(role: .destructive, action: onRemove) {
                    Label("Remove", systemImage: "trash")
                }
            }
        }
        .sheet(isPresented: $showAddToPlaylist) {
            AddToPlaylistSheet(track: track)
                .environmentObject(playlists)
        }
    }

    private func format(_ seconds: Int) -> String {
        let m = seconds / 60
        let s = seconds % 60
        return String(format: "%d:%02d", m, s)
    }
}
