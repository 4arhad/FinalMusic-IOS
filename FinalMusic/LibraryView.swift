import SwiftUI

// Library: liked songs, user playlists, play history, and the entry point for
// connecting a YouTube Music account (browser sign-in) so the account's liked
// songs and playlists can be pulled in.

struct LibraryView: View {
    @EnvironmentObject private var player: PlayerViewModel
    @EnvironmentObject private var youtube: YouTubeAccount
    @EnvironmentObject private var liked: LikedStore
    @EnvironmentObject private var playlists: PlaylistStore
    @EnvironmentObject private var history: HistoryStore

    @State private var newPlaylistName = ""
    @State private var showNewPlaylist = false

    var body: some View {
        List {
            Section {
                NavigationLink(value: Route.library) {
                    HStack(spacing: 10) {
                        Image(systemName: "heart.fill")
                            .foregroundStyle(.red)
                            .frame(width: 48, height: 48)
                            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Liked Songs").font(.body)
                            Text("\(liked.tracks.count) songs").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Section("Playlists") {
                ForEach(playlists.playlists) { playlist in
                    NavigationLink(value: Route.localPlaylist(playlist.id)) {
                        HStack(spacing: 10) {
                            Artwork(url: playlist.artwork, size: 48)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(playlist.title).lineLimit(1)
                                Text("\(playlist.tracks.count) songs").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Button {
                    showNewPlaylist = true
                } label: {
                    Label("New playlist", systemImage: "plus.circle")
                }
            }

            Section {
                NavigationLink(value: Route.forYou) {
                    HStack(spacing: 10) {
                        Image(systemName: "wand.and.stars")
                            .font(.title2)
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 48, height: 48)
                            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("For You")
                            Text("Local mix from your listening history")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }

                NavigationLink(value: Route.youtubeSync) {
                    HStack(spacing: 10) {
                        Image(systemName: youtube.isConnected ? "person.crop.circle.badge.checkmark" : "person.crop.circle.badge.plus")
                            .font(.title2)
                            .foregroundStyle(youtube.isConnected ? Color.green : Color.accentColor)
                            .frame(width: 48, height: 48)
                            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("YouTube Music")
                            Text(youtube.accountName.map { "Signed in as \($0)" } ?? "Tap to connect your account")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }

            if !history.tracks.isEmpty {
                Section("Recently played") {
                    ForEach(history.tracks.prefix(20)) { track in
                        TrackRow(track: track) {
                            player.playQueue(Array(history.tracks.prefix(20)),
                                             startingAt: history.tracks.firstIndex(of: track) ?? 0)
                        }
                    }
                }
            }
        }
        .navigationTitle("Library")
        // The stack (and its Route destinations) lives in ContentView so the
        // player can be pushed inside this tab.
        .alert("New playlist", isPresented: $showNewPlaylist) {
            TextField("Name", text: $newPlaylistName)
            Button("Create") {
                let name = newPlaylistName.trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty { _ = playlists.create(title: name) }
                newPlaylistName = ""
            }
            Button("Cancel", role: .cancel) { newPlaylistName = "" }
        }
    }
}

struct LocalPlaylistView: View {
    let playlistID: UUID

    @EnvironmentObject private var player: PlayerViewModel
    @EnvironmentObject private var playlists: PlaylistStore
    @State private var showRename = false
    @State private var draftName = ""
    @State private var renaming = false

    private var playlist: Playlist? { playlists.playlist(playlistID) }

    var body: some View {
        let tracks = playlist?.tracks ?? []
        VStack(spacing: 0) {
            if tracks.isEmpty {
                ContentUnavailableView("No songs yet", systemImage: "music.note.list",
                                       description: Text("Use “Add to playlist” from any song."))
                Spacer()
            } else {
                HStack(spacing: 10) {
                    Button {
                        player.playQueue(tracks, startingAt: 0)
                    } label: { Label("Play", systemImage: "play.fill").frame(maxWidth: .infinity) }
                        .buttonStyle(.borderedProminent)
                    Button {
                        player.playQueue(tracks.shuffled(), startingAt: 0)
                    } label: { Label("Shuffle", systemImage: "shuffle").frame(maxWidth: .infinity) }
                        .buttonStyle(.bordered)
                    Button {
                        if let seed = tracks.first { Task { await player.startRadio(seed: seed) } }
                    } label: { Label("Remix", systemImage: "dot.radiowaves.left.and.right").frame(maxWidth: .infinity) }
                        .buttonStyle(.bordered)
                }
                .padding(.horizontal)
                .padding(.bottom, 8)

                List(tracks) { track in
                    TrackRow(
                        track: track,
                        onPlay: { player.playQueue(tracks, startingAt: tracks.firstIndex(of: track) ?? 0) },
                        onRemove: { playlists.remove(videoId: track.videoId, from: playlistID) }
                    )
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle(playlist?.title ?? "Playlist")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Menu {
                Button("Rename") {
                    draftName = playlist?.title ?? ""
                    showRename = true
                }
                Button("Delete playlist", role: .destructive) {
                    playlists.delete(playlistID)
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
        .alert("Rename playlist", isPresented: $showRename) {
            TextField("Name", text: $draftName)
            Button("Save") { playlists.rename(playlistID, to: draftName) }
            Button("Cancel", role: .cancel) {}
        }
    }
}

/// Generic track list with the shared context menu (remix / like / playlists).
struct TrackListView: View {
    let title: String
    let tracks: [MusicTrack]
    var emptyMessage: String = "No songs yet."
    var onRemove: ((MusicTrack) -> Void)?

    @EnvironmentObject private var player: PlayerViewModel

    var body: some View {
        Group {
            if tracks.isEmpty {
                ContentUnavailableView(title, systemImage: "music.note", description: Text(emptyMessage))
            } else {
                List(tracks) { track in
                    TrackRow(
                        track: track,
                        onPlay: { player.playQueue(tracks, startingAt: tracks.firstIndex(of: track) ?? 0) },
                        onRemove: onRemove.map { handler in { handler(track) } }
                    )
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Add-to-playlist picker used by the track context menus.
struct AddToPlaylistSheet: View {
    let track: MusicTrack

    @EnvironmentObject private var playlists: PlaylistStore
    @Environment(\.dismiss) private var dismiss
    @State private var newName = ""
    @State private var creating = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(playlists.playlists) { playlist in
                        Button {
                            playlists.add(track, to: playlist.id)
                            dismiss()
                        } label: {
                            HStack {
                                Text(playlist.title)
                                Spacer()
                                Text("\(playlist.tracks.count)").foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Section {
                    if creating {
                        HStack {
                            TextField("Playlist name", text: $newName)
                            Button("Add") {
                                let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
                                guard !name.isEmpty else { return }
                                let playlist = playlists.create(title: name)
                                playlists.add(track, to: playlist.id)
                                dismiss()
                            }
                        }
                    } else {
                        Button {
                            creating = true
                        } label: {
                            Label("New playlist", systemImage: "plus.circle")
                        }
                    }
                }
            }
            .navigationTitle("Add to playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
