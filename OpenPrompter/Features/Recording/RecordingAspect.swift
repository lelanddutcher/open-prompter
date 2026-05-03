//
//  RecordingAspect.swift
//  OpenPrompter
//
//  User-configurable recording aspect ratio. New users default to `.ratio9x16`
//  (vertical, social-share friendly); existing users who already touched the
//  recording feature are migrated to `.openGate` so their behaviour doesn't
//  change unexpectedly. The dynamic-aspect API is gated to iOS 26+ — the
//  picker filters non-fallback choices accordingly. See V2 Design 02 for
//  the use-case copy below the picker.
//
//  QA REVIEWER FOCUS: every case here has to round-trip Codable cleanly and
//  the iOS 26 mapping in `avAspectRatio` must match `AVCaptureDevice.AspectRatio`
//  raw values. Mismatches surface as silent fallbacks in the format selector.
//

import AVFoundation
import Foundation

/// User-facing recording aspect ratio. Stored as a raw string in
/// `Prefs.recordingAspect` so we can extend without a migration. The
/// `requiresIOS26` flag drives whether the picker offers a given case at
/// runtime (we hide cases that can't be reliably honored on iOS 17–25).
enum RecordingAspect: String, CaseIterable, Codable, Hashable, Sendable {
    /// Vertical 9:16 — TikTok / Reels / Shorts. Default for fresh installs.
    /// Requires the iOS 26 dynamic-aspect API to land at non-native crops on
    /// the iPhone 17 family square / older 4:3 sensors; older OSes fall back
    /// to `.openGate` (which the user can reframe in post).
    case ratio9x16

    /// Square 1:1 — Instagram feed. iPhone 17 family only (the front sensor
    /// is natively 1:1; older iPhones have a 4:3 sensor and would need the
    /// dynamic-aspect API to crop to 1:1).
    case ratio1x1

    /// Classic 4:3 — talking-head and legacy YouTube. Works everywhere
    /// because most iPhone front sensors are natively 4:3 (or readable at
    /// 4:3 via dynamic aspect on iPhone 17).
    case ratio4x3

    /// Horizontal 16:9 — wide YouTube. Works everywhere.
    case ratio16x9

    /// Full sensor readout — reframe in post. The current shipping default
    /// for existing users (and the shape the open-gate algorithm in
    /// CameraStore was originally designed for).
    case openGate

    /// Default for *new* users. Existing users get migrated to `.openGate`
    /// via `Prefs.migrateRecordingAspectToOpenGate`.
    static var `default`: RecordingAspect { .ratio9x16 }

    /// Settings-row label.
    var displayName: String {
        switch self {
        case .ratio9x16: return "9:16 vertical"
        case .ratio1x1:  return "1:1 square"
        case .ratio4x3:  return "4:3 classic"
        case .ratio16x9: return "16:9 horizontal"
        case .openGate:  return "open gate (full sensor)"
        }
    }

    /// One-line use-case help text shown beneath the picker.
    var helpText: String {
        switch self {
        case .ratio9x16: return "tiktok / reels / shorts"
        case .ratio1x1:  return "instagram feed"
        case .ratio4x3:  return "talking-head & legacy youtube"
        case .ratio16x9: return "youtube wide"
        case .openGate:  return "reframe in post"
        }
    }

    /// Maps to the iOS 26 `AVCaptureDevice.AspectRatio` enum. Returns nil
    /// for `.openGate` because the format selector handles that case
    /// separately (no `setDynamicAspectRatio` call — keep the native
    /// largest-area readout). Returns nil on non-mappable cases too.
    @available(iOS 26.0, *)
    var avAspectRatio: AVCaptureDevice.AspectRatio? {
        switch self {
        case .ratio9x16: return .ratio9x16
        case .ratio1x1:  return .ratio1x1
        case .ratio4x3:  return .ratio4x3
        case .ratio16x9: return .ratio16x9
        case .openGate:  return nil
        }
    }

    /// True for cases that can ONLY be honored on iOS 26+ (because the
    /// iPhone front sensor isn't natively that aspect and we'd need the
    /// dynamic-aspect API to crop to it). On older OSes we fall back to
    /// `.openGate` and let the user reframe in post — the dim classifier
    /// can't reliably distinguish 9:16 from 16:9 on a 4:3 sensor.
    ///
    /// `.ratio4x3` and `.ratio16x9` are both false because legacy front
    /// sensors are natively 4:3 (so `.ratio4x3` is a no-op crop) and we
    /// can compute a 16:9 letterbox from a 4:3 source via the existing
    /// fallback logic. `.openGate` is false (no constraint).
    var requiresIOS26: Bool {
        switch self {
        case .ratio9x16, .ratio1x1: return true
        case .ratio4x3, .ratio16x9, .openGate: return false
        }
    }
}
