//
//  RecordingSelfTest.swift
//  OpenPrompter
//
//  DEBUG-only diagnostic harness for the recording pipeline. Reads back
//  the most recent .mov in `Documents/Recordings/`, decodes it via
//  `AVAsset`, samples a handful of frames for brightness, and writes a
//  JSON report next to the recording so the orchestrator can pull it
//  via `xcrun devicectl device copy from`. The on-screen alert shows a
//  pass/fail summary; the JSON has the full numeric detail.
//
//  Why this exists: most recording bugs (black first frame, wrong
//  bitrate, stretched aspect, dropped framerate) only manifest on real
//  hardware. The simulator can't fake a camera. This harness gives the
//  orchestrator a fast feedback loop without asking the user to read
//  off Photos metadata manually.
//
//  Surfaced via the "Run Recording Self-Test" button in
//  `Settings → Labs` (DEBUG only). Workflow:
//    1. User records a normal take in the prompter (any duration ≥ 2 s).
//    2. User opens Settings, scrolls to Labs, taps "Run Recording Self-Test".
//    3. The harness reads the most-recent .mov, runs assertions, shows
//       an alert AND writes `Documents/SelfTest.json`.
//    4. Orchestrator pulls the JSON via:
//         xcrun devicectl device copy from --device <UDID> \
//           --user mobile --domain temporary \
//           --source SelfTest.json --destination /tmp/selftest.json
//

import AVFoundation
import CoreGraphics
import Foundation
import UIKit

#if DEBUG

/// Result of a single self-test run. Codable so we can write it to
/// `Documents/SelfTest.json` and read it via devicectl on the orchestrator
/// side. Fields are flat (no nesting beyond the assertions array) so a
/// quick `cat selftest.json` is human-readable.
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

    /// Nominal frame rate decoded by AVFoundation. Will be 24/30/60 (or
    /// close — encoder VFR can land slightly off).
    let nominalFrameRate: Float

    /// Codec FourCC ("hvc1" for HEVC, "avc1" for H.264).
    let codecFourCC: String

    /// File-size-derived bitrate (bps). The actual encoder target lives
    /// in the writer settings; this is what the encoder produced.
    let computedBitrateBps: Int64

    /// Average luminance (0.0-1.0) of a center patch sampled at
    /// specific timestamps. Used to verify the warmup-frame drop:
    /// `firstFrameBrightness` should be > 0.05 (not pitch black) for a
    /// normal take. `secondFrameBrightness` is the sanity check.
    let firstFrameBrightness: Double
    let frameAt100msBrightness: Double
    let frameAt500msBrightness: Double
    let midpointFrameBrightness: Double

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

        let firstFrame = brightness(at: .zero, generator: generator)
        let frame100ms = brightness(at: CMTime(value: 100, timescale: 1000), generator: generator)
        let frame500ms = brightness(at: CMTime(value: 500, timescale: 1000), generator: generator)
        let midpoint: CMTime = duration.seconds.isFinite && duration.seconds > 0
            ? CMTime(seconds: duration.seconds / 2, preferredTimescale: 600)
            : .zero
        let frameMid = brightness(at: midpoint, generator: generator)

        let computedBitrateBps: Int64 = durationSeconds > 0
            ? Int64(Double(fileSize) * 8 / durationSeconds)
            : 0

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
            name: "encoded portrait (height > width OR rotation transform)",
            passed: videoHeight > videoWidth || isPortraitTransform(preferredTransform),
            detail: "dims = \(videoWidth)×\(videoHeight), transform = \(preferredTransform)"
        ))
        assertions.append(.init(
            name: "first frame is not black (brightness > 0.05)",
            passed: firstFrame > 0.05,
            detail: String(format: "first = %.3f, 100ms = %.3f, 500ms = %.3f, mid = %.3f",
                           firstFrame, frame100ms, frame500ms, frameMid)
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
            nominalFrameRate: nominalFrameRate,
            codecFourCC: codecFourCC,
            computedBitrateBps: computedBitrateBps,
            firstFrameBrightness: firstFrame,
            frameAt100msBrightness: frame100ms,
            frameAt500msBrightness: frame500ms,
            midpointFrameBrightness: frameMid,
            assertions: assertions
        )
    }

    /// Persist the result as JSON next to the recording AND at the
    /// well-known `Documents/SelfTest.json` location so devicectl's
    /// `--source SelfTest.json` pull works without knowing the recording
    /// stem. Returns the canonical destination URL on success.
    static func writeReport(_ result: SelfTestResult) -> URL? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(result) else { return nil }

        guard let docs = try? FileManager.default.url(
            for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: false
        ) else { return nil }

        let canonical = docs.appendingPathComponent("SelfTest.json")
        try? data.write(to: canonical, options: .atomic)
        return canonical
    }

    // MARK: - Internals

    private static func mostRecentRecordingURL() -> URL? {
        guard let docs = try? FileManager.default.url(
            for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: false
        ) else { return nil }

        // First-choice path: the DEBUG-only canonical copy that
        // RecordingSession stashes BEFORE Photos save deletes the original.
        // We can't scan Documents/Recordings/ for the real file because
        // production deletes it post-save to avoid spurious recovery
        // banners on next launch.
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
        return averageLuminance(of: cgImage)
    }

    private static func averageLuminance(of image: CGImage) -> Double {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return 0.0 }

        // Render the center 60×60 region into an 8-bit grayscale buffer.
        let patchSize = 60
        let patchX = max(0, width / 2 - patchSize / 2)
        let patchY = max(0, height / 2 - patchSize / 2)
        let actualW = min(patchSize, width - patchX)
        let actualH = min(patchSize, height - patchY)
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

        // Draw the source image into the context such that the center
        // patch lands inside the (0,0)–(actualW,actualH) rect. We do this
        // by translating the source so the patch origin lines up.
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

    private static func isPortraitTransform(_ t: [Double]) -> Bool {
        // Portrait-rotated 90° transform: a=0, b=1, c=-1, d=0
        // (or 270°: a=0, b=-1, c=1, d=0). Identity is a=1, d=1.
        guard t.count == 4 else { return false }
        return abs(t[0]) < 0.01 && abs(t[3]) < 0.01 &&
               (abs(t[1] - 1) < 0.01 || abs(t[1] + 1) < 0.01) &&
               (abs(t[2] - 1) < 0.01 || abs(t[2] + 1) < 0.01)
    }
}

#endif
