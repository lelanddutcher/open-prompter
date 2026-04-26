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
    ///
    /// Targeting *social-creator* file sizes rather than cinema-grade:
    /// - Standard 25 Mbps ≈ 11 MB / 30 s — close to iPhone Camera's 1080p
    ///   HEVC default scaled up for 9 MP square output. Plenty of quality
    ///   for talking-head selfie content; manageable file sizes for sharing.
    /// - High 50 Mbps ≈ 22 MB / 30 s — matches iPhone Camera's 4K30 HEVC
    ///   default. Pro headroom for users who plan to do significant grading
    ///   or reframing in post.
    ///
    /// Earlier iterations shipped 150 Mbps Standard / 360 Mbps High because
    /// the formula scaled by pixel count, which produced absurd file sizes
    /// (213 MB for a 4 s file) AND blew the hardware encoder budget at
    /// 30/60 fps (22.68 fps recorded vs 24 requested — the encoder dropped
    /// frames trying to satisfy the bitrate). The numbers below match the
    /// user's social-share expectations and stay well under the encoder
    /// ceiling on iPhone 17.
    var averageBitRate: Int {
        switch self {
        case .standard: return 25_000_000     // 25 Mbps — social-share friendly
        case .high:     return 50_000_000     // 50 Mbps — matches iOS Camera 4K
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
