//
//  VideoMarkerTests.swift
//  OpenPrompterTests
//
//  Unit tests for the V3 headline video-marker feature (H0a manual + H0b
//  script). Coverage:
//
//    - clampMarkerTime pins a time into [sessionStart, lastPTS]
//    - buildChapterSegments: ordering, auto-numbering, span, clamp, invalid
//    - RecordingSession marker queue: tapMark anchors to lastVideoPTS
//      (markerTime − sessionStart == expected offset), drain empties the
//      queue and commits, no-op outside .recording
//    - StrippingRules.markerCue extraction (bare / titled / double-bracket)
//    - MarkdownCleaner strips the [MARK] cue from displayed text AND records
//      it in ParsedScript.markerCues
//    - PrompterViewModel.scriptMarkersCrossingEyeLine fires once per block
//      (dedupe on scroll-back) and honours the take-start seed
//
//  No tests touch a real AVAssetWriter — the RecordingSession marker logic is
//  exercised via `suppressDeviceWork: true` + the DEBUG marker test seams.
//

import XCTest
import AVFoundation
@testable import OpenPrompter

@MainActor
final class VideoMarkerTests: XCTestCase {

    // Standard 600-timescale capture clock (CMTime default for video).
    private let ts: CMTimeScale = 600

    private func t(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: ts)
    }

    private var savedCountdown: Any?

    override func setUp() {
        super.setUp()
        savedCountdown = UserDefaults.standard.object(forKey: PrefKey.recordingCountdown.rawValue)
    }

    override func tearDown() {
        if let value = savedCountdown {
            UserDefaults.standard.set(value, forKey: PrefKey.recordingCountdown.rawValue)
        } else {
            UserDefaults.standard.removeObject(forKey: PrefKey.recordingCountdown.rawValue)
        }
        super.tearDown()
    }

    // MARK: - clampMarkerTime

    func testClampInsideRangeReturnsInput() {
        let clamped = clampMarkerTime(t(5), lower: t(0), upper: t(10))
        XCTAssertEqual(CMTimeGetSeconds(clamped), 5, accuracy: 0.001)
    }

    func testClampBelowLowerReturnsLower() {
        let clamped = clampMarkerTime(t(-3), lower: t(1), upper: t(10))
        XCTAssertEqual(CMTimeGetSeconds(clamped), 1, accuracy: 0.001)
    }

    func testClampAboveUpperReturnsUpper() {
        let clamped = clampMarkerTime(t(99), lower: t(0), upper: t(10))
        XCTAssertEqual(CMTimeGetSeconds(clamped), 10, accuracy: 0.001)
    }

    func testClampDegenerateWindowReturnsLower() {
        // upper < lower — a marker at the session start is always valid.
        let clamped = clampMarkerTime(t(5), lower: t(10), upper: t(2))
        XCTAssertEqual(CMTimeGetSeconds(clamped), 10, accuracy: 0.001)
    }

    // MARK: - buildChapterSegments

    func testChapterSegmentsSortAndSpanToNextMarker() {
        let markers = [
            RecordingMarker(time: t(6), title: "Third"),
            RecordingMarker(time: t(2), title: "First"),
            RecordingMarker(time: t(4), title: "Second")
        ]
        let segs = buildChapterSegments(from: markers, sessionStart: t(0), lastPTS: t(10))
        XCTAssertEqual(segs.map(\.title), ["First", "Second", "Third"])
        // Each spans [marker_i, marker_{i+1}); last runs to lastPTS.
        XCTAssertEqual(CMTimeGetSeconds(segs[0].start), 2, accuracy: 0.001)
        XCTAssertEqual(CMTimeGetSeconds(segs[0].end), 4, accuracy: 0.001)
        XCTAssertEqual(CMTimeGetSeconds(segs[1].end), 6, accuracy: 0.001)
        XCTAssertEqual(CMTimeGetSeconds(segs[2].end), 10, accuracy: 0.001) // to lastPTS
    }

    func testChapterSegmentsAutoNumberUntitledManualMarkers() {
        let markers = [
            RecordingMarker(time: t(1), title: nil),
            RecordingMarker(time: t(3), title: "Named"),
            RecordingMarker(time: t(5), title: nil)
        ]
        let segs = buildChapterSegments(from: markers, sessionStart: t(0), lastPTS: t(8))
        // Manual (untitled) markers become "Marker 1", "Marker 2" in time order;
        // the titled one keeps its name.
        XCTAssertEqual(segs.map(\.title), ["Marker 1", "Named", "Marker 2"])
    }

    func testChapterSegmentsClampOutOfRangeTimes() {
        let markers = [
            RecordingMarker(time: t(-5), title: "Before start"),
            RecordingMarker(time: t(50), title: "After end")
        ]
        let segs = buildChapterSegments(from: markers, sessionStart: t(2), lastPTS: t(10))
        for seg in segs {
            XCTAssertGreaterThanOrEqual(CMTimeGetSeconds(seg.start), 2)
            XCTAssertLessThanOrEqual(CMTimeGetSeconds(seg.end), 10)
            XCTAssertGreaterThanOrEqual(CMTimeGetSeconds(seg.end), CMTimeGetSeconds(seg.start))
        }
    }

    func testChapterSegmentsInvalidTimeCollapsesToSessionStart() {
        let markers = [RecordingMarker(time: .invalid, title: "Warmup mark")]
        let segs = buildChapterSegments(from: markers, sessionStart: t(3), lastPTS: t(9))
        XCTAssertEqual(segs.count, 1)
        XCTAssertEqual(CMTimeGetSeconds(segs[0].start), 3, accuracy: 0.001)
    }

    func testChapterSegmentsEmptyWhenNoMarkers() {
        XCTAssertTrue(buildChapterSegments(from: [], sessionStart: t(0), lastPTS: t(10)).isEmpty)
    }

    func testChapterSegmentsEmptyWhenDegenerateClock() {
        let markers = [RecordingMarker(time: t(1), title: "x")]
        XCTAssertTrue(buildChapterSegments(from: markers, sessionStart: t(10), lastPTS: t(2)).isEmpty)
    }

    // MARK: - RecordingSession marker queue (via DEBUG seams)

    private func makeRecordingSession() -> RecordingSession {
        let state = RecordingState()
        return RecordingSession(state: state, cameraStore: nil, suppressDeviceWork: true)
    }

    func testTapMarkOutsideRecordingIsNoOp() {
        let session = makeRecordingSession()
        // Phase is .idle by default.
        session.tapMark()
        XCTAssertEqual(session._testPendingMarkerCount, 0)
    }

    func testTapMarkAnchorsToLastVideoPTSGivingCorrectOffset() async {
        let session = makeRecordingSession()
        // Enter recording (countdown off).
        Prefs.recordingCountdown = "off"
        await session.tapREC()
        // Simulate the writer clock: session started at 2s, latest frame at 7s.
        session._testSeedWriterClock(sessionStart: t(2), lastVideoPTS: t(7))

        session.tapMark()
        XCTAssertEqual(session._testPendingMarkerCount, 1)

        session._testDrainPendingMarkers()
        // markerTime = tap frame (lastVideoPTS = 7s); file offset = 7 − 2 = 5s.
        let committed = session._testCommittedMarkers
        XCTAssertEqual(committed.count, 1)
        XCTAssertEqual(committed[0].offset, 5, accuracy: 0.01)
        XCTAssertNil(committed[0].title) // manual → untitled until finalize
    }

    func testDrainEmptiesPendingQueue() async {
        let session = makeRecordingSession()
        Prefs.recordingCountdown = "off"
        await session.tapREC()
        session._testSeedWriterClock(sessionStart: t(0), lastVideoPTS: t(10))

        session.tapMark()
        session.appendChapter(title: "Section", at: .zero)
        XCTAssertEqual(session._testPendingMarkerCount, 2)

        session._testDrainPendingMarkers()
        XCTAssertEqual(session._testPendingMarkerCount, 0, "drain empties the pending queue")
        XCTAssertEqual(session._testCommittedMarkers.count, 2)
        // Script marker keeps its title; manual marker stays nil.
        let titles = session._testCommittedMarkers.map(\.title)
        XCTAssertTrue(titles.contains("Section"))
        XCTAssertTrue(titles.contains(nil))
    }

    func testMarkerTimeClampedToLastPTS() async {
        let session = makeRecordingSession()
        Prefs.recordingCountdown = "off"
        await session.tapREC()
        // Session start 0, last frame 4s. A marker anchored to lastVideoPTS
        // can never exceed lastPTS, so the committed offset is ≤ 4.
        session._testSeedWriterClock(sessionStart: t(0), lastVideoPTS: t(4))
        session.tapMark()
        session._testDrainPendingMarkers()
        let committed = session._testCommittedMarkers
        XCTAssertEqual(committed.count, 1)
        XCTAssertLessThanOrEqual(committed[0].offset, 4.0001)
        XCTAssertGreaterThanOrEqual(committed[0].offset, 0)
    }

    // MARK: - StrippingRules.markerCue extraction

    func testMarkerCueBareBrackets() {
        // .some(nil) — a marker with no title.
        if let cue = StrippingRules.markerCue(in: "read this [MARK] then continue") {
            XCTAssertNil(cue)
        } else {
            XCTFail("expected a bare marker cue")
        }
    }

    func testMarkerCueWithTitle() {
        let cue = StrippingRules.markerCue(in: "here [MARK: The Intro] we go")
        XCTAssertEqual(cue ?? nil, "The Intro")
    }

    func testMarkerCueDoubleBracket() {
        if let cue = StrippingRules.markerCue(in: "[[mark]]") {
            XCTAssertNil(cue)
        } else {
            XCTFail("expected double-bracket marker cue")
        }
    }

    func testMarkerCueDoubleBracketWithTitle() {
        let cue = StrippingRules.markerCue(in: "[[mark: Chapter Two]]")
        XCTAssertEqual(cue ?? nil, "Chapter Two")
    }

    func testMarkerCueCaseInsensitive() {
        XCTAssertNotNil(StrippingRules.markerCue(in: "[mark]"))
        XCTAssertNotNil(StrippingRules.markerCue(in: "[Mark: x]"))
    }

    func testNoMarkerCueReturnsNil() {
        XCTAssertNil(StrippingRules.markerCue(in: "an ordinary line with [a bracket]"))
        XCTAssertNil(StrippingRules.markerCue(in: "plain text"))
    }

    func testMarkerCueTolerantOfEscapedBrackets() {
        // Markup.format() may serialize the leading bracket as \[.
        XCTAssertNotNil(StrippingRules.markerCue(in: #"line \[MARK: Escaped\] end"#))
    }

    // MARK: - MarkdownCleaner strips cue from display AND extracts it

    func testCleanerStripsMarkCueFromParagraphButKeepsText() {
        let parsed = MarkdownCleaner.clean(
            text: "Welcome back [MARK: Opening] to the show",
            rules: .aggressive
        )
        // Cue is hidden from the reader…
        XCTAssertFalse(parsed.bodyText.contains("MARK"))
        XCTAssertFalse(parsed.bodyText.contains("["))
        XCTAssertTrue(parsed.bodyText.contains("Welcome back"))
        XCTAssertTrue(parsed.bodyText.contains("to the show"))
        // …but recorded as a script marker on block 0 with its title.
        XCTAssertEqual(parsed.markerCues[0] ?? nil, "Opening")
    }

    func testCleanerStripsDoubleBracketMarkAndKeepsSurroundingText() {
        let parsed = MarkdownCleaner.clean(
            text: "First line here [[mark]] still going",
            rules: .aggressive
        )
        XCTAssertFalse(parsed.bodyText.lowercased().contains("mark"))
        XCTAssertTrue(parsed.bodyText.contains("First line here"))
        XCTAssertTrue(parsed.bodyText.contains("still going"))
        // Present key, bare cue → value is Optional(nil).
        XCTAssertNotNil(parsed.markerCues.index(forKey: 0))
        XCTAssertNil(parsed.markerCues[0] ?? nil)
    }

    func testCleanerStripsMarkCueInGentleMode() {
        // Marker cue is control metadata — hidden even in gentle mode.
        let parsed = MarkdownCleaner.clean(
            text: "Some content [MARK] more content",
            rules: .gentle
        )
        XCTAssertFalse(parsed.bodyText.contains("MARK"))
        XCTAssertNotNil(parsed.markerCues.index(forKey: 0))
    }

    func testCleanerRecordsCueOnCorrectBlockIndex() {
        let parsed = MarkdownCleaner.clean(
            text: """
            First paragraph with no cue.

            Second paragraph [MARK: Two] here.

            Third paragraph plain.
            """,
            rules: .aggressive
        )
        XCTAssertEqual(parsed.blocks.count, 3)
        XCTAssertNil(parsed.markerCues[0] ?? nil, "block 0 has no cue")
        XCTAssertNil(parsed.markerCues.index(forKey: 0))
        XCTAssertEqual(parsed.markerCues[1] ?? nil, "Two")
    }

    // MARK: - PrompterViewModel script-marker crossing + dedupe

    private func makeViewModel() -> PrompterViewModel {
        let url = URL(fileURLWithPath: "/tmp/op-marker-\(UUID().uuidString).md")
        let file = ScriptFile(id: url, name: url.lastPathComponent, mtime: .now, downloadState: .current)
        let vm = PrompterViewModel(file: file)
        vm.viewportHeight = 500
        vm.contentHeight = 3000
        return vm
    }

    /// Build a VM with three blocks (heading at index 1) and measured frames.
    private func markerFixtureVM() -> PrompterViewModel {
        let vm = makeViewModel()
        vm.parsed = ParsedScript(
            blocks: [
                .paragraph(StyledText(plain: "intro line")),
                .heading(level: 1, text: "Section Two"),
                .paragraph(StyledText(plain: "body line"))
            ],
            markerCues: [:]
        )
        // Block minY positions in content coordinates.
        vm.blockFrames = [
            0: BlockFrame(minY: 250, height: 100),
            1: BlockFrame(minY: 1000, height: 120),
            2: BlockFrame(minY: 1200, height: 100)
        ]
        return vm
    }

    func testScriptMarkerFiresWhenHeadingCrossesEyeLine() {
        let vm = markerFixtureVM()
        // Seed dedupe at offset 0 → eyeLine = 250. Block 0 (minY 250) is at the
        // line already (seeded); block 1 (minY 1000) is below.
        vm.resetScriptMarkerDedupe()
        XCTAssertTrue(vm.scriptMarkersCrossingEyeLine().isEmpty)

        // Scroll so the heading (minY 1000) reaches the eye-line:
        // eyeLine = offset + 250 → need offset ≥ 750.
        vm.scroller.seek(to: 800, maxOffset: vm.maxScrollOffset)
        let crossings = vm.scriptMarkersCrossingEyeLine()
        XCTAssertEqual(crossings.count, 1)
        XCTAssertEqual(crossings[0].index, 1)
        XCTAssertEqual(crossings[0].title, "Section Two")
    }

    func testScriptMarkerFiresOncePerBlockOnScrollBack() {
        let vm = markerFixtureVM()
        vm.resetScriptMarkerDedupe()
        vm.scroller.seek(to: 800, maxOffset: vm.maxScrollOffset)
        XCTAssertEqual(vm.scriptMarkersCrossingEyeLine().count, 1) // heading fires

        // Immediately re-checking without moving does not re-fire.
        XCTAssertTrue(vm.scriptMarkersCrossingEyeLine().isEmpty)

        // Scroll back up above the heading, then forward again — still no
        // re-fire (dedupe holds for the whole take).
        vm.scroller.seek(to: 0, maxOffset: vm.maxScrollOffset)
        XCTAssertTrue(vm.scriptMarkersCrossingEyeLine().isEmpty)
        vm.scroller.seek(to: 900, maxOffset: vm.maxScrollOffset)
        XCTAssertTrue(vm.scriptMarkersCrossingEyeLine().isEmpty, "block already marked this take")
    }

    func testScriptMarkerResetSeedsAlreadyPassedHeadings() {
        let vm = markerFixtureVM()
        // Start the take with the heading ALREADY above the eye-line
        // (offset 900 → eyeLine 1150 > heading minY 1000). It must NOT
        // retroactively fire.
        vm.scroller.seek(to: 900, maxOffset: vm.maxScrollOffset)
        vm.resetScriptMarkerDedupe()
        XCTAssertTrue(
            vm.scriptMarkersCrossingEyeLine().isEmpty,
            "a heading already scrolled past at take start must not mark"
        )
    }

    func testScriptMarkerUsesMarkCueBlocks() {
        let vm = makeViewModel()
        vm.parsed = ParsedScript(
            blocks: [
                .paragraph(StyledText(plain: "intro")),
                .paragraph(StyledText(plain: "cue block body"))
            ],
            markerCues: [1: "Custom Cue"]
        )
        vm.blockFrames = [
            0: BlockFrame(minY: 250, height: 100),
            1: BlockFrame(minY: 1000, height: 100)
        ]
        vm.resetScriptMarkerDedupe()
        vm.scroller.seek(to: 800, maxOffset: vm.maxScrollOffset) // eyeLine 1050
        let crossings = vm.scriptMarkersCrossingEyeLine()
        XCTAssertEqual(crossings.count, 1)
        XCTAssertEqual(crossings[0].index, 1)
        XCTAssertEqual(crossings[0].title, "Custom Cue")
    }

    func testBareMarkCueTitlesToBlockText() {
        let vm = makeViewModel()
        vm.parsed = ParsedScript(
            blocks: [
                .paragraph(StyledText(plain: "intro")),
                .paragraph(StyledText(plain: "spoken line for a bare mark"))
            ],
            markerCues: [1: nil]   // present cue (key present), no title
        )
        vm.blockFrames = [
            0: BlockFrame(minY: 250, height: 100),
            1: BlockFrame(minY: 1000, height: 100)
        ]
        vm.resetScriptMarkerDedupe()
        vm.scroller.seek(to: 800, maxOffset: vm.maxScrollOffset)
        let crossings = vm.scriptMarkersCrossingEyeLine()
        XCTAssertEqual(crossings.count, 1)
        // Bare cue → titled by the block's spoken text.
        XCTAssertEqual(crossings[0].title, "spoken line for a bare mark")
    }

    // MARK: - RemoteEvent

    func testDropMarkerEventRoutesToOnDropMarker() {
        let vm = makeViewModel()
        var fired = false
        vm.onDropMarker = { fired = true }
        vm.handleRemoteEvent(.dropMarker)
        XCTAssertTrue(fired)
    }

    func testDropMarkerIsInAllCases() {
        XCTAssertTrue(RemoteEvent.allCases.contains(.dropMarker))
        XCTAssertEqual(RemoteEvent.dropMarker.displayName, "Drop marker")
    }
}
