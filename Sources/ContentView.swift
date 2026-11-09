//
//  ContentView.swift
//  Wazy
//
//  Sidebar of the site's navigation beside a browse stack of pages (rows of artwork) and search.
//  Playing something shows the player on the TV tab (WazKit's PlayerView); the player can split the
//  movie out into its own window.
//

import SwiftUI
import WazKit


/// Where the sidebar can take you: a page from the site's navigation, search, or the TV tab (the player).
enum Place: Hashable {
    case nav(NavItem)
    case search
    case sports
    case tv

    var title: String {
        switch self {
        case .nav(let item): item.name
        case .search: "Search"
        case .sports: "Sports"
        case .tv: "TV"
        }
    }
}

/// A page pushed on the browse stack.
struct Destination: Hashable {
    let pageId: String
    let title: String
}

@MainActor
final class AppModel: ObservableObject {
    let client = DisneyClient()
    let player: PlayerController

    @Published var nav: [NavItem] = []
    @Published var place: Place? { didSet { if place != .tv { path = [] } } }
    @Published var path: [Destination] = []
    @Published var showSignIn = false
    /// Live page search text; the field lives in the window toolbar, left of Sign Out. Kept in its own
    /// object so typing does not re-render the window (and the toolbar), which would drop the field's focus.
    let liveSearch = LiveSearch()
    var liveSelected: Bool {
        if case .nav(let item) = place { return item.name.lowercased() == "live" }
        return false
    }
    /// Playback > Float on Top: the split-out player window stays above other windows.
    @Published var playerFloats = false { didSet { player.floatsOnTop = playerFloats } }
    /// Bumped on sign-in/out so the views reload.
    @Published var session = 0

    init() {
        player = PlayerController(service: client)
        Task { await start() }
    }

    /// On launch: refresh an old token quietly with the stored refresh token, then saved Keychain credentials once, else ask to sign in.
    private func start() async {
        if Session.needsRefresh, await !DisneyAuth.refresh(), await !DisneyAuth.recover() {
            showSignIn = true
            return
        }
        await loadNavigation()
    }

    func loadNavigation(retry: Bool = true) async {
        do {
            nav = try await client.navigation()
            if place == nil, let first = nav.first { place = .nav(first) }
        } catch {
            // 401/403 for a stale token, 400 for an anonymous one: either way a refresh or sign-in is needed.
            if case DisneyError.http = error {
                var recovered = false
                if retry { recovered = await DisneyAuth.refresh() }
                if retry, !recovered { recovered = await DisneyAuth.recover() }
                if recovered {
                    await loadNavigation(retry: false)
                } else {
                    DisneyAuth.stopRecovery()
                    showSignIn = true
                }
            }
        }
    }

    func signedIn() {
        session += 1
        Task { await loadNavigation() }
    }

    /// What a click on an item does: episodes and live airings play; everything else opens its page.
    func open(_ item: Item) {
        if let pageId = item.pageId, !(item.isEpisode || item.isLive) || item.play == nil {
            path.append(Destination(pageId: pageId, title: item.title))
        } else if item.play != nil {
            play(item)
        }
    }

    /// Starts playback and shows it on the TV tab (or in the split-out window, if that is open).
    func play(_ item: Item) {
        guard let action = item.play else { return }
        player.play(NowPlaying(id: item.id, title: item.title, subtitle: item.subtitle)) { [client] in
            try await client.playback(resourceId: action.resourceId)
        }
        place = .tv
    }

    func signOut() {
        player.stop()
        DisneyAuth.signOut()
        nav = []
        place = nil
        path = []
        session += 1
        showSignIn = true
    }
}

struct ContentView: View {
    @EnvironmentObject var app: AppModel

    var body: some View {
        NavigationSplitView {
            List(selection: $app.place) {
                ForEach(app.nav) { item in
                    Label(item.name, systemImage: item.icon).tag(Place.nav(item))
                }
                Label("Sports", systemImage: "sportscourt").tag(Place.sports)
                Label("Search", systemImage: "magnifyingglass").tag(Place.search)
                Label("TV", systemImage: "tv").tag(Place.tv)
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 180, max: 240)
        } detail: {
            NavigationStack(path: $app.path) {
                root
                    .navigationDestination(for: Destination.self) { destination in
                        PageView(pageId: destination.pageId, title: destination.title)
                    }
            }
            .id(app.session)
        }
        .toolbar {
            if #available(macOS 26.0, *) {
                ToolbarItem(placement: .primaryAction) {
                    if app.liveSelected, app.path.isEmpty {
                        LiveSearchField(search: app.liveSearch)
                    }
                }
                .sharedBackgroundVisibility(.hidden)
                ToolbarSpacer(.fixed, placement: .primaryAction)
            } else {
                ToolbarItem(placement: .primaryAction) {
                    if app.liveSelected, app.path.isEmpty {
                        LiveSearchField(search: app.liveSearch)
                    }
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    app.signOut()
                } label: {
                    Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
                }
                .help("Sign out of Disney+")
            }
        }
        .frame(minWidth: 960, minHeight: 600)
        .sheet(isPresented: $app.showSignIn) {
            SignInView { app.signedIn() }
        }
    }

    @ViewBuilder private var root: some View {
        switch app.place {
        case .search: SearchView()
        case .sports:
            if let item = app.nav.first(where: { $0.name.lowercased() == "sports" })
                ?? app.nav.first(where: { $0.name.lowercased() == "espn" }) {
                PageView(pageId: item.pageId, title: "Sports")
            } else {
                ContentUnavailableView("Sports Unavailable", systemImage: "sportscourt",
                                       description: Text("Disney+ has not provided a Sports or ESPN page for this profile."))
            }
        case .nav(let item): PageView(pageId: item.pageId, title: item.name, searchable: item.name.lowercased() == "live", search: app.liveSearch)
        case .tv: PlayerView(player: app.player, inWindow: false, title: "Wazy")
        case nil: ProgressView()
        }
    }
}

// MARK: - Live search

final class LiveSearch: ObservableObject {
    @Published var text = ""
}

/// The toolbar's Live search field, with a clear (X) button while it has text.
struct LiveSearchField: View {
    @ObservedObject var search: LiveSearch

    var body: some View {
        TextField("Search channels and shows", text: $search.text)
            .textFieldStyle(.roundedBorder)
            .overlay(alignment: .trailing) {
                if !search.text.isEmpty {
                    Button {
                        search.text = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 6)
                    .help("Clear search")
                }
            }
            .frame(width: 220)
    }
}

// MARK: - Pages

struct PageView: View {
    @EnvironmentObject var app: AppModel
    let pageId: String
    let title: String
    /// Shows a search bar that filters the page's tiles by title (used for Live).
    var searchable = false
    @ObservedObject var search = LiveSearch()
    @State private var page: Page?
    @State private var error: String?

    private var filter: String { searchable ? search.text.trimmingCharacters(in: .whitespaces) : "" }

    var body: some View {
        Group {
            if let page {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 24) {
                        if page.play != nil || page.description != nil {
                            header(page)
                        }
                        ForEach(page.collections) { collection in
                            CollectionRow(collection: collection, filter: filter)
                        }
                    }
                    .padding(.vertical, 20)
                }
            } else if let error {
                ContentUnavailableView(error, systemImage: "exclamationmark.triangle")
            } else {
                ProgressView()
            }
        }
        .navigationTitle(page?.title.isEmpty == false ? page!.title : title)
        .task(id: pageId) { await load() }
    }

    private func header(_ page: Page) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let description = page.description {
                Text(description).foregroundStyle(.secondary).lineLimit(4)
            }
            if let play = page.play {
                let item = Item(id: page.id, title: page.title, play: play, tileImage: page.tileImage)
                Button {
                    app.play(item)
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        Artwork(url: item.artwork(width: 960, height: 540), title: item.title)
                            .frame(width: 480, height: 270)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay {
                                Image(systemName: "play.circle.fill").font(.system(size: 56))
                                    .foregroundStyle(.white).shadow(radius: 6)
                            }
                        Text("Play").font(.headline)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 20)
    }

    private func load() async {
        page = nil
        error = nil
        do { page = try await app.client.page(pageId) } catch { self.error = error.localizedDescription }
    }
}

struct CollectionRow: View {
    @EnvironmentObject var app: AppModel
    @State var collection: Collection
    /// Only tiles whose title or subtitle contains this text are shown (empty shows all).
    var filter = ""
    @State private var loadingMore = false

    private var visibleItems: [Item] {
        guard !filter.isEmpty else { return collection.items }
        return collection.items.filter {
            $0.title.localizedCaseInsensitiveContains(filter) || ($0.subtitle?.localizedCaseInsensitiveContains(filter) ?? false)
        }
    }

    var body: some View {
        if filter.isEmpty || !visibleItems.isEmpty {
            row
        }
    }

    private var row: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(collection.name).font(.title3.bold()).padding(.horizontal, 20)
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(visibleItems) { item in
                        ItemCard(item: item, vertical: collection.vertical)
                    }
                    if collection.hasMore || (collection.isSeason && collection.items.isEmpty) {
                        ProgressView()
                            .frame(width: 120, height: collection.vertical ? 240 : 135)
                            .task(id: collection.items.count) { await loadMore() }
                    }
                }
                .padding(.horizontal, 20)
            }
        }
    }

    /// Sets come 15 at a time (and the page sends later rows empty); seasons other than the first come empty.
    private func loadMore() async {
        guard !loadingMore else { return }
        loadingMore = true
        defer { loadingMore = false }
        if collection.isSeason {
            if let season = try? await app.client.season(collection.id) {
                collection.items = season.items
            }
            collection.hasMore = false
        } else if let more = try? await app.client.set(collection.id, offset: collection.items.count) {
            collection.items += more.items
            collection.hasMore = more.hasMore && !more.items.isEmpty
        } else {
            collection.hasMore = false
        }
    }
}

struct ItemCard: View {
    @EnvironmentObject var app: AppModel
    let item: Item
    var vertical = false

    var body: some View {
        TileCard(item, vertical: vertical) {
            app.open(item)
        } menu: {
            if item.play != nil { Button("Play") { app.play(item) } }
            if let pageId = item.pageId { Button("Show Details") { app.path.append(Destination(pageId: pageId, title: item.title)) } }
        }
    }
}


// MARK: - Search

struct SearchView: View {
    @EnvironmentObject var app: AppModel
    @State private var query = ""
    @State private var results: [Item] = []
    @State private var searching = false

    var body: some View {
        VStack(spacing: 0) {
            TextField("Search Disney+", text: $query)
                .textFieldStyle(.roundedBorder)
                .font(.title3)
                .padding(20)
                .onSubmit { Task { await search() } }
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 12)], alignment: .leading, spacing: 16) {
                    ForEach(results) { item in ItemCard(item: item) }
                }
                .padding(.horizontal, 20)
                if searching { ProgressView().padding() }
            }
        }
        .navigationTitle("Search")
    }

    private func search() async {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return }
        searching = true
        results = (try? await app.client.search(query)) ?? []
        searching = false
    }
}
