//
//  FormatRunController.swift
//  OpenPrompter
//
//  The state machine behind a single Format run in the editor. Owns the
//  lifecycle — length pre-flight → stream → confirm → apply → undo/stash —
//  so the SwiftUI editor stays a thin binding layer AND the whole flow is
//  unit-testable with a MockScriptFormatter and an injected stash directory
//  (no real container, no Apple Intelligence).
//
//  It NEVER writes the script file. It only ever mutates its own `text`
//  binding on Apply/Undo; the editor's existing Save button remains the one
//  explicit disk-write action. On Apply it writes the pre-format copy to the
//  crash stash; on a clean save-of-formatted or explicit Undo it clears it.
//
//  No FoundationModels import: holds `any ScriptFormatting`.
//

import Foundation
import Observation

@Observable
@MainActor
final class FormatRunController {

    /// Where the run is in its lifecycle. Drives the editor's overlay,
    /// toolbar affordance, and confirm sheet.
    enum Phase: Equatable {
        /// No run in flight; the `✨` menu is available.
        case idle
        /// Streaming from the model; editor is read-only + dimmed, Cancel
        /// affordance shown. `snapshot` is the latest cumulative text.
        case streaming(snapshot: String)
        /// Stream finished; the confirm sheet shows `formattedText`.
        case confirming(formattedText: String)
        /// Apply happened this session — the toolbar shows "Undo Format".
        /// Kept until the sheet dismisses so undo survives past Save.
        case applied
    }

    private(set) var phase: Phase = .idle

    /// User-facing error from the most recent run, if any. Rendered in the
    /// editor's existing inline error surface. Cleared when a new run starts.
    private(set) var errorMessage: String?

    /// The text captured immediately BEFORE the current/last Format run —
    /// the target of "Undo Format". `nil` until the first Apply.
    private(set) var preFormatText: String?

    /// True while a run occupies the formatter (guards concurrent runs — the
    /// menu is disabled while set).
    var isBusy: Bool {
        switch phase {
        case .streaming, .confirming: return true
        case .idle, .applied:         return false
        }
    }

    /// True when an Undo is currently available (post-Apply, until dismiss).
    var canUndo: Bool { preFormatText != nil && phase == .applied }

    private let formatter: any ScriptFormatting
    private let stash: FormatUndoStash
    private let scriptURL: URL

    /// The in-flight streaming task, so Cancel can `Task.cancel()` it.
    private var runTask: Task<Void, Never>?

    init(
        formatter: any ScriptFormatting,
        scriptURL: URL,
        stash: FormatUndoStash = FormatUndoStash()
    ) {
        self.formatter = formatter
        self.scriptURL = scriptURL
        self.stash = stash
    }

    /// Current availability of the formatter (read live).
    var availability: FormatAvailability { formatter.availability }

    // MARK: - Run

    /// Kick off a format run against `source` using `preset.prompt`. The
    /// caller passes the editor's CURRENT text (which may include unsaved
    /// edits) — Format operates on what the user sees. Returns immediately;
    /// progress lands on `phase`.
    ///
    /// Refuses BEFORE invoking the formatter when the length pre-flight fails
    /// (the design's "never apply a truncated result" defense starts here).
    func run(source: String, preset: FormatPreset) {
        guard !isBusy else { return }
        errorMessage = nil

        // Availability gate — should be pre-checked by the UI, but defend the
        // path so a race (model dropped mid-session) can't crash.
        guard formatter.availability.isAvailable else {
            errorMessage = FormatError.unavailable(formatter.availability).userMessage
            phase = .idle
            return
        }

        // Length pre-flight — refuse without calling the model.
        guard FormatTokenBudget.fitsBudget(source: source, instructions: preset.prompt) else {
            let overBy = FormatTokenBudget.wordsOverLimit(source: source, instructions: preset.prompt)
            errorMessage = overBy > 0
                ? "This script is too long to format on-device (about \(overBy) words over the limit). Try formatting a section at a time."
                : FormatError.outputTooLong.userMessage
            phase = .idle
            return
        }

        phase = .streaming(snapshot: "")
        let formatter = self.formatter
        runTask = Task { [weak self] in
            var latest = ""
            do {
                for try await snapshot in formatter.formatStream(source: source, prompt: preset.prompt) {
                    latest = snapshot
                    self?.phase = .streaming(snapshot: snapshot)
                }
            } catch {
                self?.finishWithError(error)
                return
            }
            self?.finishStream(with: latest)
        }
    }

    /// Cancel an in-flight run. The editor text is untouched (we only assign
    /// on Apply). Leaves the controller `.idle`.
    func cancel() {
        runTask?.cancel()
        runTask = nil
        // A cancelled stream throws `.cancelled` which routes through
        // finishWithError, but assign eagerly so the UI dismisses even if the
        // formatter doesn't honor cancellation promptly.
        if isBusy {
            phase = .idle
        }
    }

    // MARK: - Confirm / Apply / Undo

    /// Discard the staged result from the confirm sheet — nothing changes.
    func discard() {
        phase = .idle
    }

    /// Apply the staged formatted text. Captures the pre-format text (for
    /// Undo), writes it to the crash stash, sets the editor binding to the
    /// formatted text IN MEMORY (never disk), and moves to `.applied`.
    ///
    /// `currentText` is the editor's text at Apply time — captured as the
    /// pre-format snapshot. `assign` mutates the editor's text binding.
    func apply(
        formattedText: String,
        currentText: String,
        assign: (String) -> Void
    ) {
        preFormatText = currentText
        // Stash the pre-format copy off the main flow. A stash-write failure
        // must NOT block the apply — the in-memory `preFormatText` still
        // guarantees undo while the editor is open; the stash is only the
        // extra cross-crash safety net.
        let stash = self.stash
        let url = self.scriptURL
        Task { try? await stash.write(preFormatText: currentText, for: url) }

        assign(formattedText)
        phase = .applied
    }

    /// Undo the applied formatting: restore the pre-format text into the
    /// editor binding and clear the crash stash. Available post-Apply and
    /// (per the design) even after a Save, until the sheet dismisses.
    func undo(assign: (String) -> Void) {
        guard let original = preFormatText else { return }
        assign(original)
        clearStash()
        phase = .idle
    }

    /// Called by the editor after a successful Save of the FORMATTED text —
    /// the pre-format source is now the on-disk history the user chose, so
    /// the crash stash is no longer needed. Undo remains available in-memory
    /// (the design keeps `preFormatText` until dismiss), so we do NOT clear
    /// `preFormatText` here — only the on-disk stash.
    func didSaveFormatted() {
        clearStash()
    }

    // MARK: - Stream completion

    private func finishStream(with latest: String) {
        runTask = nil
        let trimmed = latest.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            errorMessage = FormatError.emptyOutput.userMessage
            phase = .idle
            return
        }
        phase = .confirming(formattedText: latest)
    }

    private func finishWithError(_ error: Error) {
        runTask = nil
        let mapped: FormatError
        if let formatError = error as? FormatError {
            mapped = formatError
        } else if error is CancellationError {
            mapped = .cancelled
        } else {
            mapped = FormatErrorMapper.map(description: error.localizedDescription)
        }
        // A cancel is not an error worth surfacing as red text — it's a user
        // action. Everything else shows the inline message.
        if mapped == .cancelled {
            errorMessage = nil
        } else {
            errorMessage = mapped.userMessage
        }
        phase = .idle
    }

    private func clearStash() {
        stash.clear(for: scriptURL)
    }
}
