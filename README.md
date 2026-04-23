# open prompter

**the free, open-source teleprompter for markdown creators.**

a teleprompter for people who already write in markdown. point it at a folder in iCloud Drive or an Obsidian vault, pick a file, hit play. the file on your mac is the source of truth. no in-app editor battles, no cloud account, no copy-paste.

[![MIT License](https://img.shields.io/badge/license-MIT-3fee7a?style=flat-square)](./LICENSE)
[![Platform](https://img.shields.io/badge/platform-iOS%2017%2B-0a0a0b?style=flat-square)](https://developer.apple.com/ios/)
[![TestFlight](https://img.shields.io/badge/testflight-soon-6a6a65?style=flat-square)]()
[![App Store](https://img.shields.io/badge/app%20store-soon-6a6a65?style=flat-square)]()
[![Website](https://img.shields.io/badge/site-openprompter.app-3fee7a?style=flat-square)](https://openprompter.app)

---

## why

every teleprompter app on the store wants a subscription to unlock mirror mode. most want your script uploaded to their cloud. a few want both.

open prompter reads the markdown file you already have, from iCloud Drive or your obsidian vault, and that's the whole app. free, open source, MIT licensed.

## what it does (v1)

- reads `.md` and `.markdown` files from any folder the Files app can reach — iCloud Drive, Obsidian, Dropbox, wherever
- live file-watching — edits on your mac show up on your phone, usually within a minute
- structured rendering — headings render as headings, bullets as bullets, lists as lists
- front matter, callouts, footnotes, `[B-roll: ...]` visual directions stripped automatically
- adjustable scroll speed (5–200 px/s) and font size (16–160 pt) so dense scripts and eye-line reads both work
- mirror mode for teleprompter-rig glass — horizontal, vertical, or both axes
- focus mode dims the chrome for clean recording, with a single visible eye button to bring it back
- on-device edit sheet that teleports to the section you were reading
- zero analytics, zero tracking, zero network calls

## what's NOT in v1

- bluetooth remote (v2)
- on-device recording (v2)
- ipad (dropped)
- mac (v1.2, native SwiftUI — not catalyst)
- rich markdown wysiwyg editing (write on your mac)

## install

- testflight: coming in v0.9
- app store: coming in v1.0
- or build from source — instructions below

## build from source

```bash
brew install xcodegen
git clone https://github.com/lelanddutcher/open-prompter.git
cd open-prompter
xcodegen generate
open OpenPrompter.xcodeproj
```

set your development team in signing, then run on a simulator or device.

## architecture

- SwiftUI, iOS 17+, dark mode only
- [swift-markdown](https://github.com/apple/swift-markdown) (apple) for parsing, with a custom visitor that emits typed script blocks and strips scaffolding
- `NSMetadataQuery` on `NSMetadataQueryUbiquitousDocumentsScope` for live file detection
- `UIDocumentPickerViewController` + security-scoped bookmarks for "pick once" folder access
- `TimelineView(.animation)` for frame-rate-independent auto-scroll and the logo animation
- `SwiftData` (with CloudKit off) for recent-script cache, `@AppStorage` + `NSUbiquitousKeyValueStore` for preferences

## design language

the visual system lives in [`design-language.md`](./design-language.md). it covers the color tokens (prompter black, open green, mirror red), the type scale (JetBrains Mono for chrome, Inter for body), the shape language, and the rules for how the terminal / markdown motifs get used.

the animated brand mark is specified in [`logo-animation.md`](./logo-animation.md) — two brackets with eyes inside that sweep and blink like a reader. the reference implementation is in [`OpenPrompter/UI/OpenPrompterLogo.swift`](./OpenPrompter/UI/OpenPrompterLogo.swift).

## contributing

prs welcome. issues tagged `good-first-issue` are a safe entry point. see [`CONTRIBUTING.md`](./CONTRIBUTING.md).

## license

[MIT](./LICENSE). © 2026 Leland Dutcher.

---

**website:** <https://openprompter.app>
