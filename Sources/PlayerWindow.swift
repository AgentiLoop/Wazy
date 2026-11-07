//
//  PlayerWindow.swift
//  Waze
//
//  The split-out player window, like QuickTime: AVKit's floating controls, its own full screen (green
//  button, AVKit's full-screen button, View > Enter Full Screen), and it can float above other windows.
//  It opens when the TV tab's split-out button is pressed; closing it puts the movie back on the TV tab.
//

import AppKit
import SwiftUI
import Combine

@MainActor
final class PlayerWindowController: NSWindowController, NSWindowDelegate {
    private unowned let app: AppModel
    private var subscriptions: Set<AnyCancellable> = []

    /// Playback > Float on Top. A floating window cannot be full screen, so the level drops to normal
    /// while the window is full screen and comes back when it leaves.
    var isFloating = false { didSet { applyLevel() } }

    init(app: AppModel) {
        self.app = app
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 540),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "Waze"
        window.backgroundColor = .black
        window.collectionBehavior = [.fullScreenPrimary]
        window.isReleasedWhenClosed = false
        window.contentAspectRatio = NSSize(width: 16, height: 9)
        window.contentView = NSHostingView(rootView: PlayerView(player: app.player, inWindow: true).environmentObject(app))
        window.center()
        window.setFrameAutosaveName("Player")
        super.init(window: window)
        window.delegate = self

        // Open while split out with something playing; close otherwise (closing clears splitOut below).
        Publishers.CombineLatest(app.$splitOut, app.player.$current)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] splitOut, current in
                guard let self, let window = self.window else { return }
                if splitOut, let current {
                    window.title = current.title
                    self.showWindow(nil)
                    window.makeKeyAndOrderFront(nil)
                } else if window.isVisible {
                    window.close()
                }
            }
            .store(in: &subscriptions)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func applyLevel() {
        guard let window else { return }
        let fullScreen = window.styleMask.contains(.fullScreen)
        window.level = isFloating && !fullScreen ? .floating : .normal
    }

    func windowWillEnterFullScreen(_ notification: Notification) { window?.level = .normal }
    func windowDidExitFullScreen(_ notification: Notification) { applyLevel() }

    /// Closing the window (red button, ⌘W) puts the movie back on the TV tab; it keeps playing.
    func windowWillClose(_ notification: Notification) {
        app.splitOut = false
    }
}
