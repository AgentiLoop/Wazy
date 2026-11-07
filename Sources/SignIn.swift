//
//  SignIn.swift
//  Waze
//
//  Signing in happens on disneyplus.com itself, in a web view (and the profile is picked there too).
//  The site's SDK keeps its bearer token in localStorage; the app copies it out and uses it for the
//  API. Tokens last four hours, so the same web view (kept off screen, with the site's persistent
//  session) reloads the site to get a fresh one when needed.
//

import SwiftUI
import WebKit

enum DisneyWeb {
    static let home = URL(string: "https://www.disneyplus.com/home")!
    static let login = URL(string: "https://www.disneyplus.com/login")!
    /// The localStorage key the site's BAM SDK stores its access token under.
    static let storageKey = "__bam_sdk_access--disney-svod-3d9324fc_prod"

    static func makeWebView() -> WKWebView {
        let config = WKWebViewConfiguration()
        // The site checks the browser: WebKit's default UA has no "Version/… Safari/…" tail, so add Safari's.
        config.applicationNameForUserAgent = "Version/26.0 Safari/605.1.15"
        config.websiteDataStore = .default()
        return WKWebView(frame: .zero, configuration: config)
    }

    /// Reads the SDK's token out of the page; nil while the site has none (not signed in).
    static func readToken(from webView: WKWebView) async -> (token: String, issuedAt: Double, expiresIn: Double)? {
        let script = "JSON.parse(localStorage.getItem('\(storageKey)') || 'null')"
        guard let result = try? await webView.evaluateJavaScript(script) as? [String: Any],
              let context = result["context"] as? [String: Any],
              let token = context["token"] as? String else { return nil }
        return (token, context["issuedAt"] as? Double ?? Date().timeIntervalSince1970 * 1000,
                context["expiresIn"] as? Double ?? 14400)
    }

    /// Signed in means the site let the user through to the app proper (past login and profile pick).
    static func isInside(_ url: URL?) -> Bool {
        guard let url, url.host == "www.disneyplus.com" else { return false }
        return !["/login", "/identity", "/profiles", "/select-profile"].contains { url.path.hasPrefix($0) }
    }

    @MainActor static func signOut() async {
        let store = WKWebsiteDataStore.default()
        let records = await store.dataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes())
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
                               for: records.filter { $0.displayName.contains("disney") || $0.displayName.contains("bamgrid") })
        Session.clear()
    }
}

/// Gets a fresh token without bothering the user: loads the site off screen and waits for the SDK
/// to store a newer token than the one we have.
@MainActor
final class SessionRefresher: NSObject, WKNavigationDelegate {
    private var webView: WKWebView?

    /// True when a newer token was stored; false when the site wants a sign-in.
    func refresh() async -> Bool {
        let webView = DisneyWeb.makeWebView()
        webView.navigationDelegate = self
        self.webView = webView
        webView.load(URLRequest(url: DisneyWeb.home))
        let before = Session.issuedAt
        for _ in 0..<40 {
            try? await Task.sleep(for: .milliseconds(500))
            if let fresh = await DisneyWeb.readToken(from: webView), fresh.issuedAt > before {
                Session.store(token: fresh.token, issuedAt: fresh.issuedAt, expiresIn: fresh.expiresIn)
                self.webView = nil
                return true
            }
            if webView.url?.path.hasPrefix("/login") == true || webView.url?.path.hasPrefix("/identity") == true { break }
        }
        self.webView = nil
        return false
    }
}

struct SignInView: View {
    let onSignedIn: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Sign in to Disney+ and pick a profile").font(.headline)
                Spacer()
                Button("Cancel") { dismiss() }
            }
            .padding()
            SignInWebView {
                onSignedIn()
                dismiss()
            }
        }
        .frame(width: 960, height: 720)
    }
}

private struct SignInWebView: NSViewRepresentable {
    let onSignedIn: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onSignedIn: onSignedIn) }

    func makeNSView(context: Context) -> WKWebView {
        let webView = DisneyWeb.makeWebView()
        webView.navigationDelegate = context.coordinator
        webView.load(URLRequest(url: DisneyWeb.login))
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        let onSignedIn: () -> Void
        private var done = false
        init(onSignedIn: @escaping () -> Void) { self.onSignedIn = onSignedIn }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            check(webView)
        }

        /// The site is a single-page app: picking a profile changes the URL without a navigation, so look again after a moment.
        private func check(_ webView: WKWebView) {
            Task { @MainActor in
                for _ in 0..<120 where !done {
                    if DisneyWeb.isInside(webView.url), let fresh = await DisneyWeb.readToken(from: webView) {
                        Session.store(token: fresh.token, issuedAt: fresh.issuedAt, expiresIn: fresh.expiresIn)
                        done = true
                        onSignedIn()
                        return
                    }
                    try? await Task.sleep(for: .seconds(1))
                }
            }
        }
    }
}
