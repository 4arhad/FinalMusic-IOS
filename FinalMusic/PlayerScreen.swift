import SwiftUI

@MainActor
final class LyricsModel: ObservableObject {
    @Published var lines: [TimedLyricLine] = []
    @Published var isLoading = false

    func load(artist: String, title: String) async {
        isLoading = true
        defer { isLoading = false }
        lines = []
        let source = try? await LRCLIBClient().fetchSyncedLyrics(artist: artist, title: title)
        if let source {
            lines = SyncedLyricsParser.parse(source)
        }
    }
}

struct PlayerScreen: View {
    @EnvironmentObject var player: PlayerViewModel
    @EnvironmentObject var lastfm: LastfmAuthStore
    @EnvironmentObject var liked: LikedStore
    @EnvironmentObject var playlists: PlaylistStore
    @StateObject private var lyrics = LyricsModel()
    @State private var showQueue = false
    @State private var showAddToPlaylist = false

    var body: some View {
        VStack(spacing: 14) {
            Artwork(url: player.currentTrack?.artwork, size: 250)
                .shadow(radius: 8)

            VStack(spacing: 4) {
                Text(player.currentTrack?.title ?? "—")
                    .font(.title3).fontWeight(.semibold)
                    .lineLimit(2).multilineTextAlignment(.center)
                Text(player.currentTrack.map { "\($0.artist)\($0.album.map { " • \($0)" } ?? "")" } ?? "")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal)

            LyricsView(lyrics: lyrics)
                .frame(maxHeight: .infinity)

            if player.duration > 0 {
                VStack(spacing: 2) {
                    Slider(
                        value: Binding(
                            get: { player.currentTime },
                            set: { player.currentTime = $0 }
                        ),
                        in: 0...max(player.duration, 0.01),
                        label: { Text("Position") },
                        minimumValueLabel: {
                            Text(time(player.currentTime)).font(.caption2).monospacedDigit()
                        },
                        maximumValueLabel: {
                            Text(time(player.duration)).font(.caption2).monospacedDigit()
                        }
                    ) { editing in
                        if !editing { player.seek(to: player.currentTime) }
                    }
                    .disabled(player.buffering)
                }
                .padding(.horizontal)
            }

            if let error = player.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
                    .padding(.horizontal)
            }

            HStack(spacing: 16) {
                Button { player.toggleShuffle() } label: {
                    Image(systemName: "shuffle")
                        .foregroundStyle(player.shuffle ? Color.accentColor : Color.secondary)
                }
                .accessibilityLabel("Shuffle")

                Spacer()
                Button { player.previous() } label: {
                    Image(systemName: "backward.fill").font(.title2)
                }
                Button {
                    player.togglePlayPause()
                } label: {
                    if player.buffering {
                        ProgressView().controlSize(.large)
                    } else {
                        Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 60))
                    }
                }
                Button { player.next() } label: {
                    Image(systemName: "forward.fill").font(.title2)
                }
                Spacer()
                Button { player.toggleRepeat() } label: {
                    Image(systemName: "repeat")
                        .foregroundStyle(player.repeatAll ? Color.accentColor : Color.secondary)
                }
                .accessibilityLabel("Repeat")
            }
            .padding(.horizontal)

            HStack(spacing: 26) {
                Button {
                    player.toggleLoveCurrentTrack()
                } label: {
                    Image(systemName: player.loved ? "heart.fill" : "heart")
                        .foregroundStyle(player.loved ? .red : .secondary)
                }
                .accessibilityLabel("Love track")

                Button {
                    showAddToPlaylist = true
                } label: {
                    Image(systemName: "text.badge.plus")
                }
                .accessibilityLabel("Add to playlist")

                Button {
                    if let track = player.currentTrack {
                        Task { await player.startRadio(seed: track) }
                    }
                } label: {
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .foregroundStyle(player.isRadio ? Color.accentColor : Color.secondary)
                }
                .accessibilityLabel("Start remix")

                if lastfm.isConnected {
                    Text("Scrobbling as \(lastfm.username)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.bottom, 8)
        }
        .navigationTitle(player.isRadio ? "Remix radio" : "Now Playing")
        .navigationBarTitleDisplayMode(.inline)
        // Pushed views lose the tab bar in iOS 26 unless it is asked for — the
        // player is a layer above the tab's content, not a takeover.
        .toolbar(.visible, for: .tabBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showQueue = true } label: {
                    Image(systemName: "list.dash")
                }
                .accessibilityLabel("Queue")
            }
        }
        .sheet(isPresented: $showQueue) {
            QueueSheet()
                .environmentObject(player)
        }
        .sheet(isPresented: $showAddToPlaylist) {
            if let track = player.currentTrack {
                AddToPlaylistSheet(track: track)
                    .environmentObject(playlists)
            }
        }
        .task(id: player.currentTrack?.videoId) {
            if let track = player.currentTrack {
                await lyrics.load(artist: track.artist, title: track.title)
            }
        }
    }

    private func time(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        return "\(total / 60):\(String(format: "%02d", total % 60))"
    }
}

struct LyricsView: View {
    @ObservedObject var lyrics: LyricsModel
    @EnvironmentObject var player: PlayerViewModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                VStack(spacing: 14) {
                    if lyrics.isLoading {
                        Text("Loading lyrics…")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else if lyrics.lines.isEmpty {
                        Text(player.currentTrack == nil
                             ? "Nothing playing"
                             : "No synced lyrics found")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    } else {
                        let active = SyncedLyricsParser.activeLineIndex(
                            in: lyrics.lines, at: player.currentTime
                        )
                        ForEach(Array(lyrics.lines.enumerated()), id: \.element.id) { index, line in
                            Text(line.text)
                                .font(.system(size: index == active ? 24 : 18, weight: index == active ? .bold : .regular))
                                .foregroundStyle(index == active ? AnyShapeStyle(.primary) : AnyShapeStyle(Color.secondary.opacity(0.7)))
                                .multilineTextAlignment(.center)
                                .padding(.horizontal)
                                .id(index)
                        }
                    }
                }
                .padding(.vertical, 40)
            }
            .onChange(of: player.currentTime) { _, newValue in
                guard let active = SyncedLyricsParser.activeLineIndex(in: lyrics.lines, at: newValue) else { return }
                withAnimation(.spring(duration: 0.45)) {
                    proxy.scrollTo(active, anchor: .center)
                }
            }
        }
    }
}

struct QueueSheet: View {
    @EnvironmentObject var player: PlayerViewModel

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(Array(player.queue.enumerated()), id: \.element.videoId) { index, track in
                        Button {
                            player.playQueue(player.queue, startingAt: index)
                        } label: {
                            HStack {
                                if track.videoId == player.currentTrack?.videoId {
                                    Image(systemName: "speaker.wave.2.fill")
                                        .foregroundStyle(.tint)
                                }
                                VStack(alignment: .leading) {
                                    Text(track.title).lineLimit(1)
                                    Text(track.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                        }
                        // The currently playing item is loaded into AVPlayer
                        // already — removing it would need a fresh load, so
                        // the row is simply not offered a Remove action.
                        .swipeActions(edge: .trailing) {
                            if track.videoId != player.currentTrack?.videoId {
                                Button(role: .destructive) {
                                    player.removeFromQueue(atOffsets: IndexSet(integer: index))
                                } label: { Text("Remove") }
                            }
                        }
                    }
                    .onMove { source, destination in
                        player.moveQueue(fromOffsets: source, toOffset: destination)
                    }
                } header: {
                    Text(player.isRadio
                         ? "Remix queue • \(player.queue.count) songs (grows as it plays)"
                         : "Queue • \(player.queue.count) songs")
                }
            }
            .navigationTitle("Queue")
            .toolbar {
                EditButton()
                    .accessibilityLabel("Reorder queue")
            }
        }
        .presentationDetents([.medium, .large])
    }
}
