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
    /// HEVC at ~50 Mbps (1080p) / ~80 Mbps (4K). Matches the native iOS
    /// Camera app's "High Efficiency" output — sane storage rate, fine for
    /// most social platforms.
    case standard

    /// HEVC at ~120 Mbps (1080p) / ~150 Mbps (4K). The "high quality" sweet
    /// spot for prosumer creators. Default. Larger files but no perceptible
    /// banding on talking-head delivery.
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

    /// Average bitrate in bits per second for 1080p content. Used in
    /// `AVVideoCompressionPropertiesKey` payload as `AVVideoAverageBitRateKey`.
    /// 1080p is the front-camera mainstream — 4K writes inherit a scaled
    /// bitrate via `bitsPerSecond(forShortDimension:)`.
    var bitrate1080p: Int {
        switch self {
        case .standard: return 50_000_000
        case .high:     return 120_000_000
        }
    }

    /// Bitrate scaled to the actual recorded pixel count. Linear in pixel
    /// count — quick approximation of the headroom 4K / square sensor needs
    /// over 1080p without going full perceptual modeling.
    ///
    /// IMPORTANT: pass the ACTUAL output dimensions of what's hitting the
    /// writer. The previous fixup pass took only `shortDimension` and
    /// inferred a 16:9 long edge, which on iPhone 17's 1×1 dynamic-aspect
    /// path inflated the bitrate ~80% (3024 short edge × inferred 5376
    /// long edge = 16M pixels vs the real 9M). That produced 213 MB four-
    /// second files at "Standard" — the dogfood smoking gun.
    ///
    /// Cap at ~3× the 1080p baseline so a buffer dimension we mis-detect
    /// can't blow the encoder's hardware budget. The cap is well above the
    /// realistic 4K HEVC working bitrate, so legitimate 4K writes still
    /// land within budget.
    func bitsPerSecond(forPixelCount pixelCount: Int) -> Int {
        let baselinePixels = 1080 * 1920
        let safePixels = max(pixelCount, baselinePixels / 4) // floor on stupid-small inputs
        let scaled = Double(bitrate1080p) * Double(safePixels) / Double(baselinePixels)
        // Floor: never less than 20 Mbps (the bitrate we'd want for a
        // hypothetical 720p tier — a sane minimum for HEVC selfie video).
        // Ceiling: at most 3× the 1080p target, so a misdetected dimension
        // can't drive the encoder past hardware limits.
        let bounded = min(Double(bitrate1080p) * 3.0, max(20_000_000.0, scaled))
        return Int(bounded)
    }

    /// Convenience overload — pass width × height directly. Common at the
    /// writer-config callsite where we already have both dimensions.
    func bitsPerSecond(forWidth width: Int, height: Int) -> Int {
        bitsPerSecond(forPixelCount: max(1, width) * max(1, height))
    }

    /// Legacy short-edge API used by the Settings storage estimator. Kept
    /// for callers that need a "what's the bitrate at 1080p / 4K" guess
    /// without an actual buffer size. Routes through the new pixel-count
    /// formula assuming 16:9 (the short-dim → long-dim relation that the
    /// Settings UI displays storage for).
    func bitsPerSecond(forShortDimension shortDimension: Int) -> Int {
        let inferredLong = shortDimension * 16 / 9
        return bitsPerSecond(forPixelCount: shortDimension * inferredLong)
    }

    /// Approximate storage rate in megabytes per minute, displayed live in
    /// the Settings picker so the user can budget. Calculated from the 1080p
    /// bitrate (the default for the front camera).
    func megabytesPerMinute(framerate: RecordingFramerate) -> Int {
        // bits/s → MB/min: × 60 / 8 / 1_048_576 (1024^2)
        let perMinute = Double(bitrate1080p) * 60.0 / 8.0 / 1_048_576.0
        // Higher framerates carry slightly more cost (encoder spends more
        // bits on temporal motion). Empirical fudge factor mirrors what the
        // iOS Camera app shows in its comparable picker.
        let fpsFactor: Double
        switch framerate {
        case .fps24: fpsFactor = 0.92
        case .fps30: fpsFactor = 1.0
        case .fps60: fpsFactor = 1.18
        }
        return Int((perMinute * fpsFactor).rounded())
    }

    /// Help-text formatter — "high (≈800 MB/min at 30 fps)".
    func descriptionWithStorageEstimate(framerate: RecordingFramerate) -> String {
        let mbpm = megabytesPerMinute(framerate: framerate)
        return "\(displayName) (≈\(mbpm) MB/min at \(framerate.displayName))"
    }
}
