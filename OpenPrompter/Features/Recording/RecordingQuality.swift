//
//  RecordingQuality.swift
//  OpenPrompter
//
//  Two-tier quality picker: Standard HEVC and High HEVC. ProRes was scoped
//  out by the user — a 220-470 Mbps tier on the front-facing camera doesn't
//  meaningfully serve any selfie-creator use case and the storage burn is
//  punishing. See V2 Design 02 §"Recording quality picker" — review note 8.
//

import AVFoundation
import Foundation

/// Codec + bitrate tier for the recording session. Picker shows both tiers
/// in Settings with a live storage estimate that takes the chosen framerate
/// into account.
enum RecordingQuality: String, CaseIterable, Codable, Hashable, Sendable {
    /// HEVC at ~50 Mbps. Matches the native iOS Camera app's "High Efficiency"
    /// 4K30 output — sane storage rate, fine for most social platforms.
    case standard

    /// HEVC at ~120 Mbps. The "high quality" sweet spot for prosumer
    /// creators. Default. Larger files but no perceptible banding on
    /// talking-head delivery.
    case high

    static var `default`: RecordingQuality { .high }

    /// User-facing label for Settings (lowercase to match house style).
    var displayName: String {
        switch self {
        case .standard: return "standard"
        case .high:     return "high"
        }
    }

    /// AVFoundation codec identifier. We never ship ProRes through this
    /// pipeline — both tiers go through HEVC. The codec key is wired into
    /// `videoSettings` via `AVVideoCodecKey`.
    var codec: AVVideoCodecType { .hevc }

    /// Average bitrate in bits per second. Fixed per tier; we don't scale
    /// with pixel count because HEVC scales encoding effort with resolution
    /// and the iPhone 17 hardware encoder works hard to keep within budget.
    /// Asking it for 150 Mbps at 12 MP causes frame drops (the 22.68 fps
    /// dogfood symptom). Real iOS Camera ships HEVC at 50 Mbps for 4K30 and
    /// the world is fine — HEVC compresses very efficiently and we don't
    /// need to scale bitrate with pixel count for selfie content.
    var averageBitRate: Int {
        switch self {
        case .standard: return 50_000_000     // 50 Mbps — matches iOS Camera 4K
        case .high:     return 120_000_000    // 120 Mbps — pro-creator headroom
        }
    }

    /// 60 fps gets a 50% bonus to maintain visible quality on motion. Frame
    /// rate effectively doubles per-frame compression demand; HEVC handles
    /// most of that but a small bump avoids visible blocking on fast motion.
    func averageBitRate(framerate: Int) -> Int {
        let base = averageBitRate
        return framerate >= 60 ? Int(Double(base) * 1.5) : base
    }

    /// Approximate storage rate in megabytes per minute, displayed live in
    /// the Settings picker so the user can budget. Calculated from the fixed
    /// per-tier bitrate, framerate-aware (60 fps = 1.5× the 30 fps base).
    func megabytesPerMinute(framerate: RecordingFramerate) -> Int {
        // bits/s → MB/min: × 60 / 8 / 1_048_576 (1024^2)
        let bps = averageBitRate(framerate: framerate.fps)
        let perMinute = Double(bps) * 60.0 / 8.0 / 1_048_576.0
        return Int(perMinute.rounded())
    }

    /// Help-text formatter — "high (≈900 MB/min at 30 fps)".
    func descriptionWithStorageEstimate(framerate: RecordingFramerate) -> String {
        let mbpm = megabytesPerMinute(framerate: framerate)
        return "\(displayName) (≈\(mbpm) MB/min at \(framerate.displayName))"
    }
}
