//
//  RecordingSelfTest.swift
//  OpenPrompter
//
//  DEBUG-only diagnostic harness for the recording pipeline. Reads back
//  the most recent .mov in `Documents/Recordings/`, decodes it via
//  `AVAsset`, samples a 5-point brightness grid for orientation diagnosis,
//  exports the first frame as a PNG, and writes a JSON report next to the
//  recording so the orchestrator can pull both the JSON and the PNG via
//  `xcrun devicectl device copy from`. The on-screen alert shows a
//  pass/fail summary; the JSON has the full numeric detail.
//
//  Why this exists: most recording bugs (black first frame, wrong
//  bitrate, stretched aspect, dropped framerate, sideways playback) only
//  manifest on real hardware. The simulator can't fake a camera. This
//  harness gives the orchestrator a fast feedback loop without asking
//  the user to read off Photos metadata manually.
//
//  Surfaced via the "Run Recording Self-Test" button in
//  `Settings → Labs` (DEBUG only). Workflow:
//    1. User records a normal take in the prompter (any duration ≥ 2 s).
//    2. User opens Settings, scrolls to Labs, taps "Run Recording Self-Test".
//    3. The harness reads the most-recent .mov, runs assertions, shows
//       an alert AND writes:
//         Documents/SelfTest.json            (machine-readable report)
//         Documents/SelfTestFirstFrame.png   (visual orientation check)
//    4. Orchestrator pulls both files via:
//         xcrun devicectl device copy from --device <UDID> \
//           --user mobile --domain temporary \
//           --source SelfTest.json --destination /tmp/selftest.json
//         xcrun devicectl device copy from --device <UDID> \
//           --user mobile --domain temporary \
//           --source SelfTestFirstFrame.png --destination /tmp/selftest-firstframe.png
//
//  Dogfood-pass-12 redesign: the prior version reported single-point
//  brightness + transform components, which couldn't disambiguate
//  "buffer is portrait but transform rotates it" vs "buffer is landscape
//  and transform corrects it." User feedback on that report: "It's not
//  specific enough to give you intel on where the bug is. You're going
//  to have to really make that tool more robust if you want to rely on
//  it for dev." This rewrite addresses that with:
//   1. First-frame PNG export (visual ground truth — no inference needed)
//   2. 5-point brightness grid (TL, TR, BL, BR, C) → vertical/horizontal
//      gradient → scan-direction diagnosis without needing a known scene
//   3. Capture-time context (picker aspect, device model, iOS version,
//      mirror state, recording quality/framerate) so the orchestrator
//      doesn't have to ask "which aspect was this?"
//   4. Per-aspect expected-vs-actual assertion driven by `OrientationPolicy`
//      so the JSON declares pass/fail per intent.
//

import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import MobileCoreServices
import UIKit

#if DEBUG

/// 5-point brightness sampling of a single frame. Each value is average
/// luminance in [0, 1] from a 60×60 pixel patch at that grid position.
/// Computed gradients (`verticalGradient`, `horizontalGradient`) tell the
/// orchestrator scan direction without needing a known scene.
struct BrightnessGrid: Codable {
    /// Top-left 60×60 patch, ~10% in from each edge.
    let topLeft: Double
    /// Top-right 60×60 patch.
    let topRight: Double
    /// Bottom-left 60×60 patch.
    let bottomLeft: Double
    /// Bottom-right 60×60 patch.
    let bottomRight: Double
    /// Center 60×60 patch (matches the legacy single-point sample).
    let center: Double

    /// Average top brightness minus average bottom brightness.
    /// Positive = top is brighter (typical: ceiling/sky scene record).
    /// Negative = bottom is brighter (suggests upside-down OR the user's
    /// scene was bright-bottomed).
    /// Magnitude < 0.05 = roughly uniform, can't infer scan direction.
    var verticalGradient: Double {
        return (topLeft + topRight) / 2.0 - (bottomLeft + bottomRight) / 2.0
    }

    /// Average left brightness minus average right brightness.
    /// Positive = left is brighter, negative = right is brighter.
    var horizontalGradient: Double {
        return (topLeft + bottomLeft) / 2.0 - (topRight + bottomRight) / 2.0
    }

    /// Human-readable scan-direction guess from the gradients. The
    /// orchestrator can use this to compare against expected scan
    /// direction for a given aspect on a given device.
    var gradientSummary: String {
        let v = verticalGradient
        let h = horizontalGradient
        let vDesc = abs(v) < 0.05 ? "uniform" : (v > 0 ? "top-bright" : "bottom-bright")
        let hDesc = abs(h) < 0.05 ? "uniform" : (h > 0 ? "left-bright" : "right-bright")
        return "v=\(String(format: "%+.3f", v)) (\(vDesc)), h=\(String(format: "%+.3f", h)) (\(hDesc))"
    }
}

/// Capture-time context — what the user had set when the recording was made.
/// Read at self-test analyze time from `Prefs` and `UIDevice`. This assumes
/// the user runs the self-test soon after recording (settings haven't
/// changed). For maximum rigor we'd write a sidecar at record time, but in
/// dev usage the simpler path is fine.
struct CaptureContext: Codable {
    /// Raw `Prefs.recordingAspect` value at self-test time (e.g.
    /// `"ratio9x16"`). Lets the orchestrator filter JSON files by aspect.
    let pickerAspectRaw: String
    /// Human-readable picker label (e.g. `"9:16 vertical"`).
    let pickerAspectName: String
    /// Mirror state at self-test time. Mirror is preview-only — the file
    /// is never mirrored — but knowing this is useful for orientation
    /// regression when both rotation and mirror were on simultaneously.
    let mirrorHorizontal: Bool
    let mirrorVertical: Bool
    /// `utsname.machine` identifier (e.g. `"iPhone18,2"` for iPhone 17
    /// Pro Max). Drives device-class lookups in `OrientationPolicy`.
    let deviceModelIdentifier: String
    /// Marketing model name (e.g. `"iPhone"`).
    let deviceModelName: String
    /// `UIDevice.systemVersion` (e.g. `"26.0.1"`).
    let iosVersion: String
    /// Recording quality preset at self-test time (`"standard"` / `"high"`).
    let recordingQuality: String
    /// Recording framerate preset at self-test time (`"fps24"` / `"fps30"` / `"fps60"`).
    let recordingFramerate: String
}

/// Per-aspect expectation vs. actual file dims/transform. Computed from
/// `OrientationPolicy` against the record-time picker aspect, so the JSON
/// directly reports "this aspect intended X, file delivered Y."
struct OrientationExpectation: Codable {
    /// What `OrientationPolicy.writerTransform(for:)` returns for the
    /// captured picker aspect, flattened to [a, b, c, d].
    let expectedTransform: [Double]
    /// The actual `videoTrack.preferredTransform`, flattened.
    let actualTransform: [Double]
    /// True if `expectedTransform` and `actualTransform` agree within
    /// 0.01 per component. False means the file's transform doesn't match
    /// the policy table for the captured aspect — actionable signal.
    let transformMatches: Bool
    /// Expected aspect ratio (W/H) at PLAYBACK based on the picker
    /// aspect — `1.0` for square, `0.5625` for 9:16 portrait, etc.
    let expectedPlaybackAspectRatio: Double
    /// Actual playback aspect ratio (computed from encoded dims composed
    /// with the actual transform).
    let actualPlaybackAspectRatio: Double
    /// True if the actual playback aspect ratio is within ±5% of expected.
    let aspectRatioMatches: Bool
}

/// Result of a single self-test run. Codable so we can write it to
/// `Documents/SelfTest.json` and read it via devicectl on the orchestrator
/// side. Fields are flat (with one level of nested structs for grouped
/// concerns) so a quick `cat selftest.json | jq` is human-readable.
struct SelfTestResult: Codable {

    /// Wall-clock time the self-test ran. ISO-8601.
    let testRanAt: String

    /// Filename of the recording that was analyzed (no path — keeps the
    /// JSON self-contained even when pulled to a different machine).
    let recordingName: String

    /// File size on disk in bytes. Used to compute effective bitrate
    /// (file_size × 8 / duration).
    let fileSizeBytes: Int64

    /// Duration in seconds, decoded from the asset (not estimated).
    let durationSeconds: Double

    /// Track counts. `videoTracks` should be 1 for a normal take;
    /// `audioTracks` is 1 if mic is attached, 0 otherwise.
    let videoTrackCount: Int
    let audioTrackCount: Int

    /// Encoded buffer dimensions. Note that this is the natural size
    /// before any rotation transform; for portrait files the displayed
    /// size is the swapped pair.
    let videoWidth: Int
    let videoHeight: Int

    /// `videoTrack.preferredTransform` flattened into its 4 affine
    /// components (a, b, c, d) — non-identity means a writer-level
    /// rotation transform is in play.
    let preferredTransform: [Double]

    /// Playback-display dimensions composed from `videoWidth/Height` and
    /// `preferredTransform`. A 90/270° rotation swaps; identity/180°
    /// keeps. This is what the user actually sees in Photos.
    let playbackWidth: Int
    let playbackHeight: Int

    /// Nominal frame rate decoded by AVFoundation. Will be 24/30/60 (or
    /// close — encoder VFR can land slightly off).
    let nominalFrameRate: Float

    /// Codec FourCC ("hvc1" for HEVC, "avc1" for H.264).
    let codecFourCC: String

    /// File-size-derived bitrate (bps). The actual encoder target lives
    /// in the writer settings; this is what the encoder produced.
    let computedBitrateBps: Int64

    /// Brightness sampled at four timestamps in the duration. Used to
    /// verify the warmup-frame drop: `firstFrameBrightness` should be
    /// > 0.05 (not pitch black) for a normal take.
    let firstFrameBrightness: Double
    let frameAt100msBrightness: Double
    let frameAt500msBrightness: Double
    let midpointFrameBrightness: Double

    /// 5-point brightness grid sampled from the FIRST frame. Used to
    /// detect scan direction (top-bright vs bottom-bright, etc.).
    let firstFrameGrid: BrightnessGrid

    /// Capture-time context (picker aspect, device, mirror, quality, fps).
    let context: CaptureContext

    /// Per-aspect expectation vs. actual orientation match.
    let orientationExpectation: OrientationExpectation

    /// Path to the first-frame PNG that was exported alongside this JSON
    /// (relative to the user's Documents directory). Empty string if the
    /// PNG export failed.
    let firstFramePNGRelativePath: String

    /// Pass/fail flags for each assertion. The on-screen alert summarizes
    /// these as ✅ / ❌; the JSON keeps the detail for the orchestrator.
    let assertions: [Assertion]

    struct Assertion: Codable {
        let name: String
        let passed: Bool
        let detail: String
    }
}

/// Pure analysis logic — no UI, no SwiftUI dependencies. Callable from
/// any actor context. Marked `@MainActor` because `AVAssetImageGenerator`
/// expects to be driven from a single context for its delegate callbacks
/// (we use the synchronous `copyCGImage` path so this is mostly a
/// formality, but keeps the call sites clean).
@MainActor
enum RecordingSelfTest {

    /// Find the most recent .mov in `Documents/Recordings/` and run the
    /// full analysis. Returns nil if no recordings exist yet.
    static func runOnMostRecentRecording() async -> SelfTestResult? {
        guard let url = mostRecentRecordingURL() else { return nil }
        return await analyze(url: url)
    }

    /// Pure analyze entry point — call this if you want to test a specific
    /// .mov path (e.g. from a recovery flow).
    static func analyze(url: URL) async -> SelfTestResult? {
        let asset = AVURLAsset(url: url, options: [
            AVURLAssetPreferPreciseDurationAndTimingKey: true
        ])

        // File size on disk.
        let fileSize: Int64 = {
            (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        }()

        // Duration. `AVAsset.duration` is async-loadable in iOS 16+ via
        // `load(.duration)`; fall back to the deprecated sync property if
        // that ever surfaces an issue (it shouldn't on iOS 17+).
        let duration: CMTime = (try? await asset.load(.duration)) ?? .zero
        let durationSeconds = max(0, duration.seconds.isFinite ? duration.seconds : 0)

        // Track inspection.
        let videoTracks = (try? await asset.loadTracks(withMediaType: .video)) ?? []
        let audioTracks = (try? await asset.loadTracks(withMediaType: .audio)) ?? []

        // First video track — sample its dimensions, transform, framerate, codec.
        var videoWidth: Int = 0
        var videoHeight: Int = 0
        var preferredTransform: [Double] = [1, 0, 0, 1]
        var nominalFrameRate: Float = 0
        var codecFourCC: String = "----"
        if let track = videoTracks.first {
            let naturalSize: CGSize = (try? await track.load(.naturalSize)) ?? .zero
            videoWidth = Int(naturalSize.width)
            videoHeight = Int(naturalSize.height)
            let transform: CGAffineTransform = (try? await track.load(.preferredTransform)) ?? .identity
            preferredTransform = [Double(transform.a), Double(transform.b), Double(transform.c), Double(transform.d)]
            nominalFrameRate = (try? await track.load(.nominalFrameRate)) ?? 0
            // Codec FourCC lives in the format description — load it.
            if let formatDescriptions = try? await track.load(.formatDescriptions),
               let firstFmt = formatDescriptions.first {
                let mediaSubType = CMFormatDescriptionGetMediaSubType(firstFmt)
                codecFourCC = fourCCString(from: mediaSubType)
            }
        }

        // Frame brightness samples. Sampling at fixed wall-clock offsets
        // rather than fractions of duration so a 5 s take and a 2 s take
        // both probe the warmup window.
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = false   // raw frame, no rotation
        generator.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 60)
        generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 60)

        // Capture the first frame's CGImage ONCE — used for both brightness
        // sampling AND the PNG export. Re-decoding the same frame for each
        // sample wasted ~80 ms in the prior version.
        let firstFrameImage: CGImage? = try? generator.copyCGImage(at: .zero, actualTime: nil)
        let firstFrame = firstFrameImage.map(averageCenterLuminance) ?? 0.0
        let firstFrameGrid = firstFrameImage.map(brightnessGrid) ?? .zero
        let frame100ms = brightness(at: CMTime(value: 100, timescale: 1000), generator: generator)
        let frame500ms = brightness(at: CMTime(value: 500, timescale: 1000), generator: generator)
        let midpoint: CMTime = duration.seconds.isFinite && duration.seconds > 0
            ? CMTime(seconds: duration.seconds / 2, preferredTimescale: 600)
            : .zero
        let frameMid = brightness(at: midpoint, generator: generator)

        let computedBitrateBps: Int64 = durationSeconds > 0
            ? Int64(Double(fileSize) * 8 / durationSeconds)
            : 0

        // Compose encoded dims with the file's preferredTransform to get
        // the actual playback orientation. The dogfood-pass-10 bug had
        // encoded portrait + rotation transform = sideways playback.
        let (playbackW, playbackH) = playbackDimensions(
            encodedWidth: videoWidth,
            encodedHeight: videoHeight,
            transform: preferredTransform
        )

        // Read capture-time context (picker, device, mirror, quality/fps).
        let context = currentCaptureContext()

        // Per-aspect expectation: what does OrientationPolicy say the
        // transform SHOULD be for the captured picker aspect?
        let pickerAspect = RecordingAspect(rawValue: context.pickerAspectRaw) ?? .default
        let expectedTransform = OrientationPolicy.writerTransform(for: pickerAspect)
        let expectedTransformArray: [Double] = [
            Double(expectedTransform.a), Double(expectedTransform.b),
            Double(expectedTransform.c), Double(expectedTransform.d)
        ]
        let transformMatches = transformsAreClose(preferredTransform, expectedTransformArray, tolerance: 0.01)
        let expectedAspectRatio = expectedPlaybackAspectRatio(for: pickerAspect)
        let actualPlaybackAspect = playbackH > 0 ? Double(playbackW) / Double(playbackH) : 0.0
        let aspectRatioMatches = expectedAspectRatio > 0 &&
            abs(actualPlaybackAspect - expectedAspectRatio) < (expectedAspectRatio * 0.05)
        let orientationExpectation = OrientationExpectation(
            expectedTransform: expectedTransformArray,
            actualTransform: preferredTransform,
            transformMatches: transformMatches,
            expectedPlaybackAspectRatio: expectedAspectRatio,
            actualPlaybackAspectRatio: actualPlaybackAspect,
            aspectRatioMatches: aspectRatioMatches
        )

        // Export first-frame PNG for visual orientation diagnosis.
        let pngRelativePath: String = (firstFrameImage.flatMap(writeFirstFramePNG) != nil)
            ? "SelfTestFirstFrame.png" : ""

        // Build assertions. These are the symptoms the orchestrator can
        // see from a single .mov inspection — anything that depends on
        // live preview or session state is out of scope here.
        var assertions: [SelfTestResult.Assertion] = []
        assertions.append(.init(
            name: "duration > 0.5s",
            passed: durationSeconds > 0.5,
            detail: String(format: "duration = %.3fs", durationSeconds)
        ))
        assertions.append(.init(
            name: "video track exists",
            passed: !videoTracks.isEmpty,
            detail: "tracks = \(videoTracks.count)"
        ))
        assertions.append(.init(
            name: "audio track exists",
            passed: !audioTracks.isEmpty,
            detail: "tracks = \(audioTracks.count) (0 means mic was unavailable)"
        ))
        assertions.append(.init(
            name: "playback orientation is portrait or square",
            passed: playbackH >= playbackW && playbackH > 0,
            detail: "encoded \(videoWidth)×\(videoHeight) + transform \(preferredTransform) → playback \(playbackW)×\(playbackH)"
        ))
        assertions.append(.init(
            name: "transform matches OrientationPolicy for aspect '\(context.pickerAspectRaw)'",
            passed: transformMatches,
            detail: "expected \(expectedTransformArray), got \(preferredTransform)"
        ))
        assertions.append(.init(
            name: "playback aspect ratio matches picker '\(context.pickerAspectRaw)'",
            passed: aspectRatioMatches,
            detail: String(format: "expected %.4f, got %.4f (±5%%)", expectedAspectRatio, actualPlaybackAspect)
        ))
        assertions.append(.init(
            name: "first frame is not black (brightness > 0.05)",
            passed: firstFrame > 0.05,
            detail: String(format: "first = %.3f, 100ms = %.3f, 500ms = %.3f, mid = %.3f",
                           firstFrame, frame100ms, frame500ms, frameMid)
        ))
        assertions.append(.init(
            name: "first-frame brightness grid not pitch-black anywhere",
            passed: [firstFrameGrid.topLeft, firstFrameGrid.topRight, firstFrameGrid.bottomLeft,
                     firstFrameGrid.bottomRight, firstFrameGrid.center].allSatisfy { $0 > 0.01 },
            detail: "TL=\(String(format: "%.3f", firstFrameGrid.topLeft)) TR=\(String(format: "%.3f", firstFrameGrid.topRight)) BL=\(String(format: "%.3f", firstFrameGrid.bottomLeft)) BR=\(String(format: "%.3f", firstFrameGrid.bottomRight)) C=\(String(format: "%.3f", firstFrameGrid.center)) — \(firstFrameGrid.gradientSummary)"
        ))
        assertions.append(.init(
            name: "framerate is 24/30/60 ± 1",
            passed: [24.0, 30.0, 60.0].contains(where: { abs(Float($0) - nominalFrameRate) < 1.0 }),
            detail: String(format: "nominal = %.2f fps", nominalFrameRate)
        ))
        assertions.append(.init(
            name: "codec is HEVC",
            passed: codecFourCC == "hvc1" || codecFourCC == "hev1",
            detail: "fourCC = \(codecFourCC)"
        ))
        assertions.append(.init(
            name: "computed bitrate ≤ 200 Mbps (Standard cap is 25, High cap is 50, 60fps adds 50%)",
            passed: computedBitrateBps <= 200_000_000,
            detail: String(format: "computed = %.1f Mbps", Double(computedBitrateBps) / 1_000_000)
        ))
        assertions.append(.init(
            name: "first-frame PNG exported",
            passed: !pngRelativePath.isEmpty,
            detail: pngRelativePath.isEmpty ? "PNG export failed" : "Documents/\(pngRelativePath)"
        ))

        return SelfTestResult(
            testRanAt: ISO8601DateFormatter().string(from: .now),
            recordingName: url.lastPathComponent,
            fileSizeBytes: fileSize,
            durationSeconds: durationSeconds,
            videoTrackCount: videoTracks.count,
            audioTrackCount: audioTracks.count,
            videoWidth: videoWidth,
            videoHeight: videoHeight,
            preferredTransform: preferredTransform,
            playbackWidth: playbackW,
            playbackHeight: playbackH,
            nominalFrameRate: nominalFrameRate,
            codecFourCC: codecFourCC,
            computedBitrateBps: computedBitrateBps,
            firstFrameBrightness: firstFrame,
            frameAt100msBrightness: frame100ms,
            frameAt500msBrightness: frame500ms,
            midpointFrameBrightness: frameMid,
            firstFrameGrid: firstFrameGrid,
            context: context,
            orientationExpectation: orientationExpectation,
            firstFramePNGRelativePath: pngRelativePath,
            assertions: assertions
        )
    }

    /// Persist the result as JSON at the well-known `Documents/SelfTest.json`
    /// location so devicectl's `--source SelfTest.json` pull works without
    /// knowing the recording stem. Returns the canonical destination URL on
    /// success.
    static func writeReport(_ result: SelfTestResult) -> URL? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(result) else { return nil }

        guard let docs = documentsURL() else { return nil }

        let canonical = docs.appendingPathComponent("SelfTest.json")
        try? data.write(to: canonical, options: .atomic)
        return canonical
    }

    // MARK: - Internals

    private static func mostRecentRecordingURL() -> URL? {
        guard let docs = documentsURL() else { return nil }

        // First-choice path: the DEBUG-only canonical copy that
        // RecordingSession stashes BEFORE Photos save deletes the original.
        let canonical = docs.appendingPathComponent("SelfTestLastRecording.mov")
        if FileManager.default.fileExists(atPath: canonical.path) {
            return canonical
        }

        // Fallback: a stale .mov in Documents/Recordings/ (the recovery-
        // flow surface — only present after a force-quit interrupted a
        // take). Useful for testing the recovery path itself.
        let recordings = docs.appendingPathComponent("Recordings", isDirectory: true)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: recordings, includingPropertiesForKeys: [.creationDateKey, .contentModificationDateKey]
        ) else { return nil }
        let movies = entries.filter { $0.pathExtension.lowercased() == "mov" }
        let sorted = movies.sorted { lhs, rhs in
            let lhsDate = (try? lhs.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            let rhsDate = (try? rhs.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            return lhsDate > rhsDate
        }
        return sorted.first
    }

    /// Sample a center 60×60 patch of the frame at `time`. Returns
    /// average luminance in [0, 1] using ITU-R 601 YCbCr luma weights.
    /// Returns 0.0 on failure (which the assertion treats as "black").
    private static func brightness(at time: CMTime, generator: AVAssetImageGenerator) -> Double {
        guard let cgImage = try? generator.copyCGImage(at: time, actualTime: nil) else {
            return 0.0
        }
        return averageCenterLuminance(of: cgImage)
    }

    /// Average luminance of a centered 60×60 patch — the legacy single-
    /// point sample. Used for non-first frames where we don't need the
    /// full 5-point grid.
    private static func averageCenterLuminance(of image: CGImage) -> Double {
        let cx = image.width / 2 - 30
        let cy = image.height / 2 - 30
        return averagePatchLuminance(of: image, at: CGPoint(x: cx, y: cy), size: 60)
    }

    /// 5-point brightness grid for orientation diagnosis. Patches are 60×60
    /// pixels at 10% inset from each edge — far enough from the corners
    /// that vignetting / lens-shading bias is small, far enough from the
    /// center that gradients are detectable.
    private static func brightnessGrid(of image: CGImage) -> BrightnessGrid {
        let w = image.width
        let h = image.height
        guard w > 200, h > 200 else { return .zero }
        let inset = max(60, min(w, h) / 10)
        let patch = 60
        // CGImage origin is top-left in the geometric sense for the bitmap
        // (when rendered into a top-left-origin context). We measure in
        // BUFFER coordinates here — the PNG export and the gradient labels
        // both use buffer-space "top" / "bottom" so the orchestrator can
        // see the same orientation in the JSON and the PNG.
        let topY    = inset
        let bottomY = h - inset - patch
        let leftX   = inset
        let rightX  = w - inset - patch
        let cx      = w / 2 - patch / 2
        let cy      = h / 2 - patch / 2
        return BrightnessGrid(
            topLeft:     averagePatchLuminance(of: image, at: CGPoint(x: leftX,  y: topY),    size: patch),
            topRight:    averagePatchLuminance(of: image, at: CGPoint(x: rightX, y: topY),    size: patch),
            bottomLeft:  averagePatchLuminance(of: image, at: CGPoint(x: leftX,  y: bottomY), size: patch),
            bottomRight: averagePatchLuminance(of: image, at: CGPoint(x: rightX, y: bottomY), size: patch),
            center:      averagePatchLuminance(of: image, at: CGPoint(x: cx,     y: cy),      size: patch)
        )
    }

    /// Average luminance of a `size × size` patch starting at `origin` in
    /// the source image. Returns 0.0 on out-of-bounds or failure.
    private static func averagePatchLuminance(of image: CGImage, at origin: CGPoint, size: Int) -> Double {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0, size > 0 else { return 0.0 }

        let patchX = max(0, Int(origin.x))
        let patchY = max(0, Int(origin.y))
        let actualW = min(size, width - patchX)
        let actualH = min(size, height - patchY)
        guard actualW > 0, actualH > 0 else { return 0.0 }

        var pixels = [UInt8](repeating: 0, count: actualW * actualH)
        let colorSpace = CGColorSpaceCreateDeviceGray()
        guard let context = pixels.withUnsafeMutableBytes({ buffer -> CGContext? in
            CGContext(
                data: buffer.baseAddress,
                width: actualW,
                height: actualH,
                bitsPerComponent: 8,
                bytesPerRow: actualW,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            )
        }) else {
            return 0.0
        }

        // Draw the source so the requested patch lands inside the
        // (0,0)–(actualW,actualH) rect.
        context.draw(
            image,
            in: CGRect(x: -CGFloat(patchX),
                       y: -CGFloat(patchY),
                       width: CGFloat(width),
                       height: CGFloat(height))
        )

        let sum = pixels.reduce(0) { $0 + Int($1) }
        return Double(sum) / Double(pixels.count) / 255.0
    }

    /// Encode `image` as PNG and write to `Documents/SelfTestFirstFrame.png`.
    /// Returns the destination URL on success, nil on failure.
    private static func writeFirstFramePNG(_ image: CGImage) -> URL? {
        guard let docs = documentsURL() else { return nil }
        let url = docs.appendingPathComponent("SelfTestFirstFrame.png")
        try? FileManager.default.removeItem(at: url)
        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL,
            "public.png" as CFString,
            1, nil
        ) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest) ? url : nil
    }

    private static func documentsURL() -> URL? {
        return try? FileManager.default.url(
            for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: false
        )
    }

    private static func fourCCString(from code: FourCharCode) -> String {
        let bytes: [UInt8] = [
            UInt8((code >> 24) & 0xff),
            UInt8((code >> 16) & 0xff),
            UInt8((code >> 8)  & 0xff),
            UInt8( code        & 0xff)
        ]
        let str = String(bytes: bytes, encoding: .ascii) ?? "----"
        return str.replacingOccurrences(of: "\0", with: "")
    }

    /// Read capture-time context from `Prefs` + `UIDevice` at self-test
    /// time. Assumes the user runs the self-test soon after recording
    /// (settings haven't changed). For maximum rigor we'd write a sidecar
    /// at record time, but this is sufficient for dev usage.
    private static func currentCaptureContext() -> CaptureContext {
        let aspectRaw = Prefs.recordingAspect
        let aspect = RecordingAspect(rawValue: aspectRaw) ?? .default
        return CaptureContext(
            pickerAspectRaw: aspectRaw,
            pickerAspectName: aspect.displayName,
            mirrorHorizontal: Prefs.hMirrorDefault,
            mirrorVertical: Prefs.vMirrorDefault,
            deviceModelIdentifier: deviceModelIdentifier(),
            deviceModelName: UIDevice.current.model,
            iosVersion: UIDevice.current.systemVersion,
            recordingQuality: Prefs.recordingQuality,
            recordingFramerate: Prefs.recordingFramerate
        )
    }

    /// Read the device's hardware identifier (e.g. `"iPhone18,2"` for
    /// iPhone 17 Pro Max) via `utsname`. `UIDevice.current.model` only
    /// returns the marketing class (`"iPhone"`); we want the specific
    /// hardware revision so `OrientationPolicy` can branch by sensor
    /// generation if needed.
    private static func deviceModelIdentifier() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let mirror = Mirror(reflecting: systemInfo.machine)
        return mirror.children.compactMap { element -> String? in
            guard let value = element.value as? Int8, value != 0 else { return nil }
            return String(UnicodeScalar(UInt8(bitPattern: value)))
        }.joined()
    }

    nonisolated private static func isPortraitTransform(_ t: [Double]) -> Bool {
        // Portrait-rotated 90° transform: a=0, b=1, c=-1, d=0
        // (or 270°: a=0, b=-1, c=1, d=0). Identity is a=1, d=1.
        guard t.count == 4 else { return false }
        return abs(t[0]) < 0.01 && abs(t[3]) < 0.01 &&
               (abs(t[1] - 1) < 0.01 || abs(t[1] + 1) < 0.01) &&
               (abs(t[2] - 1) < 0.01 || abs(t[2] + 1) < 0.01)
    }

    /// Compute the playback-display dimensions of a video by composing the
    /// encoded buffer dims with the file's `preferredTransform`. A 90° or
    /// 270° rotation (transform with a=0, d=0 — see `isPortraitTransform`)
    /// swaps the W/H axes at playback. Identity and 180° leave them.
    ///
    /// Pure value-in/value-out for unit testability. `nonisolated` so tests
    /// can call it from any actor context.
    nonisolated static func playbackDimensions(
        encodedWidth: Int,
        encodedHeight: Int,
        transform: [Double]
    ) -> (width: Int, height: Int) {
        if isPortraitTransform(transform) {
            return (width: encodedHeight, height: encodedWidth)
        }
        return (width: encodedWidth, height: encodedHeight)
    }

    /// Compare two flattened CGAffineTransform components element-wise.
    /// Used to assert "the file's actual transform matches what
    /// OrientationPolicy chose for the captured aspect."
    nonisolated static func transformsAreClose(
        _ a: [Double], _ b: [Double], tolerance: Double = 0.01
    ) -> Bool {
        guard a.count == 4, b.count == 4 else { return false }
        for i in 0..<4 {
            if abs(a[i] - b[i]) > tolerance { return false }
        }
        return true
    }

    /// Predict the playback aspect ratio (W/H) for a given `RecordingAspect`.
    /// Used by the per-aspect assertion to flag "the file's playback aspect
    /// doesn't match the picker." Returns 0.0 for unknown aspects.
    nonisolated static func expectedPlaybackAspectRatio(for aspect: RecordingAspect) -> Double {
        switch aspect {
        case .ratio9x16: return 9.0 / 16.0   // 0.5625 portrait
        case .ratio4x3:  return 3.0 / 4.0    // 0.75 portrait (4:3 rotated to portrait)
        case .ratio16x9: return 9.0 / 16.0   // 0.5625 portrait (16:9 rotated to portrait)
        case .ratio1x1:  return 1.0          // square
        case .openGate:
            // Device-dependent. iPhone 17 1×1 sensor → 1:1 square; older
            // 4:3 sensors → 0.75 portrait. The assertion accepts either by
            // returning 0.0 here (skip the check). Per-device override
            // would live in OrientationPolicy.
            return 0.0
        }
    }
}

extension BrightnessGrid {
    /// All-zero grid sentinel for unanalyzable frames.
    static var zero: BrightnessGrid {
        return BrightnessGrid(topLeft: 0, topRight: 0, bottomLeft: 0, bottomRight: 0, center: 0)
    }
}

#endif
