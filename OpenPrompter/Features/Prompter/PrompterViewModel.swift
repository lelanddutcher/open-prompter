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
    var mirroredVertical: Bool = false
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

    // MARK: - Init

    init(file: ScriptFile) {
        self.file = file
        self.speed = Prefs.defaultSpeed
        self.fontSize = Prefs.defaultFont
        self.mirroredHorizontal = Prefs.mirrorDefault
        self.focus = Prefs.focusDefault
    }

    // MARK: - Loading

    func load() async {
        isLoading = true
        loadError = nil
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
        isPlaying.toggle()
        if !isPlaying {
            scroller.resetTick()
        }
        Haptics.tap()
    }

    func toggleMirror() {
        mirroredHorizontal.toggle()
        Haptics.tap(.medium)
    }

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
        scroller.seek(to: 0, maxOffset: maxScrollOffset)
    }

    func jumpBackward() {
        scroller.seek(to: scroller.offset - viewportHeight * 0.5, maxOffset: maxScrollOffset)
    }

    func jumpForward() {
        scroller.seek(to: scroller.offset + viewportHeight * 0.5, maxOffset: maxScrollOffset)
    }

    var maxScrollOffset: CGFloat {
        max(0, contentHeight - viewportHeight * 0.5)
    }
}
