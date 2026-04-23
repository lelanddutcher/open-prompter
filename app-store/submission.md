# Open Prompter — App Store Connect submission packet

Copy the fields below into App Store Connect. Two text docs (Privacy
Policy, Terms of Service) need to be hosted at openprompter.app before
submission — URLs are listed under **Links**.

---

## App Information

**Name**
`Open Prompter`

**Subtitle** (30 chars max)
`Teleprompter for markdown files`

**Primary category**: Productivity
**Secondary category**: Photo & Video

**Bundle ID**: `app.openprompter.ios`
**SKU**: `openprompter-ios-v1`
**Age rating**: 4+ (no objectionable content, no tracking, no user-generated content surface)
**Copyright**: `© 2026 Leland Dutcher`

---

## Pricing and availability

- **Price**: Free
- **Availability**: All territories
- **Pre-orders**: None
- **In-app purchases**: None
- **Subscriptions**: None

---

## Version 1.0.0 — What's New

(Used for the first release; skip the "updates since last version" copy.)

```
First release. Point Open Prompter at a folder full of markdown files —
iCloud Drive, your Obsidian vault, Dropbox — and read straight from the
source. Live file-watching, adjustable speed, mirror mode for beam-splitter
rigs, six legibility-tuned fonts, a built-in editor. Free forever, MIT,
no account.
```

---

## Promotional text (170 chars, editable post-launch)

```
Free, open-source, markdown-native. Reads the files you already have —
from iCloud, Obsidian, or any Files-app folder. No account. No subscription.
Never.
```

---

## Description (4000 chars max)

```
Open Prompter is a teleprompter for the markdown files you already have.

Every other teleprompter app on the store wants a subscription to unlock
mirror mode. Most want your script uploaded to their cloud first. A few
want both. Open Prompter reads the .md file in your iCloud Drive or your
Obsidian vault — as-is, live, no paste, no import — and that's the whole
app. Free forever. MIT licensed.

HOW IT WORKS
— Tap "pick folder" once. Choose a folder in iCloud Drive, an Obsidian
  vault, Dropbox, or anywhere the Files app can reach.
— The library shows every .md file in that folder. Tap one. You're reading.
— Edit the file on your Mac. The phone catches up, usually within a minute.
  The EDITED chip tells you when the file on disk was last saved.

THE READING EXPERIENCE
— Full-bleed prompter — no UI chrome fighting your eye-line.
— Horizontal and vertical mirror for beam-splitter teleprompter rigs.
  The mirror pill turns red so you always know you're reversed.
— Six legibility-tuned fonts built in: Atkinson Hyperlegible (default),
  Lexend, System Sans, Verdana, New York (Serif), and the brand monospace.
— Adjustable scroll speed (5–200 px/s) and font size (16–160 pt) so dense
  scripts and eye-line reads both work.
— Focus mode dims the chrome for clean recording — a single eye button
  brings it back.

WHAT IT UNDERSTANDS
Open Prompter parses real markdown. Headings render as headings, bullets
as bullets, numbered lists as numbered lists. Front matter, AI callouts
(> [!ai-generated]), footnotes, tables, and visual-direction brackets
([B-roll: ...]) are stripped automatically so you're only reading the
spoken words. Aggressive stripping is on by default; turn it off in
Settings if you want to see your cues on camera.

BUILT-IN EDITOR
Tap the pencil in the top bar to open the file. Changes save back through
the file coordinator — iCloud syncs them to your Mac the same way it
syncs any other file.

WHAT YOU WON'T FIND HERE
No account. No subscription. No analytics. No tracking. No third-party
SDKs. No network calls of any kind. Open Prompter reads the files you
pick and that's it.

OPEN SOURCE
Every line of code is on GitHub under the MIT license:
  github.com/lelanddutcher/open-prompter

If you want to see how the markdown parser handles your scripts, clone
the repo, point it at your own vault, and ship a PR.

REQUIREMENTS
— iPhone on iOS 17 or newer
— For iCloud live-sync: the same Apple ID on Mac and phone
— For Obsidian vaults: Obsidian Sync or any folder the iOS Files app
  can reach

FROM THE AUTHOR
I'm Leland. I spent three years paying $15/month for a teleprompter that
couldn't read my Obsidian vault. I built the one I wanted. It's free
because teleprompter software has no business being a subscription, and
it's open because I trust you more than I trust a startup's runway.
— openprompter.app
```

Character count: ~2,800

---

## Keywords (100 chars, comma-separated)

Work backward from search intent. Teleprompter hunters searching for
"free teleprompter", "markdown teleprompter", "obsidian prompter" are
our highest-intent traffic.

```
teleprompter,markdown,obsidian,script,mirror,recording,prompter,video,creator,icloud
```

Character count (without spaces): 87

Fallback if Apple objects to any word:
```
teleprompter,markdown,script,mirror,prompter,reader,creator,icloud,obsidian,dictation
```

---

## Support URL

`https://github.com/lelanddutcher/open-prompter/issues`

## Marketing URL

`https://openprompter.app`

## Privacy Policy URL

`https://openprompter.app/privacy`

## Terms of Use URL

`https://openprompter.app/terms`

---

## App Review Information

**Sign-in required**: No

**Demo account**: N/A

**Contact**
- First name: Leland
- Last name: Dutcher
- Phone: (fill in)
- Email: leland@lelanddutcher.com

**Notes for the reviewer**

```
Open Prompter is a local-only teleprompter. It has no accounts, no
network calls, no analytics, and no in-app purchases. It reads .md
files from a folder the user selects via UIDocumentPickerViewController
and persists access via a security-scoped bookmark.

To exercise the app end-to-end:
1. Launch the app. Complete the three-slide onboarding (tap "next" x2,
   then "pick my folder").
2. Select any folder — an empty iCloud Drive folder is fine. If the
   folder is empty, tap "Create new script" to write a sample .md file.
3. Alternatively, tap "try the demo script" on the folder picker screen
   to open a bundled demo that exercises every parser feature without
   touching iCloud.
4. In the prompter: tap the mirror pill to flip horizontally, tap PLAY
   to auto-scroll. Settings (via the ••• menu in the library) exposes
   font picker, appearance (dark default), and default speed/size.

Bundled fonts (Atkinson Hyperlegible, Lexend) are distributed under the
SIL Open Font License — license texts are in the app bundle.
```

---

## Privacy — App Privacy questionnaire

**Does your app collect data from this app?**
**No.**

(This answer is honest. The app makes zero network calls and stores
preferences only in UserDefaults and NSUbiquitousKeyValueStore, neither
of which Apple counts as "data collection" for the purposes of this
questionnaire.)

---

## Age rating answers

All questions: **None / No**. The app does not contain:
- Cartoon or fantasy violence / realistic violence
- Sexual content or nudity
- Profanity or crude humor
- Horror/fear themes
- Medical/treatment information
- Alcohol, tobacco, or drug use or references
- Mature/suggestive themes
- Simulated gambling
- Contests
- Unrestricted web access
- Gambling and contests
- User-generated content

Result: **4+**

---

## Build and upload

```
# Archive from Xcode (Product → Archive) or CLI:
cd /Users/LelandDutcher/Developer/OpenPrompter
xcodegen generate
xcodebuild archive \
  -scheme OpenPrompter \
  -configuration Release \
  -archivePath build/OpenPrompter.xcarchive \
  -destination 'generic/platform=iOS'

# Then upload via Xcode Organizer (Window → Organizer) or altool.
```

---

## Checklist before hitting Submit

- [ ] Privacy Policy hosted at `openprompter.app/privacy`
- [ ] Terms of Service hosted at `openprompter.app/terms`
- [ ] Support issues page responding at GitHub
- [ ] 1290×2796 screenshots uploaded (6 frames, already in
      `openprompter-web/dist-screenshots/`)
- [ ] App icon attached (already wired via `Assets.xcassets/AppIcon`)
- [ ] Build archived with `MARKETING_VERSION: 1.0.0` /
      `CURRENT_PROJECT_VERSION: 1`
- [ ] TestFlight internal sanity pass on a real device
