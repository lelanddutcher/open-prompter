//
//  RecordingAspect.swift
//  OpenPrompter
//
//  User-configurable recording aspect ratio.
//
//  V3 §07 (landscape auto-orientation) reworked this enum to SHAPE-ONLY.
//  Orientation (portrait vs landscape) is no longer the picker's job — it
//  is derived at REC tap from how the phone is physically held (see
//  `OrientationPolicy.PhysicalHold` + the 3-arg `writerTransform`). The
//  picker therefore presents four SHAPES:
//    .wide (16:9), .classic (4:3), .square (1:1), .openGate (full sensor).
//  Held upright, a `.wide` shape records 9:16 vertical; rotated to
//  landscape it records 16:9 horizontal. Same shape, physical orientation.
//
//  The old `.ratio9x16` / `.ratio16x9` cases were the *same 16:9 shape*
//  differing only in orientation, so they MERGE into `.wide`. Per the
//  `CameraStyle.behind` downgrade-safety precedent we DO NOT delete the old
//  raw strings:
//    - `.wide` REUSES the raw value `"ratio16x9"`. This is deliberate and
//      load-bearing — the verified 9x16↔16x9 label swap in `avAspectRatio`
//      is anchored to `.ratio16x9`'s portrait output on iPhone 17, which is
//      exactly the buffer the whole composition is built on. Do NOT re-point
//      `.wide` at `"ratio9x16"` (that inverts the verified swap).
//    - `.legacyVertical9x16` (raw `"ratio9x16"`) is kept ONLY for
//      downgrade-safety / migration so a persisted pre-V3 vertical value
//      still `init(rawValue:)`s cleanly. It is never offered in the picker
//      and every behavioral call site funnels it through `canonicalShape`
//      first (→ `.wide`), so it never reaches the policy table with its own
//      identity.
//
//  QA REVIEWER FOCUS: every case here has to round-trip Codable cleanly and
//  the iOS 26 mapping in `avAspectRatio` must match `AVCaptureDevice.AspectRatio`
//  raw values. Mismatches surface as silent fallbacks in the format selector.
//  The 9x16↔16x9 swap in `avAspectRatio` / `requestedRaw` is verified ground
//  truth (pass-13e) and MUST NOT change — see the doc comment on `avAspectRatio`.
//

import AVFoundation
import Foundation

/// User-facing recording SHAPE. Stored as a raw string in
/// `Prefs.recordingAspect` so we can extend without a migration. Orientation
/// (portrait/landscape) is derived from the physical hold at REC tap, NOT
/// from this enum (V3 §07). The `requiresIOS26` flag drives whether the
/// picker offers a given case at runtime (we hide cases that can't be
/// reliably honored on iOS 17–25).
enum RecordingAspect: String, CaseIterable, Codable, Hashable, Sendable {

    // MARK: - Shape-only surfaced cases (V3 §07)

    /// Widescreen 16:9 shape. Held upright it records 9:16 vertical
    /// (TikTok / Reels / Shorts); rotated to landscape it records 16:9
    /// horizontal (YouTube).
    ///
    /// REUSES the raw value `"ratio16x9"` so a persisted 16:9 pick survives
    /// AND so the enum lands on the verified `!wantsPortraitPlayback` branch
    /// of the untouched 2-arg `writerTransform` (its portrait-buffer cell
    /// returns +π/2 — the verified 16:9-user-pick value). See §2.3 of the
    /// design doc. Requires the iOS 26 dynamic-aspect API to land at
    /// non-native crops on the iPhone 17 family square / older 4:3 sensors;
    /// older OSes fall back to `.openGate`.
    case wide = "ratio16x9"

    /// Square 1:1 — Instagram feed. Same either way (held upright or
    /// sideways). iPhone 17 family exposes it natively (1:1 front sensor);
    /// older iPhones need the iOS 26 dynamic-aspect API to crop from 4:3.
    case square = "ratio1x1"

    /// Classic 4:3 — talking-head and legacy YouTube. Held upright records
    /// 3:4 tall; rotated to landscape records 4:3 wide. Works everywhere
    /// because most iPhone front sensors are natively 4:3 (or readable at
    /// 4:3 via dynamic aspect on iPhone 17).
    case classic = "ratio4x3"

    /// Full sensor readout — reframe in post. Same either way. The shipping
    /// default for EVERY user as of 3.1 (and the shape the open-gate
    /// algorithm in CameraStore was originally designed for). It is the only
    /// shape with no `requiresIOS26` constraint and no crop, so it is honored
    /// on every device and OS we ship to — there is nothing to fall back FROM.
    case openGate = "openGate"

    // MARK: - Downgrade-safety / migration-only (NOT offered in the picker)

    /// The old "9:16 vertical" case. Kept ONLY so a persisted `"ratio9x16"`
    /// from a pre-V3 build still decodes and an older downgraded build still
    /// finds a valid case. It is the SAME SHAPE as `.wide` under
    /// auto-orientation. Never listed in the picker (not in `availableAspects`'
    /// canonical list) and never reaches a behavioral call site with its own
    /// identity — `canonicalShape` collapses it to `.wide` first.
    @available(*, deprecated, message: "merged into .wide (V3 §07); kept for downgrade safety")
    case legacyVertical9x16 = "ratio9x16"

    /// Manual `CaseIterable` — auto-synthesis can't handle the
    /// `@available`-annotated `.legacyVertical9x16` case. Lists every case
    /// (alias included, for Codable round-trip coverage). The picker uses
    /// `surfacedCases`, not `allCases`.
    static var allCases: [RecordingAspect] {
        [.wide, .square, .classic, .openGate, .legacyVertical9x16]
    }

    /// Collapse the downgrade-safety alias onto its shape. `legacyVertical9x16`
    /// (old "9:16 vertical") is the SAME SHAPE as `.wide` under
    /// auto-orientation. Every behavioral call site (format selection, writer
    /// transform, preview rotation, avAspectRatio) funnels through this so the
    /// deprecated case never reaches the policy table with its own identity.
    var canonicalShape: RecordingAspect {
        self == .legacyVertical9x16 ? .wide : self
    }

    /// The set of shapes the picker surfaces, in canonical UX order. Open gate
    /// leads because it is the default (3.1) — the picker's first row is also
    /// the selected row on a fresh install. Excludes the downgrade-safety
    /// alias by construction. `availableAspects` in the settings view filters
    /// this by device support.
    static var surfacedCases: [RecordingAspect] {
        [.openGate, .wide, .classic, .square]
    }

    /// Default for *new* users (3.1): the full-sensor readout. `.wide` used to
    /// hold this slot, but 16:9 is a CROP on every front sensor that isn't
    /// natively 16:9 — a surprising first-record aspect on non–iPhone-17
    /// hardware. Open gate is the widest the sensor exposes (square on the
    /// iPhone 17 family, full 4:3 elsewhere), carries no `requiresIOS26`
    /// constraint, and is "never wrong — reframe in post".
    ///
    /// This now MATCHES what `Prefs.migrateRecordingAspectToOpenGate` writes
    /// for existing users, so new and existing installs converge on the same
    /// shape. The migration stays in place (it must: it persists the value
    /// explicitly so a future default change can't silently reshape a
    /// long-time user's recordings) and remains idempotent — it short-circuits
    /// the moment `recordingAspect` has any value.
    static var `default`: RecordingAspect { .openGate }

    /// Settings-row label. Orientation-agnostic (V3 §07) — the shape no
    /// longer names a direction.
    var displayName: String {
        switch canonicalShape {
        case .wide:      return "16:9 widescreen"
        case .square:    return "1:1 square"
        case .classic:   return "4:3 classic"
        case .openGate:  return "open gate (full sensor)"
        // canonicalShape guarantees the alias never reaches here, but the
        // switch must be exhaustive over the deprecated case for the compiler.
        case .legacyVertical9x16: return "16:9 widescreen"
        }
    }

    /// One-line use-case help text shown beneath the picker. States the
    /// auto-orientation rule where it matters (V3 §07).
    var helpText: String {
        switch canonicalShape {
        case .wide:      return "youtube, landscape, or vertical — follows how you hold the phone"
        case .square:    return "instagram feed — same either way"
        case .classic:   return "talking-head; 3:4 tall or 4:3 wide by hold"
        case .openGate:  return "widest your camera captures — square on iPhone 17, vertical elsewhere; reframe in post"
        case .legacyVertical9x16: return "youtube, landscape, or vertical — follows how you hold the phone"
        }
    }

    /// Maps to the iOS 26 `AVCaptureDevice.AspectRatio` enum. Returns nil
    /// for `.openGate` because the format selector handles that case
    /// separately (no `setDynamicAspectRatio` call — keep the native
    /// largest-area readout).
    ///
    /// Reads `canonicalShape` first so the `.legacyVertical9x16` alias
    /// resolves to `.wide` (= raw `"ratio16x9"`) before the switch, keeping
    /// it off the swap with its own identity.
    ///
    /// SWAPPED 9x16↔16x9 (post-pass-13e): user testing on iPhone 17 Pro Max +
    /// iOS 26.3.1 confirmed iOS's reshape behaviour is INVERTED from the
    /// label proportions for the front camera:
    ///   - `AVCaptureAspectRatio9x16` (iOS) → produces a 16:9 LANDSCAPE buffer
    ///   - `AVCaptureAspectRatio16x9` (iOS) → produces a 9:16 PORTRAIT buffer
    /// `.wide` (raw `"ratio16x9"`) therefore requests iOS's `.ratio9x16`,
    /// which on this device produces the portrait 2160×3840 sensor-natural
    /// buffer the whole V3 §07 composition is built on. The pure-square
    /// `.square` and `.classic` (4:3) aren't affected. DO NOT change this
    /// swap without re-verifying via self-test on iPhone 17.
    @available(iOS 26.0, *)
    var avAspectRatio: AVCaptureDevice.AspectRatio? {
        switch canonicalShape {
        case .wide:      return .ratio9x16   // SWAPPED: raw "ratio16x9" → request iOS 9x16 (verified portrait buffer)
        case .square:    return .ratio1x1
        case .classic:   return .ratio4x3
        case .openGate:  return nil
        case .legacyVertical9x16: return .ratio9x16  // unreachable after canonicalShape; matches .wide
        }
    }

    /// True for cases that can ONLY be honored on iOS 26+ (because the
    /// iPhone front sensor isn't natively that aspect and we'd need the
    /// dynamic-aspect API to crop to it). On older OSes we fall back to
    /// `.openGate` and let the user reframe in post.
    ///
    /// `.classic` (4:3) is false because legacy front sensors are natively
    /// 4:3. `.wide` (16:9) is false because we can compute a 16:9 letterbox
    /// from a 4:3 source via the existing fallback logic — the merge does not
    /// gate the widescreen shape behind a device check. `.square` (1:1) is
    /// true (needs a 1:1 crop). `.openGate` is false (no constraint).
    var requiresIOS26: Bool {
        switch canonicalShape {
        case .square: return true
        case .wide, .classic, .openGate: return false
        case .legacyVertical9x16: return false  // resolves to .wide
        }
    }
}
