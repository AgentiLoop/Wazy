//
//  WazyiOSApp.swift
//  Wazy (iPhone)
//
//  The iPhone app: tabs for Browse (the site's navigation), Sports and Search over the same app model,
//  pages and search the Mac app uses. Playing something opens the full-screen player (AVKit's, with
//  Picture in Picture); dismissing it keeps the movie in Picture in Picture or stops it.
//

import SwiftUI
import WazKit

@main
struct WazyiOSApp: App {
    @StateObject private var app = AppModel()

    var body: some Scene {
        WindowGroup {
            PhoneContentView().environmentObject(app)
        }
    }
}

struct PhoneContentView: View {
    @EnvironmentObject var app: AppModel
    @State private var tab = Tab.browse

    enum Tab { case browse, sports, search }
    var body: some View {
        TabView(selection: $tab) {
            stack(.browse) { BrowseList() }
                .tabItem { Label("Browse", systemImage: "house") }
                .tag(Tab.browse)
            stack(.sports) { sports }
                .tabItem { Label("Sports", systemImage: "sportscourt") }
                .tag(Tab.sports)
            stack(.search) { SearchView() }
                .tabItem { Label("Search", systemImage: "magnifyingglass") }
                .tag(Tab.search)
        }
        // Every tab pushes onto the app's one path (tiles append to it), so a tab switch starts over.
        .onChange(of: tab) { app.path = [] }
        .id(app.session)
        .sheet(isPresented: $app.showSignIn) {
            SignInView { app.signedIn() }
                .interactiveDismissDisabled()
        }
        .fullScreenCover(isPresented: $app.showPlayer) {
            PhonePlayer()
        }
    }

    /// Tiles push onto the app's one path; only the selected tab's stack shows it.
    private func stack(_ which: Tab, @ViewBuilder _ root: () -> some View) -> some View {
        NavigationStack(path: Binding(get: { tab == which ? app.path : [] },
                                      set: { if tab == which { app.path = $0 } })) {
            root()
                .navigationDestination(for: Destination.self) { destination in
                    if destination.live {
                        NavPageView(pageId: destination.pageId, title: destination.title)
                            .searchable(text: Binding(get: { app.liveSearch.text }, set: { app.liveSearch.text = $0 }),
                                        prompt: "Search channels and shows")
                    } else {
                        PageView(pageId: destination.pageId, title: destination.title)
                    }
                }
        }
    }

    @ViewBuilder private var sports: some View {
        if let item = app.nav.first(where: { $0.name.lowercased() == "sports" })
            ?? app.nav.first(where: { $0.name.lowercased() == "espn" }) {
            PageView(pageId: item.pageId, title: "Sports")
        } else if app.nav.isEmpty {
            ProgressView()
        } else {
            ContentUnavailableView("Sports Unavailable", systemImage: "sportscourt",
                                   description: Text("Disney+ has not provided a Sports or ESPN page for this profile."))
        }
    }
}

/// The site's navigation as a list; each entry opens its page.
private struct BrowseList: View {
    @EnvironmentObject var app: AppModel

    var body: some View {
        List {
            ForEach(app.nav) { item in
                NavigationLink(value: Destination(pageId: item.pageId, title: item.name, live: true)) { Label(item.name, systemImage: item.icon) }
            }
            if !app.nav.isEmpty {
                Section {
                    Button(role: .destructive) { app.signOut() } label: {
                        Label("Sign Out of Disney+", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                }
            }
        }
        .overlay { if app.nav.isEmpty && !app.showSignIn { ProgressView() } }
        .navigationTitle("Wazy")
    }
}

/// The movie, in AVKit's full screen from the start; AVKit's own ✕ closes this (a live channel picked in
/// the TV guide is paused, anything else stops).
/// Picture in Picture keeps it going over other apps. A ✕ of ours shows only when there is no video
/// (an error), since then AVKit's controls are not there.
private struct PhonePlayer: View {
    @EnvironmentObject var app: AppModel

    var body: some View {
        PlayerView(player: app.player, inWindow: true, title: "Wazy", onClose: close)
            .ignoresSafeArea()
            .overlay(alignment: .topLeading) {
                if app.player.current == nil || app.player.error != nil {
                    Button(action: close) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title)
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .black.opacity(0.5))
                    }
                    .padding()
                }
            }
            .statusBarHidden()
    }

    private func close() {
        app.player.close()
        app.showPlayer = false
    }
}
