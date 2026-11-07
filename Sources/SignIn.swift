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
import WazKit

enum DisneyWeb {
    static let home = URL(string: "https://www.disneyplus.com/home")!
    static let login = URL(string: "https://www.disneyplus.com/login")!
    /// The localStorage key the site's BAM SDK stores its access token under.
    static let storageKey = "__bam_sdk_access--disney-svod-3d9324fc_prod"

    /// Reads the SDK's token out of the page; nil while the site has none (not signed in).
    static func readToken(from webView: WKWebView) async -> (token: String, issuedAt: Double, expiresIn: Double)? {
        let script = "JSON.parse(localStorage.getItem('\(storageKey)') || 'null')"
        guard let result = try? await webView.evaluateJavaScript(script) as? [String: Any],
              let context = result["context"] as? [String: Any],
              let token = context["token"] as? String, Session.isAccount(token) else { return nil }
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
        let webView = WebSignIn.makeWebView()
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

    var body: some View {
        WebSignInView(title: "Sign in to Disney+ and pick a profile", url: DisneyWeb.login, isSignedIn: { webView in
            // Signed in once the site let the user past login and the profile pick and its SDK has an account token.
            guard DisneyWeb.isInside(webView.url), let fresh = await DisneyWeb.readToken(from: webView) else { return false }
            Session.store(token: fresh.token, issuedAt: fresh.issuedAt, expiresIn: fresh.expiresIn)
            return true
        }, onSignedIn: onSignedIn)
    }
}
