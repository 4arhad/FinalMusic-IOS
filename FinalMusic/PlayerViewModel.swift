import Foundation
import AVFoundation
import MediaPlayer
import UIKit
import Combine

// Media3-ExoPlayer equivalent for this port: an AVPlayer queue with lock
// screen controls, background audio, and the scrobble timing hooks —
// nowPlaying on track start and track.scrobble once ScrobblePolicy allows.
@MainActor
final class PlayerViewModel: ObservableObject {
    /// The one player instance, reachable from non-SwiftUI lifecycles (the
    /// CarPlay scene delegate). The App struct owns it via @StateObject; this
    /// is only a weak bridge so the engine stays singular.
    static weak var current: PlayerViewModel?

    @Published var queue: [MusicTrack] = []
    @Published var currentIndex: Int?
    @Published var isPlaying = false
    @Published var currentTime: TimeInterval = 0
    @Published var duration: TimeInterval = 0
    @Published var buffering = false
    @Published var errorMessage: String?
    @Published var loved = false
    @Published var shuffle = false
    @Published var repeatAll = false
    /// True while the queue is a YouTube Music radio ("remix"): running out of
    /// tracks fetches the next page instead of stopping.
    @Published private(set) var isRadio = false
    private var radioContinuation: String?
    private var radioPlaylistId: String?
    private var isLoadingRadioPage = false

    private var player: AVPlayer?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var playbackStatusObserver: NSKeyValueObservation?
    /// Monotonic load counter: rapid next()/next() launches overlapping resolves,
    /// and the LAST one must win — without this, the earlier tap's slower resolve
    /// can clobber the newer track.
    private var loadSequence = 0
    private var trackStart: Date?
    private var didScrobble = false
    private weak var scrobbler: LastFmClient?
    private var artworkTask: Task<Void, Never>?

    init() {
        PlayerViewModel.current = self
        // NOTE: no AVAudioSession work here. Configuring the session during
        // App init (before the first frame renders) can block the main thread
        // against mediaserverd on physical devices -> black screen at launch.
        // The session is configured lazily when a stream is loaded.
        configureRemoteCommands()

    }

    // Deep-link playback (lastwave://play/<videoId>), mirroring the Android
    // app's link resolvers: fetch watch metadata via the player endpoint.
    func play(videoId: String) async {
        if currentTrack?.videoId == videoId { return }
        do {
            let stream = try await StreamExtractor.resolve(videoId: videoId)
            let track = MusicTrack(
                videoId: videoId,
                title: stream.videoTitle ?? "Unknown title",
                artist: stream.videoArtist ?? "Unknown artist",
                album: nil,
                artwork: "https://i.ytimg.com/vi/\(videoId)/hq720.jpg",
                durationSeconds: stream.durationSeconds.map { Int($0) }
            )
            playQueue([track], startingAt: 0)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func attachScrobbler(_ client: LastFmClient?) {
        scrobbler = client
    }

    var currentTrack: MusicTrack? {
        guard let index = currentIndex, queue.indices.contains(index) else { return nil }
        return queue[index]
    }

    // MARK: - Transport

    func playQueue(_ tracks: [MusicTrack], startingAt index: Int) {
        guard !tracks.isEmpty else { return }
        queue = tracks
        isRadio = false
        radioContinuation = nil
        radioPlaylistId = nil
        NSLog("LWQUEUE play n=%d index=%d first=%@", tracks.count, index, tracks.first?.title ?? "-")
        loadTrack(at: min(max(index, 0), tracks.count - 1))
    }

    /// "Remix": YouTube Music's own radio for a seed track (/next with
    /// playlistId RDAMVM<videoId>), extended page by page while it plays.
    func startRadio(seed: MusicTrack) async {
        errorMessage = nil
        do {
            let result = try await InnerTube.radio(videoId: seed.videoId)
            let tracks = [seed] + result.tracks.filter { $0.videoId != seed.videoId }
            guard tracks.count > 1 else {
                errorMessage = "No radio tracks were returned for this song."
                return
            }
            queue = tracks
            isRadio = true
            radioContinuation = result.continuation
            radioPlaylistId = result.automixPlaylistId
            loadTrack(at: 0)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Radio from a plain videoId (launch hook / deep link), using the radio's
    /// own ordering since we have no local metadata for the seed.
    func startRadio(videoId: String) async {
        errorMessage = nil
        do {
            let result = try await InnerTube.radio(videoId: videoId)
            guard !result.tracks.isEmpty else {
                errorMessage = "No radio tracks were returned for this song."
                return
            }
            queue = result.tracks
            isRadio = true
            radioContinuation = result.continuation
            radioPlaylistId = result.automixPlaylistId
            NSLog("LWRADIO start %@ tracks=%d continuation=%@ automix=%@",
                  videoId, result.tracks.count,
                  result.continuation == nil ? "no" : "yes",
                  result.automixPlaylistId ?? "-")
            loadTrack(at: 0)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Radio from an artist/album page's own mix playlist id.
    func startRadio(playlistId: String) async {
        errorMessage = nil
        do {
            let result = try await InnerTube.radioByPlaylistId(playlistId)
            guard !result.tracks.isEmpty else {
                errorMessage = "No radio tracks were returned for this mix."
                return
            }
            queue = result.tracks
            isRadio = true
            radioContinuation = result.continuation
            radioPlaylistId = result.automixPlaylistId ?? playlistId
            loadTrack(at: 0)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Books anything played but not yet recorded — called when the app leaves
    /// the foreground, where the last partial chunk would otherwise be lost.
    func flushPendingPlayStats() { flushPlayTime() }

    func toggleShuffle() { shuffle.toggle() }

    func toggleRepeat() { repeatAll.toggle() }

    func togglePlayPause() {
        if isPlaying {
            ensurePlayer().pause()
            isPlaying = false
            flushPlayTime()
        } else if ensurePlayer().currentItem != nil {
            ensurePlayer().play()
            isPlaying = true
            statsAnchor = Date()
            lastFlushAt = Date()
        } else if let index = currentIndex {
            loadTrack(at: index)
            return
        }
        refreshNowPlaying()
    }

    func next() {
        recordSkipIfEarly()
        advance()
    }

    func previous() {
        guard let index = currentIndex, index > 0 else { return }
        recordSkipIfEarly()
        loadTrack(at: index - 1)
    }

    /// Lock-screen pause: same bookkeeping as the in-app pause, otherwise the
    /// paused minutes get counted as *played* time in the stats.
    private func pauseFromRemote() {
        guard isPlaying else { return }
        ensurePlayer().pause()
        isPlaying = false
        flushPlayTime()
        refreshNowPlaying()
    }

    private func resumeFromRemote() {
        guard !isPlaying else { return }
        ensurePlayer().play()
        isPlaying = true
        statsAnchor = Date()
        lastFlushAt = Date()
        refreshNowPlaying()
    }

    func seek(to time: TimeInterval) {
        ensurePlayer().seek(to: CMTime(seconds: time, preferredTimescale: 600))
        currentTime = time
        refreshNowPlaying()
    }

    private func advance() {
        guard let index = currentIndex else { return }
        switch QueueOps.advance(count: queue.count,
                               current: index,
                               shuffle: shuffle,
                               randomPick: Int.random(in: 0..<max(queue.count, 1)),
                               repeatAll: repeatAll,
                               isRadio: isRadio) {
        case .load(let next):
            loadTrack(at: next)
        case .extendRadio:
            Task { await extendRadio() }
        case .stop:
            ensurePlayer().pause()
            isPlaying = false
            // Book the tail of the track: nothing else will flush it now.
            flushPlayTime()
        }
    }

    // MARK: - Queue editing (sheet)

    /// Drag-reorder in the queue sheet. The identity of the currently playing
    /// track follows it to its new index; AVPlayer is not touched — the item
    /// is already loaded, and 'next' resolves by index at advance time.
    func moveQueue(fromOffsets source: IndexSet, toOffset destination: Int) {
        guard let currentId = currentTrack?.videoId else { return }
        queue = QueueOps.moved(queue, fromOffsets: source, toOffset: destination)
        currentIndex = queue.firstIndex { $0.videoId == currentId }
    }

    /// Swipe-remove in the queue sheet. The current track is not removable
    /// from the UI; if a stale index still hits it, advance() moves on.
    func removeFromQueue(atOffsets offsets: IndexSet) {
        guard let index = currentIndex, !offsets.contains(index) else { return }
        let removedBefore = QueueOps.removalShift(before: index, offsets: offsets)
        queue = QueueOps.removed(queue, at: offsets)
        currentIndex = index - removedBefore
        evictStalePrefetches(keeping: currentTrack?.videoId ?? "")
    }

    private func extendRadio() async {
        guard !isLoadingRadioPage else { return }
        isLoadingRadioPage = true
        defer { isLoadingRadioPage = false }
        do {
            let result: RadioQueue
            if let token = radioContinuation {
                result = try await InnerTube.radioContinuation(token)
            } else if let playlistId = radioPlaylistId {
                result = try await InnerTube.radioByPlaylistId(playlistId)
            } else {
                isPlaying = false
                return
            }
            radioContinuation = result.continuation ?? radioContinuation
            radioPlaylistId = result.automixPlaylistId ?? radioPlaylistId
            let known = Set(queue.map(\.videoId))
            let fresh = result.tracks.filter { !known.contains($0.videoId) }
            NSLog("LWRADIO extend +%d (queue was %d, continuation=%@)",
                  fresh.count, queue.count, result.continuation == nil ? "no" : "yes")
            guard !fresh.isEmpty else {
                ensurePlayer().pause()
                isPlaying = false
                return
            }
            let start = queue.count
            queue.append(contentsOf: fresh)
            loadTrack(at: start)
        } catch {
            errorMessage = error.localizedDescription
            isPlaying = false
        }
    }

    private var streamFailureObserver: NSKeyValueObservation?

    /// Bounded forward buffer: a music stream should not pull far ahead over the
    /// localhost proxy, and a paused track must not keep the network busy.
    private func makeItem(for proxyURL: URL) -> AVPlayerItem {
        let item = AVPlayerItem(asset: AVURLAsset(url: proxyURL))
        item.preferredForwardBufferDuration = 30
        item.canUseNetworkResourcesForLiveStreamingWhilePaused = false
        return item
    }

    /// Drop warmed streams that can no longer be next (e.g. after a double
    /// skip) — the URLs expire and would otherwise be kept until capacity evicts.
    private func evictStalePrefetches(keeping currentVideoId: String) {
        let nextId = currentIndex.flatMap { queue.indices.contains($0 + 1) ? queue[$0 + 1].videoId : nil }
        prefetchedStreams = prefetchedStreams.filter { $0.key == nextId }
    }

    /// Warms the next queue entry's stream while the current track plays.
    private func prefetchNext(after index: Int) {
        prefetchTask?.cancel()
        guard queue.indices.contains(index + 1) else { return }
        let next = queue[index + 1]
        // Artwork rides the same warm-up: the player screen's large cover
        // is in the cache before the user expands the mini player.
        Task { await ArtworkCache.shared.prefetch([next.artwork], maxPixel: artworkMaxPixel(displaySize: 250)) }
        guard prefetchedStreams[next.videoId] == nil else { return }
        prefetchTask = Task { [weak self] in
            do {
                let stream = try await StreamExtractor.resolve(videoId: next.videoId, forceRefresh: false)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard let self else { return }
                    if self.prefetchedStreams.count >= 2 { self.prefetchedStreams.removeAll() }
                    self.prefetchedStreams[next.videoId] = stream
                    NSLog("LWPREFETCH stored video=%@", next.videoId)
                }
            } catch {
                NSLog("LWPREFETCH failed video=%@ error=%@", next.videoId, error.localizedDescription)
            }
        }
    }

    private func observeEnd(of item: AVPlayerItem) {
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: item,
            queue: .main
        ) { [weak self, weak item] _ in
            Task { @MainActor in
                guard let self, let item else { return }
                self.advanceIfCurrentItemEnded(item)
            }
        }
    }

    private func advanceIfCurrentItemEnded(_ item: AVPlayerItem) {
        guard player?.currentItem === item, isPlaying else { return }
        NSLog("LWQUEUE item_ended advancing")
        advance()
    }

    private func ensurePlayer() -> AVPlayer {
        if let player { return player }
        let newPlayer = AVPlayer()
        player = newPlayer
        playbackStatusObserver = newPlayer.observe(\.timeControlStatus, options: [.new]) { [weak self] observed, _ in
            Task { @MainActor in
                guard let self, observed.timeControlStatus == .paused,
                      let item = observed.currentItem, self.isPlaying,
                      item.status == .readyToPlay,
                      self.duration > 0,
                      self.currentTime >= self.duration + 1 else { return }
                self.advanceIfCurrentItemEnded(item)
            }
        }
        configureRemoteCommands()
        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        timeObserver = newPlayer.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            Task { @MainActor in
                guard let self else { return }
                guard time.seconds.isFinite else { return }
                self.currentTime = max(0, time.seconds)
                // End notifications are the primary signal. A stalled proxy
                // sometimes leaves AVPlayer running beyond the reported media
                // duration, so also detect a finished *item* only when the
                // player is no longer waiting for more media. Do not use the
                // metadata duration alone: it may be inaccurate.
                if let item = self.player?.currentItem,
                   item.status == .readyToPlay,
                   item.isPlaybackLikelyToKeepUp,
                   self.player?.timeControlStatus == .paused,
                   self.isPlaying,
                   self.duration > 0,
                   self.currentTime >= self.duration + 1 {
                    self.advanceIfCurrentItemEnded(item)
                }
                self.evaluateScrobble()
                self.flushPlayTimeIfDue()
            }
        }
        return newPlayer
    }
    private var didRetryResolve = false
    private var currentToken: String?

    private let sessionQueue = DispatchQueue(label: "lastwave.audio-session")

    // Activating an audio session can block against mediaserverd; iOS 27 files
    // the synchronous main-thread call as a hang risk (AVAudioSession_iOS.mm:978),
    // so configure it on a background queue using the async activate API.
    private func configureAudioSessionIfNeeded() {
        if audioSessionConfigured { return }
        audioSessionConfigured = true
        sessionQueue.async { [weak self] in
            let session = AVAudioSession.sharedInstance()
            try? session.setCategory(.playback, mode: .default)
            func finish(_ activated: Bool) {
                Task { @MainActor in self?.audioSessionReady = activated }
            }
            if #available(iOS 27.0, *) {
                session.activate(options: []) { activated, _ in finish(activated) }
            } else {
                finish((try? session.setActive(true)) != nil)
            }
        }
    }

    private var audioSessionConfigured = false

    private var audioSessionReady = false

    // Listening signal for the "For You" engine — accumulated played time per
    // track plus skips, the iOS counterpart of the Android client's
    // song_play_stats table. Anchored to wall clock while playing.
    private var statsAnchor: Date?
    private var statsTrack: MusicTrack?
    private var lastFlushAt = Date.distantPast

    // Resolved next-track streams, keyed by video id: resolving while the current
    // track plays removes the network round-trip from the track transition.
    private var prefetchedStreams: [String: AudioStream] = [:]
    private var prefetchTask: Task<Void, Never>?

    /// Books accumulated play time at most every 15 s of playback, so time is
    /// not lost when nothing interrupts the track (force quit, stuck queue).
    private func flushPlayTimeIfDue() {
        guard isPlaying, statsTrack != nil,
              Date().timeIntervalSince(lastFlushAt) >= 15 else { return }
        lastFlushAt = Date()
        flushPlayTime()
    }

    /// Books the time played since the last anchor (pause, track change, stop).
    private func flushPlayTime() {
        defer { statsAnchor = isPlaying ? Date() : nil }
        guard let track = statsTrack, let anchor = statsAnchor else { return }
        PlayStatsStore.shared.addPlayTime(track, milliseconds: Date().timeIntervalSince(anchor) * 1000)
    }

    /// A user-initiated move-on before the track was really listened to counts as
    /// a skip; a track that runs to its end does not.
    private func recordSkipIfEarly() {
        guard let track = currentTrack,
              currentTime < PlayStatsStore.skipThresholdMs / 1000 else { return }
        PlayStatsStore.shared.recordSkip(track)
    }

    private func loadTrack(at index: Int) {
        guard queue.indices.contains(index) else { return }
        configureAudioSessionIfNeeded()
        currentIndex = index
        didScrobble = false
        trackStart = Date()
        errorMessage = nil
        buffering = true
        loved = LikedStore.shared.contains(queue[index].videoId)
        HistoryStore.shared.record(queue[index])
        // Book the outgoing track's time, then start counting for this one.
        flushPlayTime()
        PlayStatsStore.shared.recordStart(queue[index])
        statsTrack = queue[index]
        statsAnchor = Date()
        lastFlushAt = Date()
        currentTime = 0
        didRetryResolve = false
        loadSequence += 1
        let sequence = loadSequence

        let track = queue[index]
        Task {
            do {
                // Use the stream warmed while the previous track played, so the
                // transition costs no resolve round-trip.
                let stream: AudioStream
                if let cached = prefetchedStreams.removeValue(forKey: track.videoId) {
                    stream = cached
                    NSLog("LWPREFETCH hit video=%@", track.videoId)
                } else {
                    stream = try await StreamExtractor.resolve(videoId: track.videoId)
                }
                NSLog("LWLOAD %d/%d %@ videoId=%@ -> %@", index, queue.count, track.title, track.videoId,
                      stream.url.host ?? "-")
                // googlevideo 503s AVPlayer's own UA (verified in simulator
                // logs), so AVPlayer reads from the local byte-range proxy
                // which attaches the extracting client's headers upstream.
                NSLog("LWPROXY creating asset token")
                let proxyURL = URL(string: try await LocalStreamProxy.shared.register(stream))!
                currentToken = proxyURL.lastPathComponent
                NSLog("LWPROXY asset url: %@", proxyURL.absoluteString)
                let item = self.makeItem(for: proxyURL)
                guard sequence == self.loadSequence else {
                    // A newer load started while this resolve was in flight;
                    // handing the player to this stale track is the rapid-skip bug.
                    NSLog("LWLOAD stale sequence %d (current %d), dropping", sequence, self.loadSequence)
                    return
                }
                let p = self.ensurePlayer()
                p.replaceCurrentItem(with: item)
                self.observeEnd(of: item)
                self.watchItemFailure(item)
                if let index = self.currentIndex { self.prefetchNext(after: index) }
                // Do not block playback on an AVURLAsset duration request.
                // That request may wait on the proxy/network even though we
                // already know the duration from extraction or queue metadata.
                self.duration = stream.durationSeconds ?? Double(track.durationSeconds ?? 0)
                p.play()
                self.isPlaying = true
                self.buffering = false
                self.refreshNowPlaying()
                self.postNowPlayingToLastFm(track: track)
                self.loadArtwork(from: track.artwork)
                self.evictStalePrefetches(keeping: track.videoId)
            } catch {
                self.buffering = false
                self.errorMessage = error.localizedDescription
                NSLog("LWLOAD error %@", error.localizedDescription)
            }
        }
    }

    // googlevideo edges can answer videoplayback with 403 after an IP has
    // pulled too much in a short window (abuse cooldown). Fail gracefully
    // and retry once against a freshly resolved session URL.
    private func watchItemFailure(_ item: AVPlayerItem) {
        streamFailureObserver = item.observe(\.status, options: [.initial, .new]) { [weak self] failedItem, _ in
            guard failedItem.status == .failed else { return }
            Task { @MainActor in
                guard let self else { return }
                // An earlier track's item can fail after we already advanced;
                // acting on it would reload the WRONG (newer) track.
                guard self.player?.currentItem === failedItem,
                      let track = self.currentTrack else { return }
                if !self.didRetryResolve {
                    self.didRetryResolve = true
                    // The CDN refused the URLs this profile handed out, so ban it:
                    // re-resolving with the same client just reproduces the 403.
                    StreamExtractor.markLastClientRefused()
                    Task { await self.reload(track, forceRefresh: true) }
                } else {
                    let status = self.currentToken.flatMap { LocalStreamProxy.shared.upstreamStatus(for: $0) }
                    let detail = status.map { "the stream edge answered HTTP \($0)" }
                        ?? failedItem.error?.localizedDescription
                        ?? "the stream was refused"
                    self.errorMessage = "Playback blocked — \(detail). Usually a short rate limit; try again in a few minutes."
                    self.isPlaying = false
                    self.buffering = false
                }
            }
        }
    }

    private func reload(_ track: MusicTrack, forceRefresh: Bool) async {
        do {
            let stream: AudioStream
            if !forceRefresh, let cached = prefetchedStreams.removeValue(forKey: track.videoId) {
                stream = cached
                NSLog("LWPREFETCH hit video=%@", track.videoId)
            } else {
                stream = try await StreamExtractor.resolve(videoId: track.videoId, forceRefresh: forceRefresh)
            }
            let proxyURL = URL(string: try await LocalStreamProxy.shared.register(stream))!
            currentToken = proxyURL.lastPathComponent
            let item = makeItem(for: proxyURL)
            ensurePlayer().replaceCurrentItem(with: item)
            observeEnd(of: item)
            watchItemFailure(item)
            ensurePlayer().play()
            if let index = currentIndex { prefetchNext(after: index) }
            isPlaying = true
            buffering = false
        } catch {
            errorMessage = error.localizedDescription
            buffering = false
        }
    }

    // MARK: - Scrobble timing

    private func evaluateScrobble() {
        guard let track = currentTrack, let start = trackStart, !didScrobble else { return }
        guard ScrobblePolicy.shouldScrobble(elapsed: currentTime, duration: duration) else { return }
        didScrobble = true
        let client = scrobbler
        Task.detached {
            try? await client?.scrobble(
                track: track.title,
                artist: track.artist,
                album: track.album,
                startTime: start
            )
        }
    }

    private func postNowPlayingToLastFm(track: MusicTrack) {
        guard let client = scrobbler, client.isSignedIn else { return }
        Task.detached {
            try? await client.updateNowPlaying(
                track: track.title,
                artist: track.artist,
                album: track.album,
                duration: nil
            )
        }
    }

    func toggleLoveCurrentTrack() {
        guard let track = currentTrack else { return }
        let nowLoved = LikedStore.shared.toggle(track)
        loved = nowLoved
        // Mirror the like to the YouTube Music account when one is connected.
        YouTubeAccount.shared.pushLike(videoId: track.videoId, liked: nowLoved)
        guard nowLoved, let client = scrobbler, client.isSignedIn else { return }
        Task.detached {
            try? await client.love(track: track.title, artist: track.artist)
        }
    }

    // MARK: - Now Playing info / lock screen

    private func configureRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.resumeFromRemote() }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.pauseFromRemote() }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.togglePlayPause() }
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.next() }
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.previous() }
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let self,
                  let positionEvent = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let position = positionEvent.positionTime
            Task { @MainActor in self.seek(to: position) }
            return .success
        }
    }

    func refreshNowPlaying() {
        guard let track = currentTrack else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        var info: [String: Any] = [
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: track.artist,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
        ]
        if let album = track.album { info[MPMediaItemPropertyAlbumTitle] = album }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func loadArtwork(from urlString: String?) {
        artworkTask?.cancel()
        guard let urlString, !urlString.isEmpty else { return }
        artworkTask = Task {
            // Through the shared two-level cache: the player screen usually
            // wants the same artwork, so the lock screen never re-downloads it.
            guard let image = await ArtworkCache.shared.image(url: urlString,
                                                              maxPixel: artworkMaxPixel(displaySize: 250)) else { return }
            let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
            info[MPMediaItemPropertyArtwork] = artwork
            MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        }
    }
}
