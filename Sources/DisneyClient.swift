//
//  DisneyClient.swift
//  Wazy
//
//  Disney+'s web API — the same calls disneyplus.com's own player makes: the "explore" API on
//  disney.api.edge.bamgrid.com for browsing and search, disney.playback.edge.bamgrid.com for the
//  stream and its FairPlay keys. Auth is a bearer token from the sign-in API (SignIn.swift),
//  kept in UserDefaults.
//

import Foundation
import ImageIO
import Vision
import WazKit

/// The bearer token from Disney+'s sign-in API, remembered between launches.
struct Session {
    static let tokenKey = "accessToken"
    static let issuedKey = "tokenIssuedAt"
    static let expiresKey = "tokenExpiresIn"
    static let refreshKey = "refreshToken"

    static var token: String? { UserDefaults.standard.string(forKey: tokenKey) }
    static var refreshToken: String? { UserDefaults.standard.string(forKey: refreshKey) }
    /// When the token was stored (ms since 1970).
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

    static func store(token: String, refreshToken: String?, expiresIn: Double) {
        UserDefaults.standard.set(token, forKey: tokenKey)
        UserDefaults.standard.set(Date().timeIntervalSince1970 * 1000, forKey: issuedKey)
        UserDefaults.standard.set(expiresIn, forKey: expiresKey)
        if let refreshToken { UserDefaults.standard.set(refreshToken, forKey: refreshKey) }
    }

    static func clear() {
        for key in [tokenKey, issuedKey, expiresKey, refreshKey] { UserDefaults.standard.removeObject(forKey: key) }
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

    // MARK: Guide

    /// The live guide's calls, at the version of the explore API the site makes them with (the version the
    /// rest of this client uses answers the first two but has no hydration).
    private static let guide = "https://disney.api.edge.bamgrid.com/explore/v1.21"

    /// The live guide: every channel with what it airs between the two times.
    func guide(from start: Date, to end: Date) async throws -> [GuideChannel] {
        let views = try await json("GET", URL(string: "\(Self.guide)/guide/views")!)
        let view = ((views["data"] as? [String: Any])?["views"] as? [[String: Any]])?.first
        let channels = view?["channels"] as? [[String: Any]] ?? []
        let ids = channels.compactMap { $0["id"] as? String }
        guard !ids.isEmpty else { return [] }
        let formatter = ISO8601DateFormatter()
        let listings = try await json("POST", URL(string: "\(Self.guide)/guide/listings")!, body: [
            "startTime": formatter.string(from: start), "endTime": formatter.string(from: end),
            "channelIds": ids, "includeVisuals": true,
        ])
        let airing = (listings["data"] as? [String: Any])?["channels"] as? [String: Any] ?? [:]
        func text(_ value: Any?) -> String? { (value as? [String: Any])?["text"] as? String }
        return channels.compactMap { channel in
            guard let id = channel["id"] as? String else { return nil }
            // The logo is the channel's watermark, trimmed to its drawing.
            let watermark = ((channel["artwork"] as? [String: Any])?["standard"] as? [String: Any])?["watermark"] as? [String: Any]
            let image = (watermark?.values.first as? [String: Any])?["imageId"] as? String
            let programs = (airing[id] as? [[String: Any]] ?? []).compactMap { listing -> GuideProgram? in
                let visuals = listing["visuals"] as? [String: Any]
                guard let id = listing["id"] as? String, let title = text(visuals?["title"]),
                      let start = (listing["startTime"] as? String).flatMap(formatter.date(from:)),
                      let end = (listing["endTime"] as? String).flatMap(formatter.date(from:)) else { return nil }
                return GuideProgram(id: id, title: title, subtitle: text(visuals?["subtitle"]), start: start, end: end)
            }
            return GuideChannel(id: id, name: text(channel["name"]) ?? "",
                                logo: image.flatMap { URL(string: "https://disney.images.edge.bamgrid.com/ripcut-delivery/v2/variant/disney/\($0)/trim?format=png&max=320%7C120") },
                                programs: programs)
        }
    }

    /// What plays a guide listing that is on now: its "watch live" action. The listing itself carries none;
    /// the site asks for it when the listing is clicked, and so does this.
    func guidePlayAction(listing id: String) async throws -> PlayAction? {
        let result = try await json("POST", URL(string: "\(Self.guide)/hydration")!, body: ["context": "guide", "ids": [id]])
        let item = ((result["data"] as? [String: Any])?["itemsById"] as? [String: Any])?[id] as? [String: Any]
        let actions = (item?["modalAction"] as? [String: Any])?["actions"] as? [[String: Any]] ?? []
        return actions.lazy.compactMap(PlayAction.init(json:)).first
    }

    // MARK: Playback

    /// The episode that follows `contentId` in its series: the next one in the season, or the next season's
    /// first after a season's last. Nil when none is left (after a series' last episode, and after a movie,
    /// the up-next list is only suggestions, which are not marked sequential).
    func nextEpisode(after contentId: String) async throws -> Item? {
        var c = URLComponents(string: "\(Self.explore)/upNext")!
        c.queryItems = [.init(name: "contentId", value: contentId)]
        let result = try await json("GET", c.url!)
        let items = ((result["data"] as? [String: Any])?["upNext"] as? [String: Any])?["items"] as? [[String: Any]] ?? []
        return items.first { $0["sequentialEpisode"] as? Bool == true }
            .flatMap { $0["item"] as? [String: Any] }.flatMap(Item.init(json:))
    }

    /// The stream for a playback action's resource id; "cbcs-regular" is the FairPlay (SAMPLE-AES) scenario Safari gets.
    /// `credits`: seconds in at which the end credits start (the answer's editorial mark "FFEC", first frame of
    /// end credits), when it has one.
    func playback(resourceId: String) async throws -> (playback: Playback, credits: Double?) {
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
        // VOD has a "complete" playlist; live channels only a "slide" (sliding-window) one.
        let source = sources.first?["complete"] ?? sources.first?["slide"]
        guard let url = ((source as? [String: Any])?["url"] as? String).flatMap(URL.init(string:)) else {
            throw DisneyError.badResponse((result["errors"] as? [[String: Any]])?.first?["description"] as? String ?? "playback")
        }
        let security = (stream?["attributes"] as? [String: Any])?["security"] as? [String: Any]
        let linear = security?["drmEndpointKey"] as? String == "linear"
        let position = (result["playhead"] as? [String: Any])?["position"] as? Double ?? 0
        let editorial = stream?["editorial"] as? [[String: Any]] ?? []
        /// Seconds in of an editorial mark ("intro_start", "recap_end", "FFEC"…).
        func mark(_ label: String) -> Double? {
            (editorial.first { $0["label"] as? String == label }?["offsetMillis"] as? Double).map { $0 / 1000 }
        }
        // A recap ("Previously on…") and an intro are each marked with a start and an end.
        let skips = [("recap", "Skip Recap"), ("intro", "Skip Intro")].compactMap { kind, title -> Skip? in
            guard let start = mark("\(kind)_start"), let end = mark("\(kind)_end"), end > start else { return nil }
            return Skip(title: title, start: start, end: end)
        }
        let isLive = stream?["streamingType"] as? String == "LIVE"
        let recapEnd = mark("recap_end")
        let link = (result["thumbnails"] as? [String: Any])?["bif-main"] as? [String: Any]
        let headers = link?["headers"] as? [String: String] ?? [:]
        let findSkips: (@Sendable () async -> [Skip])? = isLive ? nil : (link?["href"] as? String).flatMap(URL.init(string:)).map { thumbnails in
            { [self] in await self.marvelIntro(resourceId: resourceId, thumbnails: thumbnails, headers: headers, recapEnd: recapEnd) }
        }
        return (Playback(streamURL: url,
                         licenseURL: URL(string: "\(Self.playback)/fairplay/v1/\(linear ? "channel/" : "")obtain-license")!,
                         certificateURL: Self.certificateURL,
                         resume: position, isLive: isLive, skips: skips, findSkips: findSkips),
                mark("FFEC"))
    }

    /// Marvel Studios intros already looked for, by resource id (empty: looked, none there).
    private var marvelIntros: [String: [Skip]] = [:]

    /// The Marvel Studios logo near the front of a Marvel title ("Skip Marvel Intro"). Nothing in the playback
    /// answer marks it, so it is found by reading: the thumbnails of the first five minutes (one every ten
    /// seconds) go through text recognition, and the logo is where "MARVEL STUDIOS" is read, which is near its
    /// end. The button shows from the end of a recap that ended up to 45 seconds before the words (the logo
    /// follows the recap; in eight Loki episodes the words were first read 28 to 39 seconds after it), else
    /// from 30 seconds before them. It jumps to the last thumbnail that shows the words: how long after that
    /// thumbnail the logo ends cannot be told, and this way it never lands inside the show.
    private func marvelIntro(resourceId: String, thumbnails: URL, headers: [String: String], recapEnd: Double?) async -> [Skip] {
        if let known = marvelIntros[resourceId] { return known }
        // The link answers with the thumbnail files (BIF) in a few sizes; the largest reads best.
        guard let answer = try? await json("GET", thumbnails, extraHeaders: headers),
              let bif = (answer["bifs"] as? [[String: Any]])?.max(by: { $0["thumbnailWidth"] as? Int ?? 0 < $1["thumbnailWidth"] as? Int ?? 0 }),
              let path = ((bif["presentations"] as? [[String: Any]])?.first?["paths"] as? [String])?.first,
              let url = URL(string: path) else { return [] }
        // The file's index and its first pictures: five minutes of them took under 700 KB in the episodes measured.
        var request = URLRequest(url: url)
        request.setValue("bytes=0-999999", forHTTPHeaderField: "Range")
        guard let (data, _) = try? await session.data(for: request) else { return [] }
        let times = await Task.detached(priority: .utility) { Self.marvelStudios(inThumbnails: data) }.value
        var found: [Skip] = []
        if let first = times.first {
            // The words stay up for a thumbnail or two.
            let end = times.last { $0 <= first + 20 } ?? first
            let start = recapEnd.flatMap { $0 <= first && first - $0 <= 45 ? $0 : nil } ?? max(0, first - 30)
            if end > start { found = [Skip(title: "Skip Marvel Intro", start: start, end: end)] }
        }
        marvelIntros[resourceId] = found
        return found
    }

    /// The times (seconds in) of the thumbnails in which "MARVEL STUDIOS" is read, among the first five minutes
    /// of a BIF file. BIF: the number of pictures at byte 12, milliseconds per time unit at 16, then from byte 64
    /// a (time, offset) pair of 4-byte little-endian numbers per picture (a JPEG, up to the next offset).
    nonisolated static func marvelStudios(inThumbnails data: Data) -> [Double] {
        func number(_ at: Int) -> Int {
            at + 4 <= data.count ? Int(data[at]) | Int(data[at + 1]) << 8 | Int(data[at + 2]) << 16 | Int(data[at + 3]) << 24 : 0
        }
        let count = number(12), scale = number(16) == 0 ? 1000 : number(16)
        var times: [Double] = []
        for i in 0..<count {
            let time = Double(number(64 + 8 * i) * scale) / 1000, from = number(68 + 8 * i), to = number(76 + 8 * i)
            guard time <= 300, from < to, to <= data.count else { break }
            guard let source = CGImageSourceCreateWithData(data.subdata(in: from..<to) as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { continue }
            let request = VNRecognizeTextRequest()
            try? VNImageRequestHandler(cgImage: image).perform([request])
            // The logo is also read while it is still forming ("PARVEL STUDIO", "MARVEL STUD"), so this much of
            // it in any of the reader's guesses counts, when it is all the picture shows: a title card that has
            // the words among others ("MARVEL STUDIOS' WandaVision" in a recap) is not the logo.
            let lines = request.results ?? []
            let read = lines.count == 1 && lines[0].topCandidates(10).contains { $0.string.uppercased().contains("ARVEL STUD") }
            if read { times.append(time) }
        }
        return times
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
    /// A sign-in API error code ("idp.error.identity.bad-credentials", "account.profile.pin.invalid", …).
    case signIn(String)

    var errorDescription: String? {
        switch self {
        case .http(let status, let message): status == 401 || status == 403 ? "Not signed in to Disney+." : "Disney+ answered \(status): \(message)"
        case .badResponse(let what): "Unexpected answer from Disney+ (\(what))."
        case .signIn("idp.error.identity.bad-credentials"): "Wrong email or password."
        case .signIn("account.profile.pin.invalid"): "Wrong PIN."
        case .signIn(let code) where code.lowercased().contains("otp") || code.lowercased().contains("passcode"): "Wrong or expired code."
        case .signIn(let code): "Disney+ refused the sign-in (\(code))."
        }
    }
}
