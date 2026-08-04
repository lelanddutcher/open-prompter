//
//  PrompterViewModel.swift
//  OpenPrompter
//
//  Per-session state for a single open script: play/pause, speed, font,
//  mirror axes, focus mode, parsed content. Owns the AutoScroller and
//  subscribes to the AppState.watcher.changed stream for live reloads.
//

import Foundation
import Observation
import SwiftUI

/// 2.0.6: a rendered block's vertical extent in scroll-content
/// coordinates. `minY` is the block's leading edge (top of the
/// block's frame); `height` is the block's full vertical span. The
/// VStack-arranged blocks use absolute Y values inside the
/// `scriptContent` named coordinate space published by
/// `TeleprompterView`. Voice-tracking math derives a matched word's
/// pixel position as `minY + withinBlockFraction * height`.
struct BlockFrame: Equatable {
    let minY: CGFloat
    let height: CGFloat
}

/// 2.0.6: SwiftUI PreferenceKey that aggregates per-block frames
/// into a `[blockIndex: BlockFrame]` map. Each `blockView` publishes
/// its own single-entry dictionary; the reducer merges them. Read
/// via `.onPreferenceChange(BlockFramesPreferenceKey.self)` on the
/// container that owns the named coordinate space.
struct BlockFramesPreferenceKey: PreferenceKey {
    static var defaultValue: [Int: BlockFrame] = [:]
    static func reduce(value: inout [Int: BlockFrame], nextValue: () -> [Int: BlockFrame]) {
        value.merge(nextValue()) { _, new in new }
    }
}

@Observable
@MainActor
final class PrompterViewModel {
    // MARK: - Identity

    let file: ScriptFile

    // MARK: - Playback state

    var isPlaying: Bool = false
    var speed: Double
    var fontSize: Double
    var mirroredHorizontal: Bool
    var mirroredVertical: Bool
    var focus: Bool

    // MARK: - Content

    var parsed: ParsedScript = .empty
    /// Full raw markdown text from the last successful read, kept so the
    /// editor can open instantly without a second coordinated read and so
    /// the edit-teleport feature can map prompter scroll → source position.
    var rawText: String = ""
    var isLoading: Bool = true
    var loadError: String?

    // MARK: - Sync state

    var reloadAvailable: Bool = false
    /// Timestamp of the most recent successful read. Kept for diagnostics;
    /// the sync chip uses `fileMTime` instead so it reflects when the file
    /// was actually edited on disk rather than when the app last read it.
    var lastSyncedAt: Date?
    /// Modification date of the script file on disk, captured at the end of
    /// each successful read. Drives the "EDITED · Xm AGO" sync chip so the
    /// user sees when the author last saved the file, not when the watcher
    /// last polled. `nil` when the file has no metadata (e.g. a bundled
    /// demo script) — the chip falls back to a "READY" state in that case.
    var fileMTime: Date?

    // MARK: - Auto-scroll

    let scroller = AutoScroller()
    var contentHeight: CGFloat = 0
    var viewportHeight: CGFloat = 0

    /// 2.0.6: per-block rendered geometry, captured from each rendered
    /// `blockView` via `BlockFramePreferenceKey`. Keys are 0-based
    /// block indices matching `parsed.blocks.enumerated().offset`.
    /// Voice-tracking math reads this to compute the matched word's
    /// PIXEL position from real geometry instead of from the linear
    /// char-fraction estimate that systematically undershot for
    /// scripts with mixed font sizes (headings + body).
    var blockFrames: [Int: BlockFrame] = [:]

    /// Voice-tracking scroll target. Set on each successful alignment
    /// match; the per-frame ticker in `TeleprompterView` lerps the
    /// scroller toward this value. `nil` when no match is pending,
    /// which short-circuits the ticker to a no-op. Cleared when voice
    /// tracking stops.
    var voiceTargetOffset: CGFloat?

    /// Wall-clock timestamp of the previous voice-tracking tick. Used
    /// to compute dt for framerate-independent velocity integration in
    /// `AutoScroller.voiceTrackingTick`. `nil` resets on activation.
    var lastVoiceTickAt: Date?

    /// 2.0.10: brief flag set when the user taps the prompter to toggle
    /// play/pause WHILE voice tracking is active. The two scroll
    /// drivers are mutually exclusive, so instead of silently no-oping,
    /// the play/pause button flashes red for ~0.4s as a visual "you
    /// can't do both" indicator. View layer reads this and applies a
    /// short tint animation. Auto-resets after the flash window.
    var playTapConflict: Bool = false

    /// Scroll offset captured at the moment the user pressed play on the
    /// current take. Used by `jumpToStartOfTake()` (Feature 7's novel
    /// `jumpToStart` remote action) to return the scroll position to the
    /// exact spot a take began — useful for retake workflows where you
    /// flubbed the line and want to reset without losing your place.
    ///
    /// Semantics: every transition from `paused → playing` resets this
    /// to the current scroll offset. Pausing in the middle of a take and
    /// resuming creates a NEW start position. Each unbroken playback span
    /// is its own "take." See `Roadmap V2.md` §7.
    private(set) var playStartScrollOffset: CGFloat = 0

    // MARK: - Remote control

    /// Shared bus for remote events. The prompter view starts a Task that
    /// `for await`s this and forwards each event to `handleRemoteEvent(_:)`.
    /// Bus is per-session — sources that activate while the prompter is on
    /// screen publish into this bus, and the consumer task ends when the
    /// prompter view goes away.
    let remoteBus = RemoteEventBus()

    /// Invoked when a `.recordToggle` remote event arrives. Recording lives
    /// on `AppState.recordingSession`, which the VM deliberately doesn't
    /// reference (the VM is per-script state; AppState is app-scoped). The
    /// view sets this to `handleRecordingChipTap` so a remote button bound to
    /// "Start / stop recording" runs the SAME start/cancel/stop dispatch as
    /// the on-screen REC chip and the hardware capture button. `nil` when the
    /// prompter isn't showing the recording chip — the event is then a no-op.
    var onRecordToggle: (() -> Void)?

    /// Invoked when a `.dropMarker` remote event arrives (V3 headline, H0a).
    /// Like `onRecordToggle`, recording lives on `AppState.recordingSession`
    /// which this per-script VM deliberately doesn't reference, so the view
    /// sets this to `RecordingSession.tapMark`. `nil` (or a no-op when nothing
    /// is recording) when the recording chip isn't on screen.
    var onDropMarker: (() -> Void)?

    // MARK: - Init

    init(file: ScriptFile) {
        self.file = file
        self.speed = Prefs.defaultSpeed
        self.fontSize = Prefs.defaultFont
        self.mirroredHorizontal = Prefs.hMirrorDefault
        self.mirroredVertical = Prefs.vMirrorDefault
        self.focus = Prefs.focusDefault
    }

    // MARK: - Loading

    func load() async {
        isLoading = true
        loadError = nil
        // Reset the take-start anchor on every (re)load. A stale offset
        // captured against a previous file's content would point into
        // invalid scroll territory in the new content.
        playStartScrollOffset = 0
        do {
            let text = try await FileCoordinatorReader.readAsync(file.url)
            let rules: StrippingRules = .resolved(
                aggressive: Prefs.aggressiveStripping,
                stripStageDirections: Prefs.stripStageDirections
            )
            let parsedResult = await Task.detached(priority: .userInitiated) {
                MarkdownCleaner.clean(text: text, rules: rules)
            }.value
            self.rawText = text
            self.parsed = parsedResult
            self.lastSyncedAt = .now
            // Capture the on-disk modification date so the top-bar chip can
            // show when the file was last edited (not when we last read it).
            // Bundled resources sometimes lack this key — the chip handles
            // a nil value by falling back to a neutral READY state.
            self.fileMTime = try? file.url
                .resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate
        } catch {
            self.loadError = error.localizedDescription
        }
        self.isLoading = false
    }

    // MARK: - Edit teleport

    /// Index of the prompter block currently under the eye-line (middle of
    /// the viewport). Used to teleport the editor to the matching source
    /// location when the user taps the pencil.
    var currentBlockIndex: Int {
        guard !parsed.blocks.isEmpty, viewportHeight > 0 else { return 0 }
        // scroller.offset is how far the content has travelled up past the
        // top of the ScrollView. The text is centred, so the "reading line"
        // is at viewport.height / 2. Anything consumed plus half-viewport
        // has crossed the reading line.
        let eyeLine = scroller.offset + viewportHeight * 0.5
        // Blocks are laid out with VStack spacing `fontSize * 0.45`; absent
        // a live measurement per block, estimate by block index vs. total
        // content height. Good enough for teleport — the editor then lets
        // the user adjust.
        guard contentHeight > 0 else { return 0 }
        let frac = min(max(eyeLine / contentHeight, 0), 1)
        let idx = Int(frac * Double(parsed.blocks.count))
        return min(max(idx, 0), parsed.blocks.count - 1)
    }

    /// Returns the character offset in `rawText` that best matches the
    /// currently-visible block, so the editor can jump there on open.
    /// Falls back to 0 if we can't find a reasonable anchor.
    func sourceOffsetForCurrentView() -> Int {
        let idx = currentBlockIndex
        guard idx < parsed.blocks.count else { return 0 }
        // Take the first ~40 chars of the target block's text. That substring
        // almost always matches a unique location in the raw markdown, even
        // after the parser has stripped markers / callouts / brackets. Use
        // the longest substring that actually appears in source.
        let target = parsed.blocks[idx].text
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return 0 }

        // Try progressively shorter prefixes (at word boundaries) until we
        // find one the raw text contains. Handles small parser transforms
        // like wikilink-alias resolution by falling back to a shorter stem.
        let maxLen = min(target.count, 60)
        var len = maxLen
        while len >= 12 {
            let probe = String(target.prefix(len))
            if let range = rawText.range(of: probe) {
                return rawText.distance(from: rawText.startIndex, to: range.lowerBound)
            }
            // Step back to the previous word boundary.
            if let space = target.prefix(len - 1).lastIndex(of: " ") {
                len = target.distance(from: target.startIndex, to: space)
            } else {
                break
            }
        }
        return 0
    }

    func reload() async {
        reloadAvailable = false
        await load()
    }

    // MARK: - Script markers (V3 headline, H0b)

    /// Block indices already marked in the CURRENT take. Prevents a heading /
    /// `[MARK]` block from re-firing a marker when the user scrolls back over
    /// it (retake workflow) — each block marks at most once per take. Reset by
    /// `resetScriptMarkerDedupe()` at the start of every recording.
    private var markedBlockIndices: Set<Int> = []

    /// Prime the per-take script-marker dedupe set at the START of a take.
    /// Seeds it with every marker-bearing block ALREADY at/above the eye-line,
    /// so a recording that begins mid-script doesn't retroactively fire a
    /// marker for each heading the presenter already scrolled past — only
    /// blocks that cross the reading line DURING the take mark. Called by the
    /// view when recording begins.
    func resetScriptMarkerDedupe() {
        markedBlockIndices.removeAll(keepingCapacity: true)
        guard !parsed.blocks.isEmpty, viewportHeight > 0 else { return }
        let eyeLine = scroller.offset + viewportHeight * 0.5
        for idx in parsed.blocks.indices {
            let isMarkerBlock = parsed.blocks[idx].isHeading || parsed.markerCues[idx] != nil
            guard isMarkerBlock else { continue }
            // A block whose top is already at/above the eye-line has been
            // read past — seed it so it won't re-fire. Blocks with no measured
            // frame yet are treated as below (they'll mark when they cross).
            if let frame = blockFrames[idx], frame.minY <= eyeLine {
                markedBlockIndices.insert(idx)
            }
        }
    }

    /// Which blocks CURRENTLY have their top edge at or above the reading
    /// eye-line, are marker-bearing (a heading OR a `[MARK]` cue block), and
    /// have not yet been marked this take. Returns them in index order with
    /// the title to write, and records them in the dedupe set so the next
    /// call won't re-report them.
    ///
    /// Uses the REAL per-block geometry (`blockFrames`) rather than the linear
    /// fraction estimate, so it's frame-accurate for BOTH constant-speed and
    /// voice-tracked scroll (which move the offset non-linearly). A block with
    /// no measured frame yet is skipped — it'll be caught on a later tick once
    /// SwiftUI has published its geometry.
    ///
    /// "Crossed" = the block's top (`minY`) has scrolled up to or past the
    /// eye-line (`scroller.offset + viewportHeight * 0.5`). We report a block
    /// the moment its top reaches the reading line — the point the presenter
    /// starts reading it — matching where a manual mark would land.
    func scriptMarkersCrossingEyeLine() -> [(index: Int, title: String)] {
        guard !parsed.blocks.isEmpty, viewportHeight > 0 else { return [] }
        let eyeLine = scroller.offset + viewportHeight * 0.5
        var result: [(index: Int, title: String)] = []
        for (idx, block) in parsed.blocks.enumerated() {
            if markedBlockIndices.contains(idx) { continue }
            // Only headings and explicit [MARK] cue blocks mark.
            let title: String?
            if block.isHeading {
                title = block.text
            } else if let cueTitle = parsed.markerCues[idx] {
                // `markerCues[idx]` is `Optional<Optional<String>>`; a present
                // key (outer optional non-nil) means the block carries a cue.
                // `cueTitle` is the inner `String?` — the cue's title or nil
                // for a bare `[MARK]`. A bare cue titles to the block's text
                // (its spoken line) so an untitled mid-paragraph mark still
                // gets a meaningful chapter name.
                title = cueTitle ?? block.text
            } else {
                continue
            }
            guard let frame = blockFrames[idx] else { continue }  // geometry not measured yet
            if frame.minY <= eyeLine {
                markedBlockIndices.insert(idx)
                let resolved = (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                result.append((index: idx, title: resolved))
            }
        }
        return result
    }

    // MARK: - Playback actions

    func togglePlay() {
        let willStart = !isPlaying
        isPlaying.toggle()
        if !isPlaying {
            scroller.resetTick()
        } else if willStart {
            // Capture the take-start offset on every paused → playing
            // transition. The user may pause and resume mid-script; each
            // resume is a new take and gets its own start position.
            playStartScrollOffset = scroller.offset
        }
        Haptics.tap()
    }

    /// 2.0.10: trigger the play-tap-conflict flash. Set the flag,
    /// schedule a reset 0.4s later. View layer animates the button
    /// tint in response. Soft haptic instead of the regular tap so the
    /// user feels a different texture for "blocked" vs "succeeded."
    func flashPlayTapConflict() {
        playTapConflict = true
        Haptics.alert()
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            self?.playTapConflict = false
        }
    }

    /// Cycles through all four mirror states so a single tap on the in-
    /// prompter mirror chip exposes every combination without forcing the
    /// user into Settings:
    ///     off (─, ─) → H (•, ─) → V (─, •) → both (•, •) → off
    /// "tap once for horizontal, twice for vertical, three times for both,
    /// four to reset." The remote-control `.mirrorToggle` event also routes
    /// here, so a Bluetooth button cycles the same four states.
    func toggleMirror() {
        switch (mirroredHorizontal, mirroredVertical) {
        case (false, false):
            mirroredHorizontal = true
            mirroredVertical = false
        case (true, false):
            mirroredHorizontal = false
            mirroredVertical = true
        case (false, true):
            mirroredHorizontal = true
            mirroredVertical = true
        case (true, true):
            mirroredHorizontal = false
            mirroredVertical = false
        }
        Haptics.tap(.medium)
    }

    /// Direct vertical-only toggle. Kept for Settings (where each axis has
    /// its own switch) and for any future remote binding that wants to
    /// flip just the vertical axis. The in-prompter chip uses
    /// `toggleMirror()` (the four-state cycle) instead.
    func toggleMirrorVertical() {
        mirroredVertical.toggle()
        Haptics.tap(.medium)
    }

    func toggleFocus() {
        focus.toggle()
    }

    func setSpeed(_ value: Double) {
        speed = max(5, min(200, value))
    }

    func setFontSize(_ value: Double) {
        fontSize = max(16, min(160, value))
    }

    func jumpToStart() {
        // Existing on-screen "Jump to start" button — semantically the top of
        // the script, i.e. RESTART. Kept named jumpToStart for backward
        // compatibility with the controls view; the remote event vocabulary
        // disambiguates with `restart` vs `jumpToStartOfTake`.
        scroller.seek(to: 0, maxOffset: maxScrollOffset)
    }

    /// Top of the script. Same effect as `jumpToStart()` but exposed under
    /// a name that matches the remote `RemoteEvent.restart` case for clarity.
    func restart() { jumpToStart() }

    /// Bottom of the script — the counterpart to `restart()`. Seeks to the
    /// maximum scroll offset, which the scroller clamps, so this is safe
    /// before layout has produced a real content height (offset stays 0).
    func jumpToEnd() {
        scroller.seek(to: maxScrollOffset, maxOffset: maxScrollOffset)
    }

    /// Novel Feature 7 action: return scroll to the offset captured when
    /// the user last pressed play. Doesn't pause — keeps playing if the
    /// prompter was already playing, so a "I flubbed that line" retake
    /// workflow is one button press.
    func jumpToStartOfTake() {
        scroller.seek(to: playStartScrollOffset, maxOffset: maxScrollOffset)
    }

    func jumpBackward() {
        scroller.seek(to: scroller.offset - viewportHeight * 0.5, maxOffset: maxScrollOffset)
    }

    func jumpForward() {
        scroller.seek(to: scroller.offset + viewportHeight * 0.5, maxOffset: maxScrollOffset)
    }

    /// One-line step, in pixels. A body line's rendered height is roughly
    /// `fontSize * lineHeightMultiple`; 1.6 matches the prompter's line
    /// spacing well enough for fine positioning without a per-line geometry
    /// pass. This is the small-step counterpart to the half-viewport
    /// `jump*` leaps (audit B3 / R3) and the target of `scrollUp/scrollDown`
    /// from a mouse-class remote (BLE-M5 D-pad → `GCMouse` deltas).
    var lineStep: CGFloat { CGFloat(fontSize) * 1.6 }

    /// Nudge scroll up by one line. Bound to `.lineUp` and reached by
    /// `scrollUp` (pointer / wheel deltas travelling up).
    func lineUp() {
        scroller.seek(to: scroller.offset - lineStep, maxOffset: maxScrollOffset)
    }

    /// Nudge scroll down by one line. Bound to `.lineDown` and reached by
    /// `scrollDown` (pointer / wheel deltas travelling down).
    func lineDown() {
        scroller.seek(to: scroller.offset + lineStep, maxOffset: maxScrollOffset)
    }

    /// Bump the scroll speed by 5 pts/s, clamped to the slider range.
    func speedUp()   { setSpeed(speed + 5) }
    /// Cut the scroll speed by 5 pts/s, clamped to the slider range.
    func speedDown() { setSpeed(speed - 5) }

    /// Move scroll to the next H1/H2 heading below the eye-line. Treats the
    /// fractional layout (block index / count of total height) the same way
    /// `currentBlockIndex` does — good enough for the "navigate by section"
    /// remote action without standing up a full per-block measurement pass.
    ///
    /// Heading-less fallback (audit C4): a script with no headings would make
    /// media Next/Prev silently no-op — a remote button that "does nothing
    /// sometimes" reads as broken. When no heading is found below the current
    /// block, fall back to a half-viewport jump so the button always advances.
    func nextSection() {
        guard !parsed.blocks.isEmpty, contentHeight > 0 else { return }
        let currentIdx = currentBlockIndex
        if let nextIdx = parsed.blocks.indices
            .first(where: { $0 > currentIdx && parsed.blocks[$0].isHeading })
        {
            seekToBlockIndex(nextIdx)
        } else {
            jumpForward()
        }
    }

    /// Mirror of `nextSection()` going up. If we're already at or above the
    /// first heading, snap to the top.
    func prevSection() {
        guard !parsed.blocks.isEmpty, contentHeight > 0 else { return }
        let currentIdx = currentBlockIndex
        if let prevIdx = parsed.blocks.indices
            .reversed()
            .first(where: { $0 < currentIdx && parsed.blocks[$0].isHeading })
        {
            seekToBlockIndex(prevIdx)
        } else {
            scroller.seek(to: 0, maxOffset: maxScrollOffset)
        }
    }

    private func seekToBlockIndex(_ idx: Int) {
        let count = max(parsed.blocks.count, 1)
        let frac = Double(idx) / Double(count)
        let target = CGFloat(frac) * contentHeight
        scroller.seek(to: target, maxOffset: maxScrollOffset)
    }

    /// Single dispatch point for `RemoteEvent`s coming off the bus. The
    /// view layer subscribes to the bus and forwards every event here.
    /// Mapping is exhaustive so a new event-vocab case becomes a compile
    /// error, not a silent no-op.
    func handleRemoteEvent(_ event: RemoteEvent) {
        switch event {
        case .playPause:    togglePlay()
        // scroll* are pointer / wheel deltas from a mouse-class remote
        // (BLE-M5 D-pad → GCMouse). Route to one-line steps instead of
        // collapsing to half-viewport jumps (audit B2 dead vocabulary).
        case .scrollUp:     lineUp()
        case .scrollDown:   lineDown()
        case .scrollLeft:   lineUp()
        case .scrollRight:  lineDown()
        case .lineUp:       lineUp()
        case .lineDown:     lineDown()
        case .speedUp:      speedUp()
        case .speedDown:    speedDown()
        case .jumpBackward: jumpBackward()
        case .jumpForward:  jumpForward()
        case .mirrorToggle: toggleMirror()
        case .restart:      restart()
        case .jumpToEnd:    jumpToEnd()
        case .nextSection:  nextSection()
        case .prevSection:  prevSection()
        case .jumpToStart:  jumpToStartOfTake()
        // Recording start/cancel/stop. Routed to the view's recording
        // dispatch via `onRecordToggle` because recording state lives on
        // AppState, not this per-script VM. No-op when the recording chip
        // isn't on screen (closure is nil), matching the on-screen chip.
        case .recordToggle: onRecordToggle?()
        // Drop a video marker into the in-flight recording (V3 headline).
        // Routed to the view's `RecordingSession.tapMark` via `onDropMarker`
        // for the same reason as `.recordToggle`. No-op when nothing records.
        case .dropMarker:   onDropMarker?()
        }
    }

    var maxScrollOffset: CGFloat {
        max(0, contentHeight - viewportHeight * 0.5)
    }

    /// Read position through the script, 0 (top) … 1 (end). Drives the
    /// left-edge `ReadingProgressBar`. Uses the same offset/maxScrollOffset
    /// the nav actions use, so it tracks manual drag, auto-scroll, and voice
    /// tracking identically.
    var readFraction: CGFloat {
        maxScrollOffset > 0 ? min(max(scroller.offset / maxScrollOffset, 0), 1) : 0
    }
}
