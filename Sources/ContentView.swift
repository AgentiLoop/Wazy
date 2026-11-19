//
//  ContentView.swift
//  Wazy
//
//  Sidebar of the site's navigation beside a browse stack of pages (rows of artwork) and search.
//  Playing something shows the player on the TV tab (WazKit's PlayerView); the player can split the
//  movie out into its own window.
//

import SwiftUI
import AVKit
import Combine
import os
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
    /// A sidebar page opened from the iPhone's Browse list: it gets the live search field.
    var live = false
}

/// The last episode or movie played and how far in, kept between launches.
struct LastPlayed: Codable {
    let id: String
    let title: String
    let subtitle: String?
    let play: PlayAction
    /// Seconds in.
    var position: Double
    /// The player was still up when this was saved (not stopped): the next launch carries straight on.
    var open = true
}

@MainActor
final class AppModel: ObservableObject {
    let client = DisneyClient()
    let player: PlayerController

    @Published var nav: [NavItem] = []
    @Published var place: Place? { didSet { if place != .tv { path = [] }; if place != oldValue { liveSearch.text = "" } } }
    @Published var path: [Destination] = []
    @Published var showSignIn = false
    /// Live page search text; the field lives in the window toolbar, left of Sign Out. Kept in its own
    /// object so typing does not re-render the window (and the toolbar), which would drop the field's focus.
    let liveSearch = LiveSearch()
    /// The search field shows on every page of the sidebar (Disney+, Hulu, ESPN, Live, Sports...).
    var liveSelected: Bool {
        switch place {
        case .nav, .sports: true
        default: false
        }
    }
    /// Playback > Float on Top: the split-out player window stays above other windows.
    @Published var playerFloats = false { didSet { player.floatsOnTop = playerFloats } }
    /// Bumped on sign-in/out so the views reload.
    @Published var session = 0

    init() {
        player = PlayerController(service: client)
        player.onEnd = { [weak self] in self?.playNext(atEnd: true) }
        player.onClose = { [weak self] in self?.closePlayer() }
        // Once a second of playback: how far in the remembered episode or movie is, and whether its end
        // credits have started (then the next episode plays).
        timeObserver = player.player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 1, preferredTimescale: 1), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                // Not while a stream is loading: a time that arrives then belongs to the one before it.
                guard let self, !self.player.isLoading, self.player.current?.id == self.last?.id, time.seconds >= 1 else { return }
                self.last?.position = time.seconds
                if let credits = self.credits, credits.id == self.player.current?.id, time.seconds >= credits.start {
                    self.credits = nil
                    self.playNext(atEnd: false)
                }
            }
        }
        // The TV tab draws from this model, so it hears when what is playing changes. Stopped (Stop, a
        // sign-out, an error) also means the next launch does not start it again.
        currentWatch = player.$current.dropFirst().sink { [weak self] current in
            if current == nil { self?.last?.open = false }
            self?.objectWillChange.send()
        }
        Task { await start() }
    }

    /// On launch: refresh an old token quietly with the stored refresh token, then saved Keychain credentials once, else ask to sign in.
    /// Then, if the app was quit with the player still up, carry straight on with what was playing.
    private func start() async {
        if Session.needsRefresh, await !DisneyAuth.refresh(), await !DisneyAuth.recover() {
            showSignIn = true
            return
        }
        await loadNavigation()
        if !nav.isEmpty, last?.open == true { resume() }
    }

    func loadNavigation(retry: Bool = true) async {
        do {
            nav = try await client.navigation()
            if place == nil, let first = nav.first { place = .nav(first) }
        } catch {
            // 401/403 for a stale token, 400 for an anonymous one: either way a refresh or sign-in is needed.
            if case DisneyError.http(let status, let message) = error {
                var recovered = false
                if retry { recovered = await DisneyAuth.refresh() }
                if retry, !recovered { recovered = await DisneyAuth.recover() }
                if recovered {
                    await loadNavigation(retry: false)
                } else {
                    // Say why instead of silently showing sign-in again: a fresh sign-in that Disney+ still
                    // refuses here looped between the sign-in sheet and the spinner with nothing to go on.
                    let detail = message.trimmingCharacters(in: .whitespacesAndNewlines)
                    Self.log.error("Menu refused after sign-in: HTTP \(status, privacy: .public) \(detail, privacy: .public)")
                    signInProblem = "Disney+ signed you in but refused to load your account (error \(status)"
                        + (detail.isEmpty ? ")." : ": \(detail.prefix(160)))." )
                        + " Try signing in at disneyplus.com and accept anything it asks, then sign in here again."
                    DisneyAuth.stopRecovery()
                    showSignIn = true
                }
            }
        }
    }

    /// Why the sign-in sheet came back after a sign-in, shown on it; nil for a plain sign-in.
    @Published var signInProblem: String?
    private static let log = Logger(subsystem: "com.starplayrx.wazy", category: "SignIn")

    func signedIn() {
        signInProblem = nil
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

    /// The iPhone's full-screen player is up.
    @Published var showPlayer = false

    /// The last episode or movie played, saved as it plays so it can carry on after the player or the app is quit.
    private(set) var last: LastPlayed? = UserDefaults.standard.data(forKey: "lastPlayed")
        .flatMap({ try? JSONDecoder().decode(LastPlayed.self, from: $0) }) {
        didSet { UserDefaults.standard.set(last.flatMap { try? JSONEncoder().encode($0) }, forKey: "lastPlayed") }
    }
    /// Where the user was when they picked what is playing: the app goes back there when nothing is left to play.
    private var origin: (place: Place?, path: [Destination])?
    private var timeObserver: Any?
    private var currentWatch: AnyCancellable?

    /// Starts playback and shows it on the TV tab (or in the split-out window, if that is open);
    /// on iPhone, in the full-screen player. `guideChannel`: the channel, when it was picked in the TV guide.
    func play(_ item: Item, guideChannel: String? = nil) {
        guard let action = item.play else { return }
        self.guideChannel = guideChannel
        play(NowPlaying(id: item.id, title: item.title, subtitle: item.subtitle), action, show: true)
    }

    /// Carries on with the last episode or movie from where it was left.
    func resume() {
        guard let last else { return }
        guideChannel = nil
        play(NowPlaying(id: last.id, title: last.title, subtitle: last.subtitle), last.play, show: true)
    }

    /// The channel last played from the TV guide: the guide highlights it and opens scrolled to it.
    @Published private(set) var guideChannel: String?

    /// The player's ✕. A live channel picked in the TV guide is paused and the app is back on the guide, which
    /// opens at that channel and keeps it highlighted. Anything else stops.
    private func closePlayer() {
        guard guideChannel != nil, player.current != nil else { player.stop(); return }
        player.pause()
        #if os(macOS)
        if place == .tv, let origin {
            place = origin.place
            path = origin.path
        }
        #else
        showPlayer = false
        #endif
    }

    /// An episode or movie becomes the remembered one; played again, it carries on from where it was left.
    /// `show` brings the player up and notes where the user was.
    private func play(_ what: NowPlaying, _ action: PlayAction, show: Bool) {
        let same = last.map { $0.play.resourceId == action.resourceId || ($0.play.contentId != nil && $0.play.contentId == action.contentId) } ?? false
        let position = same ? last?.position ?? 0 : 0
        if action.isLinear {
            last?.open = false
        } else {
            last = LastPlayed(id: what.id, title: what.title, subtitle: what.subtitle, play: action, position: position)
        }
        credits = nil
        player.play(what) { [client, weak self] in
            let (playback, credits) = try await client.playback(resourceId: action.resourceId)
            await MainActor.run { [weak self] in self?.credits = credits.map { (what.id, $0) } }
            guard position > 0, !playback.isLive else { return playback }
            return Playback(streamURL: playback.streamURL, licenseURL: playback.licenseURL, certificateURL: playback.certificateURL,
                            resume: position, isLive: false, skips: playback.skips, findSkips: playback.findSkips)
        }
        guard show else { return }
        #if os(macOS)
        if place != .tv {
            origin = (place, path)
            place = .tv
        }
        #else
        showPlayer = true
        #endif
    }

    /// Where the end credits of what is playing start, in seconds (from the playback answer). Cleared once
    /// the playhead has reached it, so the next episode is asked for once.
    private var credits: (id: String, start: Double)?

    /// The next episode plays: the next in the season, or the next season's first. This is called when the
    /// end credits start, and again at the very end (`atEnd`) for anything that has no credits mark. With no
    /// episode left the credits play on, and at the end the player closes and the app is back where the user
    /// picked what was playing.
    private func playNext(atEnd: Bool) {
        guard let finished = player.current else { return }
        let contentId = last?.id == finished.id ? last?.play.contentId : nil
        Task {
            var next: Item?
            if let contentId {
                // The question could not be asked (no network, say): the player stays as it is.
                do { next = try await client.nextEpisode(after: contentId) } catch { return }
            }
            guard player.current == finished else { return }
            if let next, let action = next.play {
                play(NowPlaying(id: next.id, title: next.title, subtitle: next.subtitle), action, show: false)
                return
            }
            guard atEnd else { return }
            last = nil
            player.stop()
            #if os(macOS)
            if place == .tv, let origin {
                place = origin.place
                path = origin.path
            }
            origin = nil
            #else
            showPlayer = false
            #endif
        }
    }

    func signOut() {
        player.stop()
        last = nil
        DisneyAuth.signOut()
        nav = []
        place = nil
        path = []
        session += 1
        showSignIn = true
    }
}

#if os(macOS)
struct ContentView: View {
    @EnvironmentObject var app: AppModel
    @State private var columns = NavigationSplitViewVisibility.automatic

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
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
        .background(FullScreenCapable())
        .fullScreenSidebar($columns)
        .hidesToolbarInFullScreen()
        .sheet(isPresented: $app.showSignIn) {
            SignInView(problem: app.signInProblem) { app.signedIn() }
        }
    }

    @ViewBuilder private var root: some View {
        switch app.place {
        case .search: SearchView()
        case .sports:
            if let item = app.nav.first(where: { $0.name.lowercased() == "sports" })
                ?? app.nav.first(where: { $0.name.lowercased() == "espn" }) {
                PageView(pageId: item.pageId, title: "Sports", searchable: true, search: app.liveSearch)
            } else {
                ContentUnavailableView("Sports Unavailable", systemImage: "sportscourt",
                                       description: Text("Disney+ has not provided a Sports or ESPN page for this profile."))
            }
        case .nav(let item): NavPageView(pageId: item.pageId, title: item.name)
        case .tv: ZStack {
            Color.black
            if let error = app.player.error {
                ContentUnavailableView(error, systemImage: "play.slash")
                    .foregroundStyle(.white)
            } else if app.player.current == nil {
                ContentUnavailableView {
                    Label("Nothing Playing", systemImage: "tv")
                } description: {
                    Text("Pick something to watch.")
                } actions: {
                    if let last = app.last { Button("Resume \(last.title)") { app.resume() } }
                }
                .foregroundStyle(.white)
            } else {
                PlayerContainer(controller: app.player)
            }
        }
        .navigationTitle(app.player.current?.title ?? "Wazy")
        case nil: ProgressView()
        }
    }
}
#endif

// MARK: - Pages

/// A page of the sidebar; the search field's text filters its tiles. Live has two faces, as on the site:
/// Browse (the page, which has the most) and Guide (the channels with what they air in the next hours).
/// The one last picked is the one shown next time.
struct NavPageView: View {
    @EnvironmentObject var app: AppModel
    let pageId: String
    let title: String
    @AppStorage("liveGuide") private var showsGuide = false

    private var isLive: Bool { app.nav.contains { $0.pageId == pageId && $0.name.lowercased() == "live" } }

    var body: some View {
        if isLive {
            VStack(spacing: 0) {
                Picker(title, selection: $showsGuide) {
                    Text("Browse").tag(false)
                    Text("Guide").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 240)
                .padding(.vertical, 10)
                if showsGuide {
                    GuideView(search: app.liveSearch, playing: app.guideChannel) { start, end in
                        try await app.client.guide(from: start, to: end)
                    } onSelect: { channel, program in
                        Task {
                            // The listing says what is on; what plays it comes with a second call.
                            guard let action = try? await app.client.guidePlayAction(listing: program.id) else { return }
                            app.play(Item(id: program.id, title: program.title, play: action), guideChannel: channel.id)
                        }
                    }
                    .id(app.session)
                } else {
                    PageView(pageId: pageId, title: title, searchable: true, search: app.liveSearch)
                }
            }
            .navigationTitle(title)
        } else {
            PageView(pageId: pageId, title: title, searchable: true, search: app.liveSearch)
        }
    }
}

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
                        Group {
                            #if os(macOS)
                            Artwork(url: item.artwork(width: 960, height: 540), title: item.title)
                                .frame(width: 480, height: 270)
                            #else
                            // A 16:9 box the artwork fills: the image alone would grow to any height offered (landscape).
                            Color.clear
                                .aspectRatio(16 / 9, contentMode: .fit)
                                .frame(maxWidth: 480)
                                .overlay { Artwork(url: item.artwork(width: 960, height: 540), title: item.title) }
                            #endif
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay {
                            Image(systemName: "play.circle.fill").font(.system(size: 56))
                                .foregroundStyle(.white).shadow(radius: 6)
                        }
                        .tileFocusEffect()
                        Text("Play").font(.headline)
                    }
                    .contentShape(Rectangle())
                }
                .tileButtonStyle()
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
                .roundedFields()
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
