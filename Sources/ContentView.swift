//
//  ContentView.swift
//  Waze
//
//  Sidebar of the site's navigation beside a browse stack of pages (rows of artwork) and search.
//  Playing something covers the browse area with the player until it is closed.
//

import SwiftUI
import AVKit

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
    /// Bumped on sign-in/out so the views reload.
    @Published var session = 0

    init() {
        player = PlayerController(client: client)
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

    /// Starts playback and shows it on the TV tab.
    func play(_ item: Item) {
        player.play(item)
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
            if app.place == .tv {
                PlayerView()
            } else {
                NavigationStack(path: $app.path) {
                    root
                        .navigationDestination(for: Destination.self) { destination in
                            PageView(pageId: destination.pageId, title: destination.title)
                        }
                }
                .id(app.session)
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
        case .nav(let item): PageView(pageId: item.pageId, title: item.name)
        case .tv: PlayerView()
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

    private var size: CGSize { vertical ? CGSize(width: 160, height: 240) : CGSize(width: 240, height: 135) }

    var body: some View {
        Button {
            app.open(item)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Artwork(url: item.artwork(width: Int(size.width) * 2, height: Int(size.height) * 2), title: item.title)
                .frame(width: size.width, height: size.height)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(alignment: .topLeading) {
                    if item.isLive {
                        Text("LIVE").font(.caption2.bold()).padding(4).background(.red, in: RoundedRectangle(cornerRadius: 3)).padding(6)
                    }
                }
                Text(item.title).font(.callout.bold()).lineLimit(1)
                if let subtitle = item.subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .frame(width: size.width)
        }
        .buttonStyle(.plain)
        .help(item.description ?? item.title)
        .contextMenu {
            if item.play != nil { Button("Play") { app.play(item) } }
            if let pageId = item.pageId { Button("Show Details") { app.path.append(Destination(pageId: pageId, title: item.title)) } }
        }
    }
}

/// A tile's image, cached; items with no artwork get their name on a plain tile.
struct Artwork: View {
    let url: URL?
    let title: String
    @State private var image: NSImage?

    private static let cache = NSCache<NSURL, NSImage>()

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else if url == nil {
                LinearGradient(colors: [.indigo.opacity(0.8), .blue.opacity(0.6)], startPoint: .topLeading, endPoint: .bottomTrailing)
                Text(title).font(.title3.bold()).multilineTextAlignment(.center).padding(12)
            } else {
                Rectangle().fill(.quaternary)
            }
        }
        .task(id: url) {
            guard let url else { image = nil; return }
            if let cached = Self.cache.object(forKey: url as NSURL) { image = cached; return }
            image = nil
            if let (data, _) = try? await URLSession.shared.data(from: url), let loaded = NSImage(data: data) {
                Self.cache.setObject(loaded, forKey: url as NSURL)
                image = loaded
            }
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

// MARK: - Player

struct PlayerView: View {
    @EnvironmentObject var app: AppModel

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black
            if let error = app.player.error {
                ContentUnavailableView(error, systemImage: "play.slash")
                    .foregroundStyle(.white)
            } else if app.player.current == nil {
                ContentUnavailableView("Nothing Playing", systemImage: "tv", description: Text("Pick something to watch."))
                    .foregroundStyle(.white)
            } else {
                VideoPlayerView(player: app.player.player)
                if app.player.isLoading { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
            }
            Button {
                app.player.stop()
                app.player.error = nil
            } label: {
                Image(systemName: "xmark.circle.fill").font(.title).foregroundStyle(.white.opacity(0.8))
            }
            .buttonStyle(.plain)
            .padding(12)
            .keyboardShortcut(.escape, modifiers: [])
        }
        .navigationTitle(app.player.current?.title ?? "Waze")
    }
}

/// AVKit's player view: its floating controls include full screen and Picture in Picture.
struct VideoPlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = FocusingPlayerView()
        view.player = player
        view.controlsStyle = .floating
        view.showsFullScreenToggleButton = true
        view.allowsPictureInPicturePlayback = true
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {}
}

/// Takes keyboard focus as soon as it is on screen, so space/arrows drive playback instead of the sidebar.
/// SwiftUI hands focus back to the sidebar after the first attempt, so it keeps claiming it on every
/// layout pass until it actually holds it, and again whenever the window becomes key.
final class FocusingPlayerView: AVPlayerView {
    override var acceptsFirstResponder: Bool { true }
    private var keyObserver: NSObjectProtocol?
    private var claimsLeft = 0

    private var hasFocus: Bool {
        guard let responder = window?.firstResponder as? NSView else { return false }
        return responder === self || responder.isDescendant(of: self)
    }

    private func claimFocus() {
        guard let window, !hasFocus else { return }
        window.makeFirstResponder(self)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let keyObserver { NotificationCenter.default.removeObserver(keyObserver) }
        keyObserver = nil
        guard let window else { return }
        claimsLeft = 10
        claimFocus()
        DispatchQueue.main.async { [weak self] in self?.claimFocus() }
        keyObserver = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
            self?.claimFocus()
        }
    }

    override func layout() {
        super.layout()
        guard claimsLeft > 0 else { return }
        claimFocus()
        if hasFocus { claimsLeft = 0 } else { claimsLeft -= 1 }
    }

    override func mouseDown(with event: NSEvent) {
        claimFocus()
        super.mouseDown(with: event)
    }

    deinit {
        if let keyObserver { NotificationCenter.default.removeObserver(keyObserver) }
    }
}
