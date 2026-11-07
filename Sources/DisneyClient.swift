//
//  DisneyClient.swift
//  Waze
//
//  Disney+'s web API — the same calls disneyplus.com's own player makes: the "explore" API on
//  disney.api.edge.bamgrid.com for browsing and search, disney.playback.edge.bamgrid.com for the
//  stream and its FairPlay keys. Auth is a bearer token: the one the site's SDK keeps in
//  localStorage after signing in, copied out of the sign-in web view and kept in UserDefaults.
//

import Foundation
import WazKit

/// The bearer token from disneyplus.com, remembered between launches.
struct Session {
    static let tokenKey = "accessToken"
    static let issuedKey = "tokenIssuedAt"
    static let expiresKey = "tokenExpiresIn"

    static var token: String? { UserDefaults.standard.string(forKey: tokenKey) }
    /// When the site's SDK issued the token (ms since 1970, as the SDK stores it).
    static var issuedAt: Double { UserDefaults.standard.double(forKey: issuedKey) }
    static var expiresAt: Date {
        Date(timeIntervalSince1970: issuedAt / 1000 + UserDefaults.standard.double(forKey: expiresKey))
    }
    static var isSignedIn: Bool { token != nil }
    /// Tokens last 4 hours; treat the last 10 minutes as expired so a refresh happens first.
    static var needsRefresh: Bool { token == nil || !isAccount(token!) || expiresAt.timeIntervalSinceNow < 600 }

    /// The site's SDK stores a token even before anyone signs in (an anonymous device token, "subt": "anonymous");
    /// the API answers 400 to those, so only an account token counts.
    static func isAccount(_ token: String) -> Bool {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return false }
        var b64 = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64),
              let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return claims["subt"] as? String != "anonymous"
    }

    static func store(token: String, issuedAt: Double, expiresIn: Double) {
        UserDefaults.standard.set(token, forKey: tokenKey)
        UserDefaults.standard.set(issuedAt, forKey: issuedKey)
        UserDefaults.standard.set(expiresIn, forKey: expiresKey)
    }

    static func clear() {
        for key in [tokenKey, issuedKey, expiresKey] { UserDefaults.standard.removeObject(forKey: key) }
    }
}

actor DisneyClient: StreamingService {
    nonisolated var name: String { "Disney+" }

    private static let explore = "https://disney.api.edge.bamgrid.com/explore/v1.12"
    private static let playback = "https://disney.playback.edge.bamgrid.com"
    private static let certificateURL = URL(string: "https://playback-certs.bamgrid.com/static/v1.0/disney/fairplay.cer")!
    private static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"

    private let session: URLSession
    private var certificate: Data?

    init() {
        let config = URLSessionConfiguration.default
        config.httpAdditionalHeaders = [
            "User-Agent": Self.userAgent,
            // The services refuse requests that don't say which SDK/app they come from.
            "X-BAMSDK-Client-ID": "disney-svod-3d9324fc",
            "X-BAMSDK-Platform": "browser",
            "X-BAMSDK-Version": "32.0",
            "X-Application-Version": "1.1.2",
            "X-DSS-Edge-Accept": "vnd.dss.edge+json; version=2",
        ]
        session = URLSession(configuration: config)
    }

    // MARK: Browse

    /// The sidebar: the site's global navigation flattened (For You, Disney+, Hulu, ESPN, Live, Watchlist, Movies…).
    func navigation() async throws -> [NavItem] {
        let result = try await json("GET", URL(string: "\(Self.explore)/globalNav")!)
        let nav = (result["data"] as? [String: Any])?["nav"] as? [String: Any]
        var items = [NavItem]()
        func walk(_ node: [String: Any]) {
            if let item = NavItem(json: node) { items.append(item) }
            for child in node["children"] as? [[String: Any]] ?? [] { walk(child) }
        }
        if let nav { walk(nav) }
        return items
    }

    func page(_ id: String) async throws -> Page {
        var c = URLComponents(string: "\(Self.explore)/page/\(id)")!
        c.queryItems = [.init(name: "disableSmartFocus", value: "true"), .init(name: "enhancedContainersLimit", value: "15"),
                        .init(name: "limit", value: "15")]
        let result = try await json("GET", c.url!)
        guard let page = (result["data"] as? [String: Any])?["page"] as? [String: Any] else {
            throw DisneyError.badResponse("page")
        }
        return Page(json: page)
    }

    /// A page of a set (a row), from `offset`.
    func set(_ id: String, offset: Int) async throws -> Collection? {
        let result = try await json("GET", URL(string: "\(Self.explore)/set/\(id)?limit=15&offset=\(offset)")!)
        return ((result["data"] as? [String: Any])?["set"] as? [String: Any]).flatMap(Collection.init(json:))
    }

    /// A season's episodes.
    func season(_ id: String) async throws -> Collection? {
        let result = try await json("GET", URL(string: "\(Self.explore)/season/\(id)?limit=60&offset=0")!)
        return ((result["data"] as? [String: Any])?["season"] as? [String: Any]).flatMap(Collection.init(json:))
    }

    func search(_ query: String) async throws -> [Item] {
        var c = URLComponents(string: "\(Self.explore)/search")!
        c.queryItems = [.init(name: "query", value: query)]
        let result = try await json("GET", c.url!)
        let page = (result["data"] as? [String: Any])?["page"] as? [String: Any]
        let containers = page?["containers"] as? [[String: Any]] ?? []
        return containers.flatMap { ($0["items"] as? [[String: Any]] ?? []).compactMap(Item.init(json:)) }
    }

    // MARK: Playback

    /// The stream for a playback action's resource id; "cbcs-regular" is the FairPlay (SAMPLE-AES) scenario Safari gets.
    func playback(resourceId: String) async throws -> Playback {
        let body: [String: Any] = [
            "playback": [
                "attributes": [
                    "resolution": ["max": ["1920x1080"]], "protocol": "HTTPS", "assetInsertionStrategy": "SGAI",
                    "playbackInitiationContext": "ONLINE", "frameRates": [60], "slugDuration": "SLUG_500_MS",
                ],
                "adTracking": ["limitAdTrackingEnabled": "NOT_SUPPORTED", "deviceAdId": "00000000-0000-0000-0000-000000000000"],
                "tracking": ["playbackSessionId": UUID().uuidString.lowercased()],
            ],
            "playbackId": resourceId,
        ]
        let result = try await json("POST", URL(string: "\(Self.playback)/v7/playback/cbcs-regular")!, body: body,
                                    accept: "application/vnd.media-service+json", extraHeaders: ["X-DSS-Feature-Filtering": "true"])
        let stream = result["stream"] as? [String: Any]
        let sources = stream?["sources"] as? [[String: Any]] ?? []
        guard let url = ((sources.first?["complete"] as? [String: Any])?["url"] as? String).flatMap(URL.init(string:)) else {
            throw DisneyError.badResponse((result["errors"] as? [[String: Any]])?.first?["description"] as? String ?? "playback")
        }
        let security = (stream?["attributes"] as? [String: Any])?["security"] as? [String: Any]
        let linear = security?["drmEndpointKey"] as? String == "linear"
        let position = (result["playhead"] as? [String: Any])?["position"] as? Double ?? 0
        return Playback(streamURL: url,
                        licenseURL: URL(string: "\(Self.playback)/fairplay/v1/\(linear ? "channel/" : "")obtain-license")!,
                        certificateURL: Self.certificateURL,
                        resume: position, isLive: stream?["streamingType"] as? String == "LIVE")
    }

    /// The FairPlay application certificate (DER), cached.
    func certificate(_ url: URL) async throws -> Data {
        if let certificate { return certificate }
        let (data, _) = try await session.data(from: url)
        certificate = data
        return data
    }

    /// SPC in, CKC out, both raw bytes.
    func license(_ url: URL, spc: Data) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(Session.token ?? "")", forHTTPHeaderField: "Authorization")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        request.httpBody = spc
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw DisneyError.http(status, String(decoding: data.prefix(200), as: UTF8.self)) }
        return data
    }

    /// Key URIs look like "skd://<base64 json>"; the license server wants that base64 part (the URI's host).
    nonisolated func contentIdentifier(forKeyURI uri: String) -> Data {
        Data(uri.replacingOccurrences(of: "skd://", with: "").utf8)
    }

    // MARK: HTTP

    private func json(_ method: String, _ url: URL, body: [String: Any]? = nil, accept: String = "application/json",
                      extraHeaders: [String: String] = [:]) async throws -> [String: Any] {
        guard let token = Session.token else { throw DisneyError.http(401, "") }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(accept, forHTTPHeaderField: "Accept")
        for (key, value) in extraHeaders { request.setValue(value, forHTTPHeaderField: key) }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DisneyError.http(status, String(decoding: data.prefix(200), as: UTF8.self))
        }
        guard (200..<300).contains(status) else {
            let error = (object["errors"] as? [[String: Any]])?.first
            throw DisneyError.http(status, error?["description"] as? String ?? error?["code"] as? String ?? "")
        }
        return object
    }
}

enum DisneyError: LocalizedError {
    case http(Int, String)
    case badResponse(String)

    var errorDescription: String? {
        switch self {
        case .http(let status, let message): status == 401 || status == 403 ? "Not signed in to Disney+." : "Disney+ answered \(status): \(message)"
        case .badResponse(let what): "Unexpected answer from Disney+ (\(what))."
        }
    }
}
