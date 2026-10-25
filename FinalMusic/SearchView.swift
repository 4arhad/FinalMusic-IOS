import SwiftUI

// Search with the Android app's filter chips. Filters are the real WEB_REMIX
// params (songs / albums / artists / videos / community playlists), verified
// against the live endpoint.

struct SearchView: View {
    @EnvironmentObject private var player: PlayerViewModel

    let initialQuery: String
    let autoOpenFirst: Bool
    let initialKind: EntityKind?
    /// Sends the user back to the Home tab — the Search tab is often entered
    /// from Home, so it gets its own way back at the root of its stack.
    let onGoHome: () -> Void
    /// The stack lives in ContentView so the player can be pushed inside it.
    @Binding var path: NavigationPath

    init(initialQuery: String = "",
         autoOpenFirst: Bool = false,
         initialKind: EntityKind? = nil,
         onGoHome: @escaping () -> Void = {},
         path: Binding<NavigationPath>) {
        self.initialQuery = initialQuery
        self.autoOpenFirst = autoOpenFirst
        self.initialKind = initialKind
        self.onGoHome = onGoHome
        self._path = path
    }

    @State private var query = ""
    @State private var kind: EntityKind? = .song
    @State private var tracks: [MusicTrack] = []
    @State private var entities: [SearchEntity] = []
    @State private var isSearching = false
    @State private var errorText: String?
    /// Only the newest search may publish: a submit while an earlier request
    /// is in flight cancels it (the URLSession async bridge turns that into a
    /// cancelled request), and a cancelled task never writes results.
    @State private var searchTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            searchField
            chips
            content
        }
        .navigationTitle("Search")
        .toolbar {
            // Only at the root of the stack: once a page is pushed the
            // system back chevron takes this spot.
            if path.isEmpty {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        onGoHome()
                    } label: {
                        // A plain Label renders icon-only in the nav bar, so
                        // build the chevron + word explicitly.
                        HStack(spacing: 2) {
                            Image(systemName: "chevron.backward")
                            Text("Home")
                        }
                        .font(.body)
                    }
                    .accessibilityLabel("Back to Home")
                }
            }
        }
        .task {
            if let initialKind { kind = initialKind }
            guard !initialQuery.isEmpty, tracks.isEmpty, entities.isEmpty else { return }
            query = initialQuery
            await run(autoOpenFirst: autoOpenFirst)
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Songs, artists, albums", text: $query)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .onSubmit { startSearch(autoOpenFirst: false) }
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 16)
        .padding(.top, 6)
    }

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(EntityKind.allCases) { candidate in
                    Button {
                        kind = candidate
                        if !query.isEmpty { startSearch(autoOpenFirst: false) }
                    } label: {
                        Text(candidate.rawValue)
                            .font(.subheadline)
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(candidate == kind ? AnyShapeStyle(Color.accentColor.opacity(0.18))
                                                          : AnyShapeStyle(.quaternary.opacity(0.5)),
                                        in: Capsule())
                            .foregroundStyle(candidate == kind ? Color.accentColor : Color.primary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 6)
        }
    }

    @ViewBuilder
    private var content: some View {
        if isSearching {
            ProgressView().frame(maxHeight: .infinity)
        } else if let errorText {
            ContentUnavailableView("Search failed", systemImage: "wifi.exclamationmark",
                                   description: Text(errorText))
        } else if tracks.isEmpty && entities.isEmpty {
            ContentUnavailableView.search(text: query)
        } else if !entities.isEmpty {
            List(entities) { entity in
                NavigationLink(value: Route.collection(entity.browseId)) {
                    CollectionRow(entity: entity)
                }
                .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 16))
            }
            .listStyle(.plain)
        } else {
            List(tracks) { track in
                TrackRow(track: track) {
                    player.playQueue(tracks, startingAt: tracks.firstIndex(of: track) ?? 0)
                }
                .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
            }
            .listStyle(.plain)
        }
    }

    func run(autoOpenFirst: Bool) async {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return }
        isSearching = true
        errorText = nil
        do {
            if let kind, kind == .album || kind == .artist || kind == .playlist {
                let found = try await InnerTube.searchEntities(query: term, kind: kind)
                guard !Task.isCancelled else { return }
                entities = found
                tracks = []
                if autoOpenFirst, let first = entities.first {
                    path.append(Route.collection(first.browseId))
                }
            } else {
                let selected = kind ?? .song
                let found = try await InnerTube.searchTracksFiltered(query: term, kind: selected)
                guard !Task.isCancelled else { return }
                tracks = found
                entities = []
                if tracks.isEmpty {
                    let more = try await InnerTube.searchSongs(query: term)
                    guard !Task.isCancelled else { return }
                    tracks = more
                }
            }
        } catch {
            guard !Task.isCancelled else { return }
            errorText = error.localizedDescription
        }
        isSearching = false
    }

    /// Supersede any in-flight search: cancel it, then start this one.
    private func startSearch(autoOpenFirst: Bool) {
        searchTask?.cancel()
        searchTask = Task { await run(autoOpenFirst: autoOpenFirst) }
    }

    /// Used by the launch hooks so a headless run can exercise search.
    func setQuery(_ value: String) { query = value }

    func setKind(_ value: EntityKind?) { kind = value }
}
