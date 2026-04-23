# Privacy Policy

**Effective date:** 2026-04-23
**Last updated:** 2026-04-23

## tl;dr

Open Prompter does not collect, transmit, sell, or share any of your
data. It has no accounts. It makes no network calls. It has no
analytics. It contains no third-party SDKs. Every file it reads comes
from a folder you picked, and everything stays on your device or in
your own iCloud Drive.

---

## What Open Prompter does with your files

Open Prompter reads markdown files (`.md`, `.markdown`) from a folder
you choose using the system file picker. Your choice is stored as a
security-scoped bookmark so the app can read the folder on subsequent
launches without asking again. You can change or revoke the folder at
any time from the library's menu.

The app **reads** files — including their text content and the
"last modified" timestamp — so it can render them as teleprompter
scripts and show you when each file was last edited. It **writes**
files when you use the built-in editor or the "create new script"
action. All reads and writes happen through Apple's standard
`NSFileCoordinator`, locally on your device.

Open Prompter never uploads your files anywhere. iCloud sync, if you
use it, happens between your devices via Apple's iCloud Drive — not
through Open Prompter. Obsidian vaults, Dropbox folders, and other
cloud-provider folders behave the same way: the app reads the local
copy that their own apps have already placed on your device.

---

## Preferences we store

Open Prompter saves your app preferences in Apple's `UserDefaults`
(on your device) and mirrors them to `NSUbiquitousKeyValueStore` (your
personal iCloud key-value store) so they follow you across your own
iPhones. The mirrored preferences are:

- Default scroll speed
- Default font size
- Default mirror state
- Default focus state
- Whether aggressive markdown stripping is on
- Your chosen appearance (light / dark / system)
- Your chosen prompter font

No other data is stored or synced. The security-scoped folder bookmark
and the last-opened-file pointer are device-local — we deliberately
don't sync them because a folder on one device may not be reachable
from another.

---

## What we don't collect

- Your name, email, phone number, or any other identifier
- Your scripts or file contents
- Usage statistics, telemetry, crash logs, or analytics
- Advertising identifiers (the app doesn't link `AdSupport` at all)
- Device fingerprints, IP addresses, or location
- Contacts, photos, microphone, camera, or health data

Open Prompter does not link any third-party SDKs or embed any
tracking code.

---

## Network activity

Open Prompter makes no network requests of its own. The only network
activity associated with the app is what iOS performs on your behalf
when it syncs iCloud Drive, iCloud Key-Value Store, or a third-party
cloud provider's folder — all of which are system services outside
Open Prompter's control and governed by those services' own privacy
policies:

- **Apple iCloud** — <https://www.apple.com/legal/privacy/>
- **Obsidian Sync** (if used) — <https://obsidian.md/privacy>
- **Dropbox** (if used) — <https://www.dropbox.com/privacy>
- **Google Drive** (if used) — <https://policies.google.com/privacy>

---

## Children's privacy

Open Prompter is rated 4+. We do not knowingly collect data from
anyone, including children under 13. Because the app collects nothing
from anyone, no special children's data protections are needed.

---

## Your rights

Because we don't collect, store, or process any personal data, there's
nothing to access, correct, export, or delete on our side. If you want
to remove the data Open Prompter has stored on your device, delete the
app. That clears all local preferences and the folder bookmark. To
clear the iCloud key-value store mirror, sign out of iCloud on the
device (or use Settings → [your name] → iCloud → Apps Using iCloud →
Open Prompter → remove).

Residents of the EU (GDPR), United Kingdom (UK-GDPR), and California
(CCPA / CPRA) have additional rights around personal data. Because
Open Prompter neither collects nor processes personal data, those
rights are satisfied by default — there is nothing on our side to
access, correct, port, or delete.

---

## Changes to this policy

If we ever add a feature that would change what the app reads or
sends, this policy will be updated before the feature ships, and the
"Last updated" date at the top will reflect the change. Material
changes will also be noted in the App Store release notes.

---

## Contact

Questions about privacy? File an issue at
<https://github.com/lelanddutcher/open-prompter/issues> or email
`leland@lelanddutcher.com`.

Open Prompter is made by Leland Dutcher, an independent developer in
the United States.
