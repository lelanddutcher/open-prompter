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
    var isLoading: Bool = true
    var loadError: String?

    // MARK: - Reload banner

    var reloadAvailable: Bool = false

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
            self.parsed = parsedResult
        } catch {
            self.loadError = error.localizedDescription
        }
        self.isLoading = false
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
