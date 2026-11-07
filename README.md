# Waze

A personal Mac player for a Disney+ subscription, in SwiftUI. Not for distribution.

Like Wazu (Hulu) and StarPlayrX, it talks to the service's own web API and plays natively: the
same calls disneyplus.com's player makes (the "explore" API on disney.api.edge.bamgrid.com for
browsing and search, disney.playback.edge.bamgrid.com for the stream) feed a native UI, and
AVPlayer plays the FairPlay HLS stream with keys from Disney's license server
(AVContentKeySession). Sign-in happens once on disneyplus.com in a web view (pick a profile
there too); the bearer token the site's SDK keeps is what the API client uses, and it is renewed
by reloading the site off screen when it is about to expire.

You need your own Disney+ subscription. The app stores nothing but the session token the site
itself keeps in the browser.

## Features

- Sidebar: the site's own navigation — For You, Disney+, Hulu, ESPN, Live, Watchlist, Movies,
  Series, Originals (⌘1–⌘9) and Search (⌘F); ⌘[ goes back a page
- Rows of artwork per page; series pages list seasons and episodes; a Play button resumes
- Live events and channels play from wherever they appear (ESPN, Live)
- Player: AVKit's floating controls (full screen, Picture in Picture, audio/subtitle
  menus), Play/Pause ⌘P, skip ±10 s, Stop ⌘., Esc closes; the keyboard's media keys work
- Sign-in is remembered between launches (Waze > Sign Out of Disney+ clears it)

## Keyboard

| Shortcut | Action |
| --- | --- |
| ⌘1 – ⌘9 | Sidebar pages |
| ⌘F | Search |
| ⌘[ | Back |
| ⌘P | Play / Pause |
| ⌘← / ⌘→ | Skip back / forward 10 s |
| ⌃⌘T | Float on Top (player window) |
| ⌘. | Stop |
| Esc | Close the player |

## Requirements

- macOS 14 or later
- Xcode 15 or later
- [xcodegen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`) — the Xcode
  project is generated from `project.yml`

## Build

```sh
xcodegen generate
xcodebuild -project Waze.xcodeproj -scheme Waze -configuration Release -derivedDataPath build build
open build/Build/Products/Release/Waze.app
```

Re-run `xcodegen generate` after adding or removing files under `Sources/`.

## Layout

| File | Role |
| --- | --- |
| `Sources/WazeApp.swift` | App entry point, menus and keyboard shortcuts |
| `Sources/ContentView.swift` | Sidebar, pages, rows of artwork, series/episode views, inline player |
| `Sources/DisneyClient.swift` | The explore / playback API client, session handling and FairPlay key delivery |
| `Sources/Models.swift` | Codable models for the explore API responses |
| `Sources/Player.swift` | AVPlayer controller and AVKit player view |
| `Sources/PlayerWindow.swift` | Stand-alone player window (own full screen, Float on Top) |
| `Sources/SignIn.swift` | disneyplus.com sign-in web view that captures the session token |
| `project.yml` | xcodegen project definition |

## Notes

- Playback is DRM-protected; screenshots and screen recordings of the player come out black.
- This is a personal project that depends on undocumented endpoints; it can break whenever the
  service changes its web player.
