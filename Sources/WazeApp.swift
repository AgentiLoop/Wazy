//
//  WazeApp.swift
//  Waze
//
//  One window; the Go and Playback menus drive the app model and the player.
//

import SwiftUI

@main
struct WazeApp: App {
    @StateObject private var app = AppModel()

    var body: some Scene {
        Window("Waze", id: "main") {
            ContentView().environmentObject(app)
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appSettings) {
                Button("Sign In to Disney+…") { app.showSignIn = true }
                Button("Sign Out of Disney+") { app.signOut() }
            }
            CommandMenu("Go") {
                ForEach(Array(app.nav.prefix(9).enumerated()), id: \.element) { index, item in
                    Button(item.name) { app.place = .nav(item) }
                        .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
                }
                Button("Search") { app.place = .search }
                    .keyboardShortcut("f", modifiers: .command)
                Divider()
                Button("Back") { app.path.removeLast() }
                    .keyboardShortcut("[", modifiers: .command)
                    .disabled(app.path.isEmpty)
            }
            CommandMenu("Playback") {
                Button(app.player.isPlaying ? "Pause" : "Play") { app.player.playPause() }
                    .keyboardShortcut("p", modifiers: .command)
                    .disabled(app.player.current == nil)
                Button("Skip Back 10 Seconds") { app.player.skip(-10) }
                    .keyboardShortcut(.leftArrow, modifiers: .command)
                    .disabled(app.player.current == nil)
                Button("Skip Ahead 10 Seconds") { app.player.skip(10) }
                    .keyboardShortcut(.rightArrow, modifiers: .command)
                    .disabled(app.player.current == nil)
                Divider()
                Button("Stop") { app.player.stop() }
                    .keyboardShortcut(".", modifiers: .command)
                    .disabled(app.player.current == nil)
            }
        }
    }
}
