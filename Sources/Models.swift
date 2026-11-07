//
//  Models.swift
//  Waze
//
//  What the explore API hands back, reduced to what the UI shows: pages of containers of items.
//  A "set" container is a row; an "episodes" container holds one season per row. Every item is a
//  "view" with visuals (title, artwork image ids…) and actions (browse to a page, playback).
//

import Foundation

/// A sidebar entry from the site's global navigation.
struct NavItem: Identifiable, Hashable {
    let id: String
    let name: String
    let pageId: String

    init?(json: [String: Any]) {
        guard json["type"] as? String == "navItem", let id = json["id"] as? String,
              let name = (json["visuals"] as? [String: Any])?["name"] as? String,
              let pageId = (json["action"] as? [String: Any])?["pageId"] as? String else { return nil }
        self.id = id; self.name = name; self.pageId = pageId
    }

    var icon: String {
        switch name.lowercased() {
        case "for you": "house"
        case "live": "antenna.radiowaves.left.and.right"
        case "watchlist": "plus.square.on.square"
        case "movies": "film"
        case "series": "tv"
        case "originals": "star"
        case "hulu": "h.square"
        case "espn": "sportscourt"
        default: "sparkles"
        }
    }
}

struct Page {
    let id: String
    let title: String
    /// The title's description when this is a details page.
    let description: String?
    /// The Play button on a details page (resume / first episode / the movie).
    let play: PlayAction?
    var collections: [Collection]

    init(json: [String: Any]) {
        id = json["id"] as? String ?? ""
        let visuals = json["visuals"] as? [String: Any]
        title = visuals?["title"] as? String ?? ""
        description = (visuals?["description"] as? [String: Any])?["medium"] as? String
        play = (json["actions"] as? [[String: Any]] ?? []).lazy.compactMap(PlayAction.init(json:)).first
        var collections = [Collection]()
        for container in json["containers"] as? [[String: Any]] ?? [] {
            switch container["type"] as? String {
            case "set":
                if let c = Collection(json: container) { collections.append(c) }
            case "episodes":
                for season in container["seasons"] as? [[String: Any]] ?? [] {
                    if let c = Collection(json: season) { collections.append(c) }
                }
            default:
                break
            }
        }
        self.collections = collections
    }
}

/// A row: a set (paged, 15 at a time) or a season (fetched whole).
struct Collection: Identifiable {
    let id: String
    let name: String
    let style: String
    let isSeason: Bool
    var items: [Item]
    /// More items to fetch from the set, when the API says so.
    var hasMore: Bool

    init?(json: [String: Any]) {
        guard let id = json["id"] as? String else { return nil }
        self.id = id
        let visuals = json["visuals"] as? [String: Any]
        name = visuals?["name"] as? String ?? ""
        style = (json["style"] as? [String: Any])?["name"] as? String ?? ""
        isSeason = json["type"] as? String == "season"
        items = (json["items"] as? [[String: Any]] ?? []).compactMap(Item.init(json:))
        hasMore = (json["pagination"] as? [String: Any])?["hasMore"] as? Bool ?? false
    }

    /// Rows whose style is a poster get tall tiles.
    var vertical: Bool { style.contains("poster") || style.contains("vertical") || style.contains("top_ranked") }
}

/// Something that can be played: the resource id the playback service wants.
struct PlayAction: Hashable {
    let resourceId: String
    /// A live channel/event rather than VOD.
    let isLinear: Bool

    init?(json: [String: Any]) {
        guard json["type"] as? String == "playback", let resourceId = json["resourceId"] as? String else { return nil }
        self.resourceId = resourceId
        isLinear = json["contentType"] as? String == "linear"
    }
}

struct Item: Identifiable, Hashable {
    let id: String
    let title: String
    let subtitle: String?
    let description: String?
    /// ripcut image ids: a 16:9 tile and, when there is one, a poster.
    let tileImage: String?
    let posterImage: String?
    let play: PlayAction?
    /// The page to open for this item (details page, collection page…).
    let pageId: String?
    /// An episode (or extra) rather than a series/movie: clicking it plays.
    let isEpisode: Bool
    var isLive: Bool { play?.isLinear ?? false }

    init?(json: [String: Any]) {
        guard json["type"] as? String == "view", let id = json["id"] as? String else { return nil }
        self.id = id
        let visuals = json["visuals"] as? [String: Any] ?? [:]
        title = visuals["title"] as? String ?? ""
        description = (visuals["description"] as? [String: Any])?["brief"] as? String
        isEpisode = visuals["episodeTitle"] != nil || visuals["durationMs"] != nil
        let meta = visuals["metastringParts"] as? [String: Any]
        subtitle = (visuals["fullEpisodeTitle"] as? String
            ?? visuals["prompt"] as? String
            ?? ((visuals["itemPrompt"] as? [String: Any])?["text"] as? String)
            ?? (meta?["releaseYearRange"] as? [String: Any])?["startYear"] as? String)?
            .replacingOccurrences(of: "\n", with: " · ")

        // Artwork: visuals.artwork.<purpose>.<kind>.<aspect>.imageId; prefer the standard tile.
        let artwork = visuals["artwork"] as? [String: Any] ?? [:]
        func image(_ purposes: [String], _ kinds: [String], _ aspects: [String]) -> String? {
            for purpose in purposes {
                guard let p = artwork[purpose] as? [String: Any] else { continue }
                for kind in kinds {
                    guard let k = p[kind] as? [String: Any] else { continue }
                    for aspect in aspects {
                        if let id = (k[aspect] as? [String: Any])?["imageId"] as? String { return id }
                    }
                }
            }
            return nil
        }
        // Episodes have their own still as the thumbnail; series and movies use the tile.
        tileImage = image(["standard", "tile", "hero", "partner"], isEpisode ? ["thumbnail", "tile", "background"] : ["tile", "thumbnail", "background"],
                          ["1.78", "1.33", "2.29", "2.89"])
        posterImage = image(["standard", "tile"], ["tile", "background"], ["0.67", "0.71", "0.75", "0.80"])

        // Actions: a browse (pageId) and a playback (resourceId); live items nest theirs inside a modal.
        var browse: String?
        var playback: PlayAction?
        func walk(_ actions: [[String: Any]]) {
            for action in actions {
                if browse == nil, action["type"] as? String == "browse" { browse = action["pageId"] as? String }
                if playback == nil, let p = PlayAction(json: action) { playback = p }
                walk(action["actions"] as? [[String: Any]] ?? [])
            }
        }
        walk(json["actions"] as? [[String: Any]] ?? [])
        pageId = browse
        play = playback
    }

    /// A page's Play button, as something the player can show.
    init(id: String, title: String, play: PlayAction) {
        self.id = id; self.title = title; subtitle = nil; description = nil
        tileImage = nil; posterImage = nil; self.play = play; pageId = nil; isEpisode = true
    }

    /// Sized artwork from ripcut; a portrait size picks the poster when there is one.
    func artwork(width: Int, height: Int) -> URL? {
        guard let image = height > width ? posterImage ?? tileImage : tileImage else { return nil }
        return URL(string: "https://disney.images.edge.bamgrid.com/ripcut-delivery/v2/variant/disney/\(image)/compose?format=jpeg&width=\(width)")
    }
}

/// What the playback service answers: the HLS stream and where to get its FairPlay keys.
struct Playback {
    let streamURL: URL
    let licenseURL: URL
    /// Where to resume, in seconds (0 to start over; live has none).
    let resume: Double
    let isLive: Bool
}
