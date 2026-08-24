# open prompter

**the pro, open-source teleprompter for creators.**

a teleprompter that supports markdown files and every "Pro" feature you need to record content (plus some extras). point it at a folder in iCloud Drive, an Obsidian vault, or anywhere the iOS Files app can reach. pick a file. hit play. read it back at your pace with voice tracking while the selfie camera records you. the take saves to Photos AND back to the same folder as the script — so when you switch to your mac, your edit is sitting next to the .md it came from. no subscription. no account. no cloud upload. no copy-paste.

<a href="https://apps.apple.com/us/app/open-prompter/id6763611915">
  <img src="https://tools.applemediaservices.com/api/badges/download-on-the-app-store/black/en-us?size=250x83" alt="Download on the App Store" height="60">
</a>

[![MIT License](https://img.shields.io/badge/license-MIT-3fee7a?style=flat-square)](./LICENSE)
[![Platform](https://img.shields.io/badge/platform-iOS%2017%2B-0a0a0b?style=flat-square)](https://developer.apple.com/ios/)
[![App Store](https://img.shields.io/badge/app%20store-shipping-3fee7a?style=flat-square)](https://apps.apple.com/us/app/open-prompter/id6763611915)
[![Website](https://img.shields.io/badge/site-openprompter.app-3fee7a?style=flat-square)](https://openprompter.app)
[![Buy Me a Coffee](https://img.shields.io/badge/buy%20me%20a%20coffee-ffdd00?style=flat-square&logo=buymeacoffee&logoColor=black)](https://buymeacoffee.com/lelanddutcher)

<p align="center">
  <img src="docs/readme-hero.svg" alt="Open Prompter — animated phone mockup with scrolling script, READ/FEATHER cursors, PiP camera, and audio meter" width="340">
</p>

---

## why

every teleprompter app on the store wants a subscription to unlock mirror mode. most want your script uploaded to their cloud. a few want both. the rest hide the "Pro" features behind a paywall that scales with how serious you are about your craft.

open prompter is the whole feature set, free, MIT-licensed forever. it reads the markdown file you already wrote, records you reading it on the phone you already own, and saves the take where the script came from. that's it.

---

## the reading experience

- **voice tracking** — on-device speech recognition follows what you actually said, so the page advances when you do. nothing leaves the phone, ever. it primes the recognizer with a **script-biased vocabulary** built from your own words, so names and jargon match reliably; a draggable reading-band indicator (READ/FEATHER handles) lands the matched word exactly where you want; velocity-controlled scroll with momentum accelerates and decelerates with your pace; when you pause, the scroll finishes landing your last word on the READ line before settling, so you can scroll back to re-read without a fight; and a catch-up floor plus a chase-speed slider (settings → reading) control how briskly it recovers when you fall behind.
- **horizontal AND vertical mirror**, independently, for beam-splitter teleprompter rigs.
- **six legibility-tuned fonts** built in: Atkinson Hyperlegible (default), Lexend, System Sans, Verdana, New York (Serif), and the brand monospace.
- **adjustable scroll speed** (5–200 px/s) and font size (16–160 pt) so dense scripts AND eye-line reads both work.
- **focus mode** dims the chrome for clean recording — a single eye button brings it back.
- **left-edge reading-progress bar** — a slim green marker shows how far you are through the script at a glance, like a page scrollbar. turn it off in settings if you'd rather not see it.
- **iPhone and iPad** — same app, laid out for the screen it's on. an iPad on a teleprompter mount is the classic studio rig; the script column keeps a readable line length instead of stretching across the whole panel.
- **the screen stays awake** while a script is open — reading is the one thing you do without touching the phone.
- **automatic landscape ↔ portrait** — hold the phone whichever way you're shooting and the prompter *and* the recording follow. the aspect picker sets shape; your grip sets orientation.
- **full-bleed prompter** — no UI chrome fighting your eye-line. on iOS 26 the controls render in Liquid Glass.

## camera and recording

- **front camera lives inside the app.** picture-in-picture tile floats over the script while you read; tap it to promote to a full-screen camera preview, tap minimize to collapse it back.
- **four aspect ratios:** **open gate** (the default — the widest your camera captures, never a crop), plus 16:9, 4:3 classic, and 1:1 square.
- **mirror the recorded file** — optional, off by default. flips the saved video left-to-right the way snapchat and the stock selfie camera do, so it matches what you saw while reading. separate from the on-screen mirror chip, which only flips the display for beam-splitter rigs.
- **open gate on iPhone 17** captures the full 1:1 front sensor at 3840 × 3840. perform your script once, crop a 9:16 / 1:1 / 16:9 from the same take in your editor. no reshoot for every platform. (older iPhones record at the maximum frame their sensor exposes — the square-headroom re-crop trick is iPhone 17-only.)
- **save next to the script** — toggle in Settings → Recording. when on, the .mov writes to the same folder as the .md so iCloud delivers the take to your mac next to the script. no Photos library hunt, no AirDrop dance.
- **standard or high-bitrate HEVC**, sized for quality + efficiency. true 24p frame rate or 30p or 60p (if you're feeling wild).
- **editor-ready markers** — tap the mark button while recording, or let script cues (`[MARK]` / headings) drop them automatically. they embed in the .mov as QuickTime chapters *and* an Adobe XMP marker track, so they import as **native markers in Premiere Pro**.
- per-take stabilization, mic source picker, recovery banner if a take got force-quit mid-write.
- **tally-light border + Live Activity in the dynamic island** while recording, so the record state is visible from anywhere.

## built-in editor

tap the pencil in the top bar to open the file. changes save back through the system file coordinator — iCloud syncs them to your mac the same way it syncs any other file. no proprietary container, no "import to edit" round-trip.

use on device inteligence to format your script.

## on-device format

paste a messy transcript or a wall of notes and let **Format** reshape it into clean teleprompter markdown — paragraph breaks, headings, readable line lengths — entirely on-device with Apple's Foundation Models. nothing uploaded, no account. (iOS 26 on an Apple-Intelligence-capable iPhone; the button hides itself where the model can't run.)

## bluetooth remote

pair any Bluetooth keyboard, media remote, or presentation clicker and bind buttons to play, pause, mirror, jump to the top or the end of the script, and other prompter actions. a **"learn your remote" wizard** maps each button by having you press it — including keys we've never heard of, so a programmable or DIY controller works too. keyboards, numeric keypads, media / consumer-control keys, and mouse-class remotes all flow through one unified event bus. volume-button capture is opt-in (Settings → Remote) so the volume rocker still works as a volume rocker by default.

## what it parses

real markdown:

- headings render as headings, bullets as bullets, numbered lists as numbered lists
- front matter, callouts (`> [!ai-generated]`), footnotes, tables, visual-direction brackets (`[B-roll: ...]`), and stage directions (`(pause)`, all-caps action cues) stripped automatically
- aggressive stripping is on by default; turn it off in settings if you want to see cues on screen

## what you WON'T find here

no account. no subscription. no analytics. no tracking. no third-party SDKs. no network calls of any kind. voice tracking and the camera both run entirely on-device. open prompter reads the files you pick from the built-in Files app, captures with the camera you already own, and that's it.

---

## install

- **App Store** — [Open Prompter](https://apps.apple.com/us/app/open-prompter/id6763611915) (iPhone)
- **build from source** — instructions below

## requirements

- iPhone on iOS 17 or newer
- For iCloud live-sync: the same Apple ID on Mac and phone
- For Obsidian vaults: Obsidian Sync or any folder the iOS Files app can reach
- For Open Gate recording: iPhone 17 family (older iPhones record at the maximum frame their sensor exposes)
- For Bluetooth remote: any keyboard or media remote your iPhone can pair with

## build from source

```bash
brew install xcodegen
git clone https://github.com/lelanddutcher/open-prompter.git
cd open-prompter
xcodegen generate
open OpenPrompter.xcodeproj
```

set your development team in signing, then run on a simulator or device.

> ⚠️ the `OpenPrompter.xcodeproj` is gitignored. always run `xcodegen generate` after cloning, after adding/removing files, or after pulling.

## architecture

- **SwiftUI**, iOS 17+, dark mode only, single-pane app
- [swift-markdown](https://github.com/apple/swift-markdown) (Apple) for parsing, with a custom visitor that emits typed script blocks and strips scaffolding (front matter, callouts, footnotes, brackets)
- `NSMetadataQuery` on `NSMetadataQueryUbiquitousDocumentsScope` for live file detection
- `UIDocumentPickerViewController` + security-scoped bookmarks for the "pick once" folder access pattern
- `TimelineView(.animation)` for frame-rate-independent auto-scroll and the velocity-controlled voice-tracking lerp
- `AVCaptureSession` with pre-attached `AVCaptureVideoDataOutput` + `AVCaptureAudioDataOutput`; `AVAssetWriter` is built lazily on the first sample buffer for clean orientation, with an `OrientationPolicy` table mapping `(aspect, bufferShape)` → writer transform (handles the iPhone 17 + iOS 26 front-camera orientation quirks)
- `SFSpeechRecognizer` (on-device) drives voice tracking; a custom `ScriptAligner` does word-level Levenshtein + double-metaphone phonetic folding + locality-biased matching so common words don't teleport you to the end of the script
- `OSAllocatedUnfairLock<WriterState>` guards cross-thread writer state in `RecordingSession` (one lock around a 12-property struct, not 12 individual `nonisolated(unsafe)` fields)
- `SwiftData` (with CloudKit off) for the recents cache, `@AppStorage` + `NSUbiquitousKeyValueStore` for preferences, `ActivityKit` for the recording Live Activity
- `GameController` (`GCKeyboard` / `GCMouse`) + `MediaPlayer` remote-command + hardware key-event handlers feed one unified remote event bus, fronted by a "learn your remote" binding wizard
- on-device `FoundationModels` (`SystemLanguageModel`) powers **Format** on iOS 26 — availability-gated so the feature hides itself on older OSes / ineligible devices and never blocks the iOS 17 floor
- markers write as a QuickTime `.text` chapter track plus an Adobe XMP `xmpDM:Tracks` packet injected into `moov/udta`, so Premiere Pro reads them as native markers
- Liquid Glass controls on iOS 26 (`glassEffect`), with a material + hairline fallback on iOS 17–25


## contributing

PRs welcome. issues tagged `good-first-issue` are a safe entry point. see [`CONTRIBUTING.md`](./CONTRIBUTING.md) for the workflow, code style, and the areas that most need care — the iPhone 17 + iOS 26 camera orientation quirks, the voice-tracking algorithm, and the recording / writer state machine.

## support the project

open prompter is free and MIT-licensed forever. if it saved you a subscription or an hour of fighting your previous teleprompter, [buy me a coffee](https://buymeacoffee.com/lelanddutcher) ☕️ — keeps the lights on for App Store fees, hardware to dogfood on, and shipping more dogfood-tested features.

## license

[MIT](./LICENSE). © 2026 Leland Dutcher.

---

**App Store:** <https://apps.apple.com/us/app/open-prompter/id6763611915>
**Website:** <https://openprompter.app>
**Coffee:** <https://buymeacoffee.com/lelanddutcher>
