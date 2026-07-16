//
//  RecordingMarker.swift
//  OpenPrompter
//
//  Video-marker model (V3 headline "Video Markers", H0a manual + H0b script).
//  A marker is a labelled point in the recorded `.mov` timeline. Two kinds of
//  markers converge on this one model:
//
//  - MANUAL (H0a): the user taps the "mark" chip near the camera toggle; the
//    tap captures the most recently appended video PTS as the marker time and
//    leaves the title `nil` (auto-numbered "Marker 1", "Marker 2", … at
//    finalize).
//  - SCRIPT (H0b): a heading or a `[MARK]` / `[MARK: title]` / `[[mark]]` cue
//    crosses the reading eye-line during a take; the crossing captures the
//    current video PTS and carries the heading text (or the cue's title) as
//    the marker title.
//
//  Both kinds flow through the SAME writer half (`RecordingSession`):
//    1. A MainActor caller appends a `RecordingMarker` into
//       `WriterState.pendingMarkers` under `writerStateLock` (no `await` held).
//    2. The `recordingQueue` sample-buffer handler drains `pendingMarkers`
//       after each appended video frame — copying the pending array out under
//       the lock, releasing the lock, then appending each into the timed-
//       metadata adaptor and accumulating it for the chapter track.
//
//  Marker times are stored as ABSOLUTE capture-clock `CMTime` PTS values (the
//  same clock the writer's `startSession(atSourceTime:)` anchor and every
//  appended sample buffer use). The offset written into the file is
//  `markerPTS − sessionStartTime`. Every marker time is clamped to
//  `[sessionStart, lastVideoPTS]` before it reaches the adaptor — an
//  out-of-range time makes `AVAssetWriter.finishWriting` fail.
//
//  Threading: `RecordingMarker` is a `Sendable` value type so it crosses the
//  MainActor → recordingQueue boundary inside `WriterState` without any
//  unsafe escape hatch.
//

import AVFoundation
import Foundation

/// One labelled point in a recording's timeline. `time` is an absolute
/// capture-clock PTS (see file header); `title` is `nil` for auto-numbered
/// manual marks and non-nil for script markers.
struct RecordingMarker: Sendable, Equatable {
    /// Absolute capture-clock presentation timestamp of the marker. The
    /// file-relative offset is `time − sessionStartTime`, computed at drain
    /// time once the session-start anchor is known.
    var time: CMTime
    /// Human-readable title. `nil` → auto-numbered at finalize
    /// ("Marker 1", "Marker 2", …). Script markers carry the heading text or
    /// the `[MARK: title]` cue title.
    var title: String?

    init(time: CMTime, title: String? = nil) {
        self.time = time
        self.title = title
    }
}

/// Clamps `t` into the inclusive range `[lower, upper]` in the SAME timescale
/// as the endpoints. Used before a marker time reaches the timed-metadata
/// adaptor or the chapter track — `AVAssetWriter.finishWriting` fails outright
/// if any metadata group's time range falls outside the media's time range,
/// so we pin every marker to `[sessionStart, lastVideoPTS]`.
///
/// If the endpoints are out of order (`upper < lower`, which shouldn't happen
/// in practice), `lower` wins — a marker at the session start is always valid.
func clampMarkerTime(_ t: CMTime, lower: CMTime, upper: CMTime) -> CMTime {
    guard upper >= lower else { return lower }
    if t < lower { return lower }
    if t > upper { return upper }
    return t
}

/// Non-empty value for a marker's LIVE timed-metadata sample.
///
/// ROOT CAUSE of the manual-mark save-hang: `AVAssetWriter`'s boxed-UTF-8
/// timed-metadata sample rejects an EMPTY value. A manual mark stores
/// `title == nil`, and the drain used to write `(title ?? "")` — i.e. `""` —
/// which flipped the writer to `.failed`. That failure surfaced on the next
/// frame as the "mark reported an error" AND left `finishWriting()` running
/// on a dead writer whose completion handler never fires (the chip stuck on
/// "saving" for minutes). Every appended metadata sample must carry a
/// non-empty value, so an untitled marker gets a stable placeholder here.
///
/// This does NOT change the stored `RecordingMarker.title` (kept `nil` for
/// manual marks so the chapter track still auto-numbers them "Marker N" at
/// finalize) — only the value written into the live metadata sample.
func markerMetadataLabel(title: String?) -> String {
    if let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return title
    }
    return "Marker"
}

/// One finalized QuickTime chapter: a titled segment `[start, end)` in the
/// capture clock, ready to become an `AVTimedMetadataGroup`. Pure value type
/// so the segment-building logic is unit-testable without a live writer.
struct ChapterSegment: Sendable, Equatable {
    var title: String
    var start: CMTime
    var end: CMTime
}

/// Build contiguous, non-overlapping chapter segments from an unordered marker
/// list, for the QuickTime chapter track written at `finishWriting`. Rules:
///
/// - Markers are sorted by time.
/// - Each chapter spans `[marker_i, marker_{i+1})`; the last runs to `lastPTS`.
/// - Every time is clamped into `[sessionStart, lastPTS]` (an out-of-range
///   chapter sample fails `finishWriting`); invalid marker times (queued
///   during warmup before an anchor existed) collapse to `sessionStart`.
/// - Untitled (manual) markers are auto-numbered "Marker 1", "Marker 2", …
///   in time order; titled (script) markers keep their title.
///
/// Returns an empty array when there are no markers or the clock window is
/// degenerate (`lastPTS < sessionStart`).
func buildChapterSegments(
    from markers: [RecordingMarker],
    sessionStart: CMTime,
    lastPTS: CMTime
) -> [ChapterSegment] {
    guard !markers.isEmpty, lastPTS >= sessionStart else { return [] }
    let sorted = markers
        .map { RecordingMarker(time: $0.time.isValid ? $0.time : sessionStart, title: $0.title) }
        .sorted { $0.time < $1.time }
    var segments: [ChapterSegment] = []
    var manualCount = 0
    for (i, marker) in sorted.enumerated() {
        let start = clampMarkerTime(marker.time, lower: sessionStart, upper: lastPTS)
        let rawEnd = (i + 1 < sorted.count) ? sorted[i + 1].time : lastPTS
        let end = clampMarkerTime(rawEnd, lower: start, upper: lastPTS)
        let title: String
        if let t = marker.title, !t.isEmpty {
            title = t
        } else {
            manualCount += 1
            title = "Marker \(manualCount)"
        }
        segments.append(ChapterSegment(title: title, start: start, end: max(end, start)))
    }
    return segments
}

/// Ordered, named marker POINTS for the Premiere XMP Dynamic Media track
/// (`XMPMarkerWriter`). Uses the SAME sort + auto-numbering rules as
/// `buildChapterSegments`, so the XMP markers and the QuickTime chapter track
/// agree name-for-name and time-for-time:
///
/// - Markers sorted by time; invalid (warmup-queued) times collapse to
///   `sessionStart`.
/// - Each marker's `offsetSeconds` is `clamp(time) − sessionStart` (≥ 0), the
///   file-relative instant the mark was tapped / a block crossed.
/// - Untitled (manual) markers are auto-numbered "Marker 1", "Marker 2", … in
///   time order; titled (script) markers keep their title.
///
/// Returns an empty array when there are no markers or the clock window is
/// degenerate. Pure value-in / value-out — unit-testable without a live writer.
func orderedMarkerPoints(
    from markers: [RecordingMarker],
    sessionStart: CMTime,
    lastPTS: CMTime
) -> [XMPMarkerWriter.MarkerPoint] {
    guard !markers.isEmpty, lastPTS >= sessionStart else { return [] }
    let sorted = markers
        .map { RecordingMarker(time: $0.time.isValid ? $0.time : sessionStart, title: $0.title) }
        .sorted { $0.time < $1.time }
    var points: [XMPMarkerWriter.MarkerPoint] = []
    var manualCount = 0
    for marker in sorted {
        let clamped = clampMarkerTime(marker.time, lower: sessionStart, upper: lastPTS)
        let offset = max(0, CMTimeGetSeconds(clamped - sessionStart))
        let name: String
        if let title = marker.title, !title.isEmpty {
            name = title
        } else {
            manualCount += 1
            name = "Marker \(manualCount)"
        }
        points.append(XMPMarkerWriter.MarkerPoint(offsetSeconds: offset, name: name))
    }
    return points
}

// MARK: - QuickTime chapter TEXT track

/// Builds the pieces of a QuickTime chapter track backed by a **text** track.
///
/// ROOT CAUSE of the empty chapter titles: the pipeline used to associate a
/// `.metadata` (`mebx`) input to the video track as `.chapterList`. QuickTime
/// players and ffmpeg read chapter titles ONLY from the sample data of a
/// `.text` track referenced via a `chap` track reference — a `mebx` track
/// referenced as a chapter list yields the `TAG:title=` (empty) that the
/// founder saw. The fix is to make the chapter track a real `.text` track whose
/// samples carry the titles as QuickTime text (`[uint16 length][UTF-8][encd]`).
enum ChapterTextTrack {

    /// Create the `.text` sample format description required as the
    /// `sourceFormatHint` of the chapter `AVAssetWriterInput`. Returns nil if
    /// CoreMedia rejects the description (the known `-12717` failure) — the
    /// caller then simply omits the chapter track (no crash, no regression to
    /// the video/audio/marker tracks).
    ///
    /// The 60-byte big-endian `TextDescription` is the canonical QuickTime text
    /// sample description (size, 'text', reserved[6], dataRefIndex, displayFlags,
    /// textJustification, bgColor, defaultTextBox, reserved, font/face, fgColor,
    /// empty text name).
    static func makeTextFormatDescription() -> CMFormatDescription? {
        let textDescription: [UInt8] = [
            0x00, 0x00, 0x00, 0x3C,             // size = 60
            0x74, 0x65, 0x78, 0x74,             // 'text'
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // reserved[6]
            0x00, 0x01,                         // data reference index
            0x00, 0x00, 0x00, 0x01,             // display flags
            0x00, 0x00, 0x00, 0x01,             // text justification
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // background color (RGB)
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // default text box
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // reserved
            0x00, 0x00,                         // font number
            0x00, 0x00,                         // font face
            0x00,                               // reserved
            0x00, 0x00,                         // reserved
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // foreground color (RGB)
            0x00                                // text name length (0)
        ]
        var format: CMFormatDescription?
        let status = textDescription.withUnsafeBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return -1 }
            return CMTextFormatDescriptionCreateFromBigEndianTextDescriptionData(
                allocator: kCFAllocatorDefault,
                bigEndianTextDescriptionData: base.assumingMemoryBound(to: UInt8.self),
                size: textDescription.count,
                flavor: nil,
                mediaType: kCMMediaType_Text,
                formatDescriptionOut: &format
            )
        }
        guard status == noErr else { return nil }
        return format
    }

    /// QuickTime text-sample payload for one chapter title:
    /// `[uint16 big-endian text length][UTF-8 text][encd atom]`. The trailing
    /// `encd` (Text Encoding Modifier) atom marks the payload UTF-8 so non-ASCII
    /// script headings aren't mis-decoded as MacRoman. The 2-byte length counts
    /// only the text bytes (readers stop there); the `encd` atom trails it.
    /// Exposed for unit testing the byte layout without a live writer.
    static func textSamplePayload(for title: String) -> Data {
        let utf8 = Data(title.utf8)
        let textLen = min(utf8.count, Int(UInt16.max))
        var payload = Data()
        var lengthBE = UInt16(textLen).bigEndian
        withUnsafeBytes(of: &lengthBE) { payload.append(contentsOf: $0) }
        payload.append(utf8.prefix(textLen))
        // 'encd' atom: [size:4 = 12]['encd']['08 00 01 00' = UTF-8]
        payload.append(contentsOf: [0x00, 0x00, 0x00, 0x0C])
        payload.append(contentsOf: [0x65, 0x6E, 0x63, 0x64])
        payload.append(contentsOf: [0x08, 0x00, 0x01, 0x00])
        return payload
    }

    /// Wrap a chapter title into a ready `CMSampleBuffer` spanning `timeRange`,
    /// for appending to the `.text` chapter input at finalize. Returns nil on
    /// any CoreMedia failure (caller skips that chapter — never fails the take).
    static func makeTextSampleBuffer(
        title: String,
        format: CMFormatDescription,
        timeRange: CMTimeRange
    ) -> CMSampleBuffer? {
        let payload = textSamplePayload(for: title)
        let length = payload.count

        var blockBuffer: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: length,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: length,
            flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &blockBuffer
        ) == kCMBlockBufferNoErr, let block = blockBuffer else { return nil }

        let copyStatus = payload.withUnsafeBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return -1 }
            return CMBlockBufferReplaceDataBytes(
                with: base,
                blockBuffer: block,
                offsetIntoDestination: 0,
                dataLength: length
            )
        }
        guard copyStatus == kCMBlockBufferNoErr else { return nil }

        var sampleBuffer: CMSampleBuffer?
        var timing = CMSampleTimingInfo(
            duration: timeRange.duration,
            presentationTimeStamp: timeRange.start,
            decodeTimeStamp: .invalid
        )
        var sampleSize = length
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            formatDescription: format,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        ) == noErr else { return nil }
        return sampleBuffer
    }
}
