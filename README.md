# Waze

A personal Mac player for a Disney+ subscription, in SwiftUI. Not for distribution.

Like Wazu (Hulu) and StarPlayrX, it talks to the service's own web API and plays natively: the
same calls disneyplus.com's player makes (the "explore" API on disney.api.edge.bamgrid.com for
browsing and search, disney.playback.edge.bamgrid.com for the stream) feed a native UI, and
AVPlayer plays the FairPlay HLS stream with keys from Disney's license server
(AVContentKeySession). Sign-in happens once on disneyplus.com in a web view (pick a profile
there too); the bearer token the site's SDK keeps is what the API client uses, and it is renewed
by reloading the site off screen when it is about to expire.

- Sidebar: the site's own navigation — For You, Disney+, Hulu, ESPN, Live, Watchlist, Movies,
  Series, Originals (⌘1–⌘9) and Search (⌘F); ⌘[ goes back a page
- Rows of artwork per page; series pages list seasons and episodes; a Play button resumes
- Live events and channels play from wherever they appear (ESPN, Live)
- Player: AVKit's floating controls (full screen, Picture in Picture, audio/subtitle
  menus), Play/Pause ⌘P, skip ±10 s, Stop ⌘., Esc closes; the keyboard's media keys work
- Sign-in is remembered between launches (Waze > Sign Out of Disney+ clears it)

## Build

```sh
xcodegen generate
xcodebuild -project Waze.xcodeproj -scheme Waze -configuration Release -derivedDataPath build build
open build/Build/Products/Release/Waze.app
```
