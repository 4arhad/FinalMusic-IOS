import UIKit
#if canImport(CarPlay)
import CarPlay

/// CarPlay surface (the port's §13): browsing Liked Songs, the user's
/// playlists and Recently played, then the standard Now Playing template for
/// transport controls. It drives the SAME PlayerViewModel as the phone UI via
/// PlayerViewModel.current — there is no second audio engine — and the track
/// metadata shown on the dash comes from MPNowPlayingInfoCenter, which the
/// player already maintains for the lock screen.
///
/// Scene-based lifecycle (CPTemplateApplicationSceneSessionRoleApplication),
/// wired through Info.plist's UISceneConfigurations. The audio-app CarPlay
/// entitlement (com.apple.developer.carplay-audio) is an approval-gated
/// capability: without it iOS never offers this scene, so the phone app is
/// unaffected and nothing here runs. See LastWave-carplay.entitlements.
@MainActor
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private var interfaceController: CPInterfaceController?

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                  didConnect interfaceController: CPInterfaceController) {
        self.interfaceController = interfaceController
        // CPListItem images are init-only, so playlist covers resolve through
        // the artwork cache first — an instant hit when warm, and the lists
        // are usually built while the dash is still animating in.
        Task { [weak self] in
            guard let self, self.interfaceController === interfaceController else { return }
            let root = CPTabBarTemplate(templates: [await self.libraryTemplate(),
                                                    self.recentlyPlayedTemplate()])
            interfaceController.setRootTemplate(root, animated: false, completion: nil)
        }
    }

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                  didDisconnectInterfaceController interfaceController: CPInterfaceController) {
        self.interfaceController = nil
    }

    // MARK: - Templates

    private func libraryTemplate() async -> CPListTemplate {
        let liked = CPListItem(text: "Liked Songs",
                               detailText: "\(LikedStore.shared.tracks.count) songs",
                               image: UIImage(systemName: "heart.fill"))
        let likedTracks = LikedStore.shared.tracks
        liked.handler = { [weak self] _, completion in
            self?.play(tracks: likedTracks)
            completion()
        }
        var sections = [CPListSection(items: [liked])]

        let playlists = PlaylistStore.shared.playlists
        if !playlists.isEmpty {
            var items: [CPListItem] = []
            for playlist in playlists.prefix(30) {
                let cover = await ArtworkCache.shared.image(url: playlist.artwork,
                                                             maxPixel: artworkMaxPixel(displaySize: 40))
                let item = CPListItem(text: playlist.title,
                                      detailText: "\(playlist.tracks.count) songs",
                                      image: cover)
                let tracks = playlist.tracks
                item.handler = { [weak self] _, completion in
                    self?.play(tracks: tracks)
                    completion()
                }
                items.append(item)
            }
            sections.append(CPListSection(items: items, header: "Playlists", sectionIndexTitle: nil))
        }

        let template = CPListTemplate(title: "My Library", sections: sections)
        template.tabImage = UIImage(systemName: "music.note.list")
        return template
    }

    private func recentlyPlayedTemplate() -> CPListTemplate {
        let history = HistoryStore.shared.tracks
        let items: [CPListItem] = history.prefix(40).map { track in
            let item = CPListItem(text: track.title, detailText: track.artist)
            item.handler = { [weak self] _, completion in
                self?.play(tracks: history, startingMatching: track.videoId)
                completion()
            }
            return item
        }
        let template = CPListTemplate(title: "Recently Played",
                                      sections: [CPListSection(items: items.isEmpty
                                        ? [CPListItem(text: "Nothing played yet", detailText: nil)]
                                        : items)])
        template.tabImage = UIImage(systemName: "clock.arrow.circlepath")
        return template
    }

    // MARK: - Playback

    /// Queue + show Now Playing. Everything (audio session, remote commands,
    /// scrobbling, lyrics clock) keeps running through the phone-side engine.
    private func play(tracks: [MusicTrack], startingMatching videoId: String? = nil) {
        guard let player = PlayerViewModel.current, !tracks.isEmpty else { return }
        let index = videoId.flatMap { id in tracks.firstIndex { $0.videoId == id } } ?? 0
        player.playQueue(tracks, startingAt: index)
        showNowPlaying(with: player)
    }

    /// The shared Now Playing template reads track metadata, elapsed time and
    /// transport from MPNowPlayingInfoCenter / MPRemoteCommandCenter — which
    /// the engine already maintains for the lock screen — so presenting it
    /// needs no second data path.
    private func showNowPlaying(with player: PlayerViewModel) {
        guard let interfaceController else { return }
        let nowPlaying = CPNowPlayingTemplate.shared
        let skipImage = UIImage(systemName: "forward.fill") ?? UIImage()
        let buttons: [CPNowPlayingButton] = [
            CPNowPlayingImageButton(image: skipImage) { _ in
                player.next()
            },
            CPNowPlayingAddToLibraryButton { _ in
                player.toggleLoveCurrentTrack()
            },
        ]
        nowPlaying.updateNowPlayingButtons(buttons)
        nowPlaying.add(queueObserver)
        interfaceController.pushTemplate(nowPlaying, animated: true, completion: nil)
    }

    /// Forwards the "Up Next" button to a live queue list.
    private lazy var queueObserver = QueueObserver { [weak self] in
        self?.presentQueue()
    }

    private func presentQueue() {
        guard let player = PlayerViewModel.current else { return }
        var items: [CPListItem] = []
        for (index, track) in player.queue.enumerated() {
            let prefix = track.videoId == player.currentTrack?.videoId ? "\u{266B} " : ""
            let item = CPListItem(text: prefix + track.title, detailText: track.artist)
            item.handler = { _, completion in
                player.playQueue(player.queue, startingAt: index)
                completion()
            }
            items.append(item)
        }
        let list = CPListTemplate(title: "Up Next", sections: [CPListSection(items: items)])
        interfaceController?.pushTemplate(list, animated: true, completion: nil)
    }
}

/// CPNowPlayingTemplateObserver must be a class; this forwards one callback.
final class QueueObserver: NSObject, CPNowPlayingTemplateObserver {
    private let onUpNext: @MainActor () -> Void
    init(onUpNext: @escaping @MainActor () -> Void) { self.onUpNext = onUpNext }

    func nowPlayingTemplateUpNextButtonTapped(_ nowPlayingTemplate: CPNowPlayingTemplate) {
        // CarPlay delivers template observers on the main thread; hop
        // explicitly so the MainActor-isolated delegate is entered correctly.
        DispatchQueue.main.async { self.onUpNext() }
    }
}
#endif
