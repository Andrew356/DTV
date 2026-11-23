# DTV: IPTV for Apple TV

DTV is a native tvOS app (SwiftUI, tvOS 17+) for watching IPTV. It's meant as a personal alternative to apps like UHF.

## Features

| | |
|---|---|
| **M3U / M3U8 playlists** | Reads `tvg-id`, `tvg-name`, `tvg-logo`, `group-title`, `tvg-chno`, `catchup`, `#EXTGRP`, and `url-tvg` / `x-tvg-url` in the header. Entries are sorted into **Live TV**, **Movies** (`/movie/` paths and video files) and **Series** (`/series/` paths and `S01E02`-style titles, grouped into shows and seasons). |
| **Xtream Codes login** | Server, username and password. Loads live, VOD and series categories in the provider's order, fetches series episodes when you open a show, checks your login when you save it, and plays live TV as HLS when the server allows it. |
| **TV guide (EPG)** | XMLTV guides, plain or `.gz`, from the playlist header, the Xtream `xmltv.php`, or a URL you set yourself. The parser streams the file so large guides work. Shows what's on now and next, with a progress bar. |
| **iCloud sync** | Sources, favorites, watch progress ("Continue Watching") and settings sync between your Apple TVs through iCloud Key-Value storage. Xtream passwords go through **iCloud Keychain** and are never stored in plain text. |
| **Player** | Uses AVPlayerViewController, so you get the native transport bar, audio and subtitle track menus, and Picture in Picture. For live TV you get Previous/Next channel buttons, plus a **Guide** panel and a **Channels** panel (swipe down) for changing channel without leaving the player. Movies and episodes resume where you stopped. |
| **Optional VLC engine** | Plays MKV, AVI, raw MPEG-TS and other formats AVPlayer can't. In Automatic mode it also takes over when AVPlayer fails. |
| Other | Favorites (long-press a channel), global search, multiple sources, playlists cached on the device. |

## Build & run

You need a Mac with Xcode 15 or later, and an Apple Developer account (the free tier is enough to run the app on your own Apple TV).

```bash
brew install xcodegen
cd DTV
xcodegen            # generates DTV.xcodeproj from project.yml
open DTV.xcodeproj
```

1. Select the **DTV** target. Under **Signing & Capabilities**, pick your **Team** and change the bundle identifier (default `com.example.DTV`) to one that's yours.
2. Make sure the **iCloud** capability has **Key-value storage** ticked. It's already in `DTV/DTV.entitlements`.
3. Pair your Apple TV: on the Apple TV, open *Settings → Remotes and Devices → Remote App and Devices*, then in Xcode use *Window → Devices and Simulators*. Pick the Apple TV as the run destination and press ⌘R.

To sync between Apple TVs, every Apple TV must be signed in to the same Apple Account with iCloud turned on, and run a build signed with the same Team and bundle ID.

### Enable the VLC engine (recommended for MKV and `.ts` streams)

1. In `project.yml`, uncomment the `packages:` block and the `dependencies:` entry under the `DTV` target.
2. Run `xcodegen` again and build.

When `TVVLCKit` is linked, the code under `#if canImport(TVVLCKit)` turns on by itself, and a **Player** option appears in Settings (Automatic / Apple / VLC).

## Moving over from UHF

DTV can't read UHF's data directly. Add the same M3U URL or Xtream login you use in UHF (Settings → Add Source) and DTV picks up the rest. Once you've added it on one Apple TV, your other Apple TVs get it through iCloud.

## Project layout

```
DTV/
  App/        DTVApp (entry point), AppModel (state, loading, playback, favorites)
  Models/     Source, Channel, Movie, Series, Episode, Catalog, favorites/progress/settings
  Services/   M3UParser, CatalogBuilder, XtreamClient, EPG (XMLTV and gzip), SyncStore (iCloud KVS),
              Keychain (iCloud Keychain), CatalogCache
  Player/     PlayerScreen (picks the engine), AVPlayerView, VLCPlayerView
  Views/      Live TV, Movies, Series, Favorites, Search, Settings, shared components
DTVTests/     Unit tests for the M3U parser, Xtream decoding and XMLTV parsing
```

## Notes

- `NSAllowsArbitraryLoads` is on because most IPTV servers use plain `http`.
- Big playlists and guides are kept in the Caches folder. tvOS can clear that folder, and the app downloads them again when it does.
- If an M3U URL has your credentials in it (for example `get.php?username=…`), that URL syncs through iCloud Key-Value storage. Use the Xtream login instead if you want the password kept in the Keychain.
- There's no App Icon or Top Shelf image yet. Add a tvOS "App Icon & Top Shelf Image" set to an asset catalog before distributing the app.
