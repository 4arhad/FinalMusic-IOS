import SwiftUI

// Home / Charts / New releases, mirroring the Android feed: a row of chips at
// the top and the shelves YouTube Music returns for the selected browse id.

struct HomeFeedView: View {
    @EnvironmentObject private var player: PlayerViewModel

    enum Source: String, CaseIterable, Identifiable {
        case home = "Home"
        case charts = "Charts"
        case newReleases = "New releases"

        var id: String { rawValue }

        var browseId: String {
            switch self {
            case .home: return "FEmusic_home"
            case .charts: return "FEmusic_charts"
            case .newReleases: return "FEmusic_new_releases"
            }
        }

        /// Launch-argument value for the -StartChip hook ("charts", "new releases"…).
        static func parse(_ name: String?) -> Source? {
            guard let name, !name.isEmpty else { return nil }
            return Source.allCases.first {
                $0.rawValue.lowercased().replacingOccurrences(of: " ", with: "") ==
                name.lowercased().replacingOccurrences(of: " ", with: "")
            } ?? Source.allCases.first { $0.rawValue.lowercased().hasPrefix(name.lowercased()) }
        }
    }

    @State private var source: Source
    @State private var shelves: [HomeShelf]
    @State private var isLoading: Bool
    @State private var errorText: String?

    init() {
        let parsed = Source.parse(UserDefaults.standard.string(forKey: "StartChip")) ?? .home
        _source = State(initialValue: parsed)
        let cached = HomeFeedCache.load(browseId: parsed.browseId)
        _shelves = State(initialValue: cached)
        _isLoading = State(initialValue: cached.isEmpty)
    }

    /// Entry point for the local algorithmic mix (ported from the Android
    /// client's For You feed; scored from on-device listening signal).
    private var forYouCard: some View {
        NavigationLink(value: Route.forYou) {
            HStack(spacing: 12) {
                Image(systemName: "wand.and.stars")
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 48, height: 48)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 2) {
                    Text("For You").font(.headline)
                    Text("Built from what you actually listen to")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal)
        }
        .buttonStyle(.plain)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                chips
                forYouCard
                if isLoading && shelves.isEmpty {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
                } else if let errorText, shelves.isEmpty {
                    ContentUnavailableView("Could not load the feed", systemImage: "wifi.exclamationmark",
                                           description: Text(errorText))
                        .frame(maxWidth: .infinity)
                } else {
                    ForEach(shelves) { shelf in
                        HomeShelfView(shelf: shelf)
                            .environmentObject(player)
                    }
                }
            }
            .padding(.vertical, 8)
        }
        .navigationTitle("Home")
        .refreshable { await load() }
        .task { await load() }
        .onChange(of: source) { _, newSource in
            let cached = HomeFeedCache.load(browseId: newSource.browseId)
            shelves = cached
            isLoading = cached.isEmpty
            Task { await load() }
        }
    }

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Source.allCases) { candidate in
                    Button {
                        source = candidate
                    } label: {
                        Text(candidate.rawValue)
                            .font(.subheadline)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(candidate == source ? AnyShapeStyle(Color.accentColor.opacity(0.18))
                                                            : AnyShapeStyle(.quaternary.opacity(0.5)),
                                        in: Capsule())
                            .foregroundStyle(candidate == source ? Color.accentColor : Color.primary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal)
        }
    }

    private func load() async {
        // A refresh never empties the screen: pull-to-refresh.s Task is
        // cancelled whenever the refresh control idles (or the user scrolls
        // away), and wiping shelves first turned that routine cancellation
        // into a permanent "Could not load the feed / cancelled" over what
        // used to be a working screen. Content is replaced only on success.
        if shelves.isEmpty { isLoading = true }
        errorText = nil
        do {
            var loaded = try await InnerTube.browseShelves(source.browseId)
            if source == .charts, !loaded.contains(where: \.hasPlayableTracks) {
                // Charts serves "Top artists" and "Video charts" to anonymous
                // clients; the songs chart row list comes back empty (it is a
                // signed-in surface now). Fill the tab with the home feed's own
                // trending shelf so the chip still leads to music.
                let home = try await InnerTube.browseShelves("FEmusic_home")
                if let trending = home.first(where: { $0.title.lowercased().contains("trend") || $0.hasPlayableTracks }) {
                    loaded.insert(trending, at: 0)
                }
            }
            guard !Task.isCancelled else { return }
            if !loaded.isEmpty {
                HomeFeedCache.save(loaded, browseId: source.browseId)
                // The port's take on Android's history-led shelf: "Quick picks"
                // becomes the last-played music whenever the device has
                // listening history (the Android feed leads it with Room
                // history + recent-song signals too). Fresh installs keep
                // YouTube's own picks. The cache stores the raw feed; this
                // synthesis re-runs after every load.
                var displayed = loaded
                if source == .home, !HistoryStore.shared.tracks.isEmpty,
                   let idx = displayed.firstIndex(where: { $0.title.lowercased().hasPrefix("quick pick") }) {
                    displayed[idx] = HomeShelf(title: "Quick picks",
                                               items: HistoryStore.shared.tracks.prefix(20).map { HomeItem.track($0) })
                }
                shelves = displayed
                // Warm the first rows of every shelf at their rendered size so
                // scrolling the feed is a cache hit from the first frame.
                let urls = displayed.flatMap { shelf in
                    shelf.items.prefix(6).map { item -> String? in
                        switch item {
                        case .track(let track): return track.artwork
                        case .collection(let entity): return entity.artwork
                        }
                    }
                }
                let rowSize = artworkMaxPixel(displaySize: 48)
                Task { await ArtworkCache.shared.prefetch(urls, maxPixel: rowSize) }
            } else if shelves.isEmpty {
                errorText = "This feed returned no shelves."
            }
            NSLog("LWHOME %@ -> %@", source.browseId,
                  loaded.map { "\($0.title)[\($0.items.count) tracks:\($0.hasPlayableTracks)]" }
                      .joined(separator: " | "))
        } catch {
            // A cancelled request is not an error the user should see: it
            // means the refresh control idled or the chip switched — the
            // successor load publishes when it finishes.
            if !Task.isCancelled, shelves.isEmpty {
                errorText = error.localizedDescription
            }
        }
        isLoading = false
    }
}

/// Horizontal carousel of cards — what the Android feed calls the section cards.
struct HomeShelfView: View {
    let shelf: HomeShelf
    @EnvironmentObject private var player: PlayerViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(shelf.title).font(.headline)
                Spacer()
                let tracks = shelf.items.compactMap { item -> MusicTrack? in
                    if case .track(let t) = item { return t } else { return nil }
                }
                if !tracks.isEmpty {
                    Button("Play all") { player.playQueue(tracks, startingAt: 0) }
                        .font(.caption)
                }
            }
            .padding(.horizontal)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(shelf.items) { item in
                        switch item {
                        case .track(let track):
                            Button {
                                let tracks = shelf.items.compactMap { element -> MusicTrack? in
                                    if case .track(let t) = element { return t } else { return nil }
                                }
                                let index = tracks.firstIndex(of: track) ?? 0
                                player.playQueue(tracks, startingAt: index)
                            } label: {
                                Card(title: track.title, subtitle: track.artist, artwork: track.artwork)
                            }
                            .buttonStyle(.plain)
                        case .collection(let entity):
                            NavigationLink(value: Route.collection(entity.browseId)) {
                                Card(title: entity.title, subtitle: entity.subtitle, artwork: entity.artwork)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.horizontal)
            }
        }
    }
}

struct Card: View {
    let title: String
    let subtitle: String
    let artwork: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Artwork(url: artwork, size: 150)
            Text(title)
                .font(.subheadline)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
        }
        .frame(width: 150, alignment: .leading)
    }
}
