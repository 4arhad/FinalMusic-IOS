import SwiftUI

/// "For You" — the local algorithmic mix. Built from real playback signal
/// (time listened, skips, likes, recency, time of day) and expanded through
/// YouTube Music's related songs. Ported from the Android client's
/// LocalTasteSuggestionEngine; no account required.
struct ForYouView: View {
    @EnvironmentObject private var player: PlayerViewModel
    @EnvironmentObject private var playlists: PlaylistStore

    @State private var tracks: [MusicTrack] = []
    @State private var status: String?
    @State private var isBuilding = false
    @State private var showSaveSheet = false
    @State private var playlistName = "For You"

    var body: some View {
        List {
            Section {
                Button {
                    Task { await build() }
                } label: {
                    Label(isBuilding ? "Building…" : "Build For You mix", systemImage: "wand.and.stars")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isBuilding)

                if let status {
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Text("Local taste mix")
            } footer: {
                Text("Scores what you actually listen to — time played, skips, likes, recency and time of day — then expands the strongest tracks through YouTube Music's related songs.")
            }

            if !tracks.isEmpty {
                Section {
                    Button {
                        player.playQueue(tracks, startingAt: 0)
                    } label: {
                        Label("Play \(tracks.count) picks", systemImage: "play.fill")
                    }
                    Button {
                        playlistName = defaultPlaylistName()
                        showSaveSheet = true
                    } label: {
                        Label("Save as playlist", systemImage: "square.and.arrow.down")
                    }
                }

                Section("Suggestions") {
                    ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                        TrackRow(track: track) {
                            player.playQueue(tracks, startingAt: index)
                        }
                    }
                }
            }
        }
        .navigationTitle("For You")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            // The -AutoForYou hook also builds on entry so the screen can be
            // verified headlessly (otherwise the mix is built on tap only).
            if UserDefaults.standard.bool(forKey: "AutoForYou"), tracks.isEmpty {
                await build()
            }
        }
        .sheet(isPresented: $showSaveSheet) {
            NavigationStack {
                Form {
                    TextField("Playlist name", text: $playlistName)
                    Button("Save") {
                        playlists.create(title: playlistName, tracks: tracks)
                        status = "Saved \(tracks.count) tracks to “\(playlistName)”."
                        showSaveSheet = false
                    }
                    .disabled(playlistName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .navigationTitle("Save playlist")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { showSaveSheet = false }
                    }
                }
            }
        }
    }

    private func defaultPlaylistName() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM"
        return "For You \(formatter.string(from: Date()))"
    }

    private func build() async {
        isBuilding = true
        defer { isBuilding = false }
        let started = Date()
        let outcome = await LocalTasteEngine.build()
        let elapsed = Int(Date().timeIntervalSince(started) * 1000)
        tracks = outcome.tracks
        status = outcome.summary + "  \(elapsed) ms"
        NSLog("LFY built picks=%d seeds=%d fallback=%@ ms=%d", outcome.tracks.count,
              outcome.seeds.count, outcome.usedLikedFallback ? "yes" : "no", elapsed)
    }
}
