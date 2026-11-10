//
//  WazyApp.swift
//  Wazy
//
//  One window; the Go and Playback menus drive the app model and the player.
//

import SwiftUI
import ScreenCaptureKit

@main
struct WazyApp: App {
    @StateObject private var app = AppModel()
    @State private var savingScreenshot = false

    init() { Updater.shared.start() }

    var body: some Scene {
        Window("Wazy", id: "main") {
            ContentView().environmentObject(app)
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .saveItem) {
                Button("Save Window Screenshot to Desktop") {
                    let window = NSApp.keyWindow ?? NSApp.mainWindow
                    Task { await saveScreenshot(of: window) }
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(savingScreenshot)
            }
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { Task { await Updater.shared.check(interactive: true) } }
            }
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
                Toggle("Float on Top", isOn: $app.playerFloats)
                    .keyboardShortcut("t", modifiers: [.command, .control])
                Button("Stop") { app.player.stop() }
                    .keyboardShortcut(".", modifiers: .command)
                    .disabled(app.player.current == nil)
            }
        }
    }

    @MainActor
    private func saveScreenshot(of window: NSWindow?) async {
        guard !savingScreenshot else { return }
        savingScreenshot = true
        defer { savingScreenshot = false }
        do {
            guard let window else {
                throw screenshotError("No Wazy window is available to capture.")
            }
            guard #available(macOS 14.0, *) else {
                throw screenshotError("Saving a window screenshot requires macOS 14 or later.")
            }
            guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
                showScreenRecordingPermissionHelp()
                return
            }
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            guard let captureWindow = content.windows.first(where: {
                $0.windowID == CGWindowID(window.windowNumber)
            }) else {
                throw screenshotError("The Wazy window is not available for screen capture. Make sure it is visible.")
            }
            let filter = SCContentFilter(desktopIndependentWindow: captureWindow)
            let configuration = SCStreamConfiguration()
            configuration.width = Int((filter.contentRect.width * CGFloat(filter.pointPixelScale)).rounded(.up))
            configuration.height = Int((filter.contentRect.height * CGFloat(filter.pointPixelScale)).rounded(.up))
            configuration.showsCursor = false
            configuration.ignoreShadowsSingleWindow = true
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
                throw screenshotError("The screenshot could not be encoded as a PNG.")
            }
            let desktop = try FileManager.default.url(for: .desktopDirectory, in: .userDomainMask,
                                                       appropriateFor: nil, create: false)
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
            let name = "Wazy Screenshot \(formatter.string(from: Date())) \(UUID().uuidString.prefix(8)).png"
            let url = desktop.appendingPathComponent(name)
            try png.write(to: url, options: .atomic)
            let alert = NSAlert()
            alert.messageText = "Screenshot Saved to Desktop"
            alert.informativeText = "\(name)\n\nThe screenshot captures the window and its visible controls. Protected video may appear black."
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Show in Finder")
            if alert.runModal() == .alertSecondButtonReturn {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        } catch {
            let captureError = error as NSError
            if captureError.domain == SCStreamError.errorDomain,
               captureError.code == SCStreamError.Code.userDeclined.rawValue {
                showScreenRecordingPermissionHelp()
                return
            }
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Screenshot Not Saved"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    @MainActor
    private func showScreenRecordingPermissionHelp() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Screen Recording Permission Needed"
        alert.informativeText = "macOS has not made screen capture access available to Wazy. This does not mean you clicked Deny.\n\nOpen System Settings → Privacy & Security → Screen & System Audio Recording (Screen Recording on older macOS versions), enable Wazy, then quit and reopen Wazy before trying again. If Wazy is not listed, use the + button to add the copy of Wazy you are running."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    private func screenshotError(_ message: String) -> NSError {
        NSError(domain: "WazyScreenshot", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
