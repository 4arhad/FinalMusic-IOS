import Foundation
import Combine

// Local library: liked songs, user playlists and play history. JSON in
// UserDefaults, mirroring LastWave's Room-free stores. Account playlists and
// likes arrive through the YouTube Music sync (browser sign-in), not here.

private let encoder = JSONEncoder()
private let decoder = JSONDecoder()

private func load<T: Decodable>(_ type: T.Type, key: String) -> T? {
    guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
    return try? decoder.decode(type, from: data)
}

private func save<T: Encodable>(_ value: T, key: String) {
    guard let data = try? encoder.encode(value) else { return }
    UserDefaults.standard.set(data, forKey: key)
}

@MainActor
final class LikedStore: ObservableObject {
    static let shared = LikedStore()
    private let key = "lastwave.likedSongs"

    @Published private(set) var tracks: [MusicTrack] = []

    init() { tracks = load([MusicTrack].self, key: key) ?? [] }

    func contains(_ videoId: String) -> Bool {
        tracks.contains { $0.videoId == videoId }
    }

    @discardableResult
    func toggle(_ track: MusicTrack) -> Bool {
        if let index = tracks.firstIndex(where: { $0.videoId == track.videoId }) {
            tracks.remove(at: index)
            save(tracks, key: key)
            return false
        }
        tracks.insert(track, at: 0)
        save(tracks, key: key)
        return true
    }

    func add(_ track: MusicTrack) {
        guard !contains(track.videoId) else { return }
        tracks.insert(track, at: 0)
        save(tracks, key: key)
    }

    func addBatch(_ newTracks: [MusicTrack]) {
        guard !newTracks.isEmpty else { return }
        var seen = Set(tracks.map(\.videoId))
        var added: [MusicTrack] = []
        for track in newTracks {
            if seen.insert(track.videoId).inserted {
                added.append(track)
            }
        }
        guard !added.isEmpty else { return }
        tracks.insert(contentsOf: added, at: 0)
        save(tracks, key: key)
    }
}

struct Playlist: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var title: String
    var tracks: [MusicTrack] = []

    var artwork: String? { tracks.first?.artwork }
}

@MainActor
final class PlaylistStore: ObservableObject {
    static let shared = PlaylistStore()
    private let key = "lastwave.playlists"

    @Published private(set) var playlists: [Playlist] = []

    init() { playlists = load([Playlist].self, key: key) ?? [] }

    @discardableResult
    func create(title: String, tracks: [MusicTrack] = []) -> Playlist {
        let playlist = Playlist(title: title.trimmingCharacters(in: .whitespacesAndNewlines), tracks: tracks)
        playlists.append(playlist)
        persist()
        return playlist
    }

    func rename(_ id: UUID, to title: String) {
        guard let index = playlists.firstIndex(where: { $0.id == id }) else { return }
        playlists[index].title = title
        persist()
    }

    func delete(_ id: UUID) {
        playlists.removeAll { $0.id == id }
        persist()
    }

    func add(_ track: MusicTrack, to id: UUID) {
        guard let index = playlists.firstIndex(where: { $0.id == id }) else { return }
        guard !playlists[index].tracks.contains(where: { $0.videoId == track.videoId }) else { return }
        playlists[index].tracks.append(track)
        persist()
    }

    func remove(videoId: String, from id: UUID) {
        guard let index = playlists.firstIndex(where: { $0.id == id }) else { return }
        playlists[index].tracks.removeAll { $0.videoId == videoId }
        persist()
    }

    func playlist(_ id: UUID) -> Playlist? { playlists.first { $0.id == id } }

    private func persist() { save(playlists, key: key) }
}

@MainActor
final class HistoryStore: ObservableObject {
    static let shared = HistoryStore()
    private let key = "lastwave.history"
    private let limit = 100

    @Published private(set) var tracks: [MusicTrack] = []

    init() { tracks = load([MusicTrack].self, key: key) ?? [] }

    func record(_ track: MusicTrack) {
        tracks.removeAll { $0.videoId == track.videoId }
        tracks.insert(track, at: 0)
        if tracks.count > limit { tracks = Array(tracks.prefix(limit)) }
        save(tracks, key: key)
    }

    func clear() {
        tracks = []
        save(tracks, key: key)
    }
}
