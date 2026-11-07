//
//  PlayerWindow.swift
//  Waze
//
//  The movie plays in its own window, like QuickTime: it goes full screen on its own (green button,
//  AVKit's full-screen button, View > Enter Full Screen) and can float above other windows.
//  Closing it stops playback; stopping playback closes it.
//

import AppKit
import SwiftUI
import Combine

@MainActor
final class PlayerWindowController: NSWindowController, NSWindowDelegate {
    private let player: PlayerController
    private var subscriptions: Set<AnyCancellable> = []
    private var closing = false

    /// Playback > Float on Top. A floating window cannot be full screen, so the level drops to normal
    /// while the window is full screen and comes back when it leaves.
    var isFloating = false { didSet { applyLevel() } }

    init(app: AppModel) {
        player = app.player
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 540),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "Waze"
        window.backgroundColor = .black
        window.collectionBehavior = [.fullScreenPrimary]
        window.isReleasedWhenClosed = false
        window.contentAspectRatio = NSSize(width: 16, height: 9)
        window.contentView = NSHostingView(rootView: PlayerView().environmentObject(app))
        window.center()
        window.setFrameAutosaveName("Player")
        super.init(window: window)
        window.delegate = self

        player.$current
            .receive(on: DispatchQueue.main)
            .sink { [weak self] current in
                guard let self, let window = self.window else { return }
                if let current {
                    window.title = current.title
                    self.showWindow(nil)
                    window.makeKeyAndOrderFront(nil)
                } else if !self.closing, self.player.error == nil, window.isVisible {
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

    func windowWillClose(_ notification: Notification) {
        closing = true
        player.stop()
        player.error = nil
        closing = false
    }
}
