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

    /// Voice-tracking scroll target. Set on each successful alignment
    /// match; the per-frame ticker in `TeleprompterView` lerps the
    /// scroller toward this value. `nil` when no match is pending,
    /// which short-circuits the ticker to a no-op. Cleared when voice
    /// tracking stops.
    var voiceTargetOffset: CGFloat?

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
            let rules: StrippingRules = Prefs.aggressiveStripping ? .aggressive : .gentle
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

    /// Bump the scroll speed by 5 pts/s, clamped to the slider range.
    func speedUp()   { setSpeed(speed + 5) }
    /// Cut the scroll speed by 5 pts/s, clamped to the slider range.
    func speedDown() { setSpeed(speed - 5) }

    /// Move scroll to the next H1/H2 heading below the eye-line. Treats the
    /// fractional layout (block index / count of total height) the same way
    /// `currentBlockIndex` does — good enough for the "navigate by section"
    /// remote action without standing up a full per-block measurement pass.
    func nextSection() {
        guard !parsed.blocks.isEmpty, contentHeight > 0 else { return }
        let currentIdx = currentBlockIndex
        if let nextIdx = parsed.blocks.indices
            .first(where: { $0 > currentIdx && parsed.blocks[$0].isHeading })
        {
            seekToBlockIndex(nextIdx)
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
        case .scrollUp:     jumpBackward()
        case .scrollDown:   jumpForward()
        case .scrollLeft:   jumpBackward()
        case .scrollRight:  jumpForward()
        case .speedUp:      speedUp()
        case .speedDown:    speedDown()
        case .jumpBackward: jumpBackward()
        case .jumpForward:  jumpForward()
        case .mirrorToggle: toggleMirror()
        case .restart:      restart()
        case .nextSection:  nextSection()
        case .prevSection:  prevSection()
        case .jumpToStart:  jumpToStartOfTake()
        }
    }

    var maxScrollOffset: CGFloat {
        max(0, contentHeight - viewportHeight * 0.5)
    }
}
