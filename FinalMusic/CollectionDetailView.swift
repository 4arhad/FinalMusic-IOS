import SwiftUI

// Album / artist / playlist pages, plus the local-playlist branch of the
// navigation stack. One view covers all three remote kinds because the
// Android app's detail screens all reduce to the same shape: header + shelves.

enum Route: Hashable {
    case collection(String)      // browseId: MPREb… (album), UC… (artist), VL… (playlist)
    case localPlaylist(UUID)
    case library                 // liked songs
    case player                  // now-playing, pushed as a layer inside the tab
    case youtubeSync             // YouTube Music account sign-in / sync
    case forYou                  // local algorithmic mix (LocalTasteEngine)
}

/// One place that turns a Route into a screen, so every tab's NavigationStack
/// resolves the same destinations (Home used to declare none, which made every
/// collection card on Home and Charts a dead tap).
struct RouteDestination: View {
    let route: Route

    var body: some View {
        switch route {
        case .collection(let browseId):
            CollectionDetailView(browseId: browseId)
        case .localPlaylist(let id):
            LocalPlaylistView(playlistID: id)
        case .library:
            TrackListView(
                title: "Liked Songs",
                tracks: LikedStore.shared.tracks,
                emptyMessage: "Tap the heart on a song to save it here.",
                onRemove: { track in _ = LikedStore.shared.toggle(track) }
            )
        case .player:
            PlayerScreen()
        case .youtubeSync:
            YouTubeSyncView()
        case .forYou:
            ForYouView()
        }
    }
}

struct CollectionDetailView: View {
    let browseId: String

    @EnvironmentObject private var player: PlayerViewModel
    @State private var detail: CollectionDetail?
    @State private var isLoading = true
    @State private var errorText: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if isLoading {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 60)
                } else if let errorText {
                    ContentUnavailableView("Could not load this page", systemImage: "wifi.exclamationmark",
                                           description: Text(errorText))
                } else if let detail {
                    header(detail)
                    actions(detail)
                    ForEach(detail.shelves) { shelf in
                        CompactShelfView(shelf: shelf)
                            .environmentObject(player)
                    }
                }
            }
            .padding(.vertical, 12)
        }
        .navigationTitle(detail?.title ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .tabBar)
        .task { await load() }
    }

    @ViewBuilder
    private func header(_ detail: CollectionDetail) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Artwork(url: detail.artwork, size: 132)
                .shadow(radius: 6)
            VStack(alignment: .leading, spacing: 6) {
                Text(detail.title).font(.title3).fontWeight(.semibold).lineLimit(3)
                if !detail.subtitle.isEmpty {
                    Text(detail.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                }
                Text(detail.kind.rawValue.uppercased())
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal)
    }

    @ViewBuilder
    private func actions(_ detail: CollectionDetail) -> some View {
        let tracks = detail.allTracks
        HStack(spacing: 10) {
            if !tracks.isEmpty {
                Button {
                    player.playQueue(tracks, startingAt: 0)
                } label: {
                    Label("Play", systemImage: "play.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
            Button {
                player.playQueue(tracks.shuffled(), startingAt: 0)
            } label: {
                Label("Shuffle", systemImage: "shuffle").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(tracks.isEmpty)

            Button {
                if let playlistId = detail.radioPlaylistId {
                    Task { await player.startRadio(playlistId: playlistId) }
                } else if let seed = tracks.first {
                    Task { await player.startRadio(seed: seed) }
                }
            } label: {
                Label("Remix", systemImage: "dot.radiowaves.left.and.right").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(tracks.isEmpty && detail.radioPlaylistId == nil)
        }
        .padding(.horizontal)
    }

    private func load() async {
        isLoading = true
        errorText = nil
        do {
            let loaded = try await InnerTube.browseCollection(browseId)
            detail = loaded
            // Warm the artwork for what the user will see next; the rows
            // themselves read straight out of the cache afterwards. Rows
            // render at 48 pt and the header at 132 pt, so prefetch both
            // variants (the cache key includes the size).
            let rowURLs = loaded.allTracks.prefix(15).map(\.artwork)
            let headerURL = loaded.artwork
            Task {
                await ArtworkCache.shared.prefetch(rowURLs, maxPixel: artworkMaxPixel(displaySize: 48))
                await ArtworkCache.shared.prefetch([headerURL], maxPixel: artworkMaxPixel(displaySize: 132))
            }
        } catch {
            errorText = error.localizedDescription
        }
        isLoading = false
    }
}

/// A shelf rendered as a compact vertical list — used inside detail pages where
/// a horizontal carousel would hide most of the track list.
struct CompactShelfView: View {
    let shelf: HomeShelf
    @EnvironmentObject private var player: PlayerViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(shelf.title).font(.headline).padding(.horizontal)
                Spacer()
                let tracks = shelf.items.compactMap { item -> MusicTrack? in
                    if case .track(let t) = item { return t } else { return nil }
                }
                if !tracks.isEmpty {
                    Button("Play all") { player.playQueue(tracks, startingAt: 0) }
                        .font(.caption)
                        .padding(.trailing)
                }
            }
            ForEach(shelf.items) { item in
                switch item {
                case .track(let track):
                    TrackRow(track: track) {
                        let tracks = shelf.items.compactMap { element -> MusicTrack? in
                            if case .track(let t) = element { return t } else { return nil }
                        }
                        let index = tracks.firstIndex(of: track) ?? 0
                        player.playQueue(tracks, startingAt: index)
                    }
                case .collection(let entity):
                    NavigationLink(value: Route.collection(entity.browseId)) {
                        CollectionRow(entity: entity)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

struct CollectionRow: View {
    let entity: SearchEntity

    var body: some View {
        HStack(spacing: 10) {
            Artwork(url: entity.artwork, size: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text(entity.title).font(.body).lineLimit(2)
                Text(entity.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
        }
        .padding(.horizontal)
        .contentShape(Rectangle())
    }
}
