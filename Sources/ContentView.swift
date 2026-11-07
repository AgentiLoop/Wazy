//
//  ContentView.swift
//  Waze
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
    case tv

    var title: String {
        switch self {
        case .nav(let item): item.name
        case .search: "Search"
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
    private let refresher = SessionRefresher()

    @Published var nav: [NavItem] = []
    @Published var place: Place? { didSet { if place != .tv { path = [] } } }
    @Published var path: [Destination] = []
    @Published var showSignIn = false
    /// Playback > Float on Top: the split-out player window stays above other windows.
    @Published var playerFloats = false { didSet { player.floatsOnTop = playerFloats } }
    /// Bumped on sign-in/out so the views reload.
    @Published var session = 0

    init() {
        player = PlayerController(service: client)
        Task { await start() }
    }

    /// On launch: refresh an old token quietly if the site still has a session, else ask to sign in.
    private func start() async {
        if Session.needsRefresh, await !refresher.refresh() {
            showSignIn = true
            return
        }
        await loadNavigation()
    }

    func loadNavigation() async {
        do {
            nav = try await client.navigation()
            if place == nil, let first = nav.first { place = .nav(first) }
        } catch {
            // 401/403 for a stale token, 400 for an anonymous one: either way a refresh or sign-in is needed.
            if case DisneyError.http = error {
                if await refresher.refresh() { await loadNavigation() } else { showSignIn = true }
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
        Task {
            await DisneyWeb.signOut()
            nav = []
            place = nil
            path = []
            session += 1
            showSignIn = true
        }
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
        .frame(minWidth: 960, minHeight: 600)
        .sheet(isPresented: $app.showSignIn) {
            SignInView { app.signedIn() }
        }
    }

    @ViewBuilder private var root: some View {
        switch app.place {
        case .search: SearchView()
        case .nav(let item): PageView(pageId: item.pageId, title: item.name)
        case .tv: PlayerView(player: app.player, inWindow: false, title: "Waze")
        case nil: ProgressView()
        }
    }
}

// MARK: - Pages

struct PageView: View {
    @EnvironmentObject var app: AppModel
    let pageId: String
    let title: String
    @State private var page: Page?
    @State private var error: String?

    var body: some View {
        Group {
            if let page {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 24) {
                        if page.play != nil || page.description != nil {
                            header(page)
                        }
                        ForEach(page.collections) { collection in
                            CollectionRow(collection: collection)
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
                Button {
                    app.play(Item(id: page.id, title: page.title, play: play))
                } label: {
                    Label("Play", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
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
    @State private var loadingMore = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(collection.name).font(.title3.bold()).padding(.horizontal, 20)
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(collection.items) { item in
                        ItemCard(item: item, vertical: collection.vertical)
                    }
                    if collection.hasMore || (collection.isSeason && collection.items.isEmpty) {
                        Button {
                            Task { await loadMore() }
                        } label: {
                            if loadingMore { ProgressView() } else { Label("More", systemImage: "ellipsis") }
                        }
                        .frame(width: 120, height: collection.vertical ? 240 : 135)
                        .task { if collection.items.isEmpty { await loadMore() } }
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
