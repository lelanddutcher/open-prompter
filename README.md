# open prompter

a free, open-source ios teleprompter that reads markdown files straight from icloud drive.

![MIT License](https://img.shields.io/badge/license-MIT-black)
![Platform](https://img.shields.io/badge/platform-iOS%2017%2B-blue)
![TestFlight](https://img.shields.io/badge/testflight-soon-lightgrey)
![App Store](https://img.shields.io/badge/app%20store-soon-lightgrey)

## what it is

a teleprompter for people who already write in markdown. point it at a folder in icloud drive or your obsidian vault, pick a file, hit play. the file on your mac is the source of truth. no in-app editor, no cloud account, no copy-paste.

## features (v1)

- reads `.md` and `.markdown` files from icloud drive
- live file-watching — edits on mac show up on phone, usually within a minute
- front matter, callouts, footnotes, and `[B-roll: ...]` visual directions stripped automatically
- adjustable scroll speed (5–200 px/s) and font size (32–160 pt)
- mirror mode for teleprompter rig glass — horizontal, vertical, or both axes
- dim-ui focus mode for clean recording
- iphone portrait + landscape
- zero analytics, zero tracking, zero network calls

## what's NOT in v1

- bluetooth remote (v2)
- recording (v2)
- ipad (dropped)
- mac (v1.2 native swiftui, not catalyst)

## install

- testflight: coming in v0.9
- app store: coming in v1.0

## build from source

```
brew install xcodegen
git clone https://github.com/lelanddutcher/open-prompter.git
cd open-prompter
xcodegen generate
open OpenPrompter.xcodeproj
```

## architecture

- SwiftUI, iOS 17+, dark mode only
- `swift-markdown` (Apple) for parsing, custom visitor for scaffold-aware stripping
- `NSMetadataQuery` on `NSMetadataQueryUbiquitousDocumentsScope` for live file detection
- `UIDocumentPickerViewController` + security-scoped bookmarks for "pick once" folder access
- `TimelineView(.animation)` for frame-rate-independent auto-scroll
- `SwiftData` for recent-script cache, `@AppStorage` + `NSUbiquitousKeyValueStore` for preferences

see `docs/ARCHITECTURE.md` for details.

## contributing

prs welcome. issues tagged `good-first-issue` are a safe entry point. see `CONTRIBUTING.md`.

## license

[MIT](./LICENSE). © 2026 Leland Dutcher.
