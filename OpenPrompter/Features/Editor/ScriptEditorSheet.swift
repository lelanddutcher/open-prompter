//
//  ScriptEditorSheet.swift
//  OpenPrompter
//
//  Edit the raw markdown of the currently-open script. Accepts a
//  `cachedSource` from the prompter VM so the sheet opens instantly with
//  the text already on-screen, and an `initialOffset` into that source so
//  we can teleport the cursor to the section the user was reading. Writes
//  back via FileCoordinatorReader.writeAsync; onSaved lets the prompter
//  reparse and refresh.
//
//  Also hosts the on-device "Format" action (V3 Design 04). The `✨ Format`
//  menu runs an on-device Foundation Models session against the editor's
//  CURRENT text with a preset prompt, streams a preview, and — behind a
//  confirm sheet — STAGES the result into `text` in memory (never disk). The
//  existing Save button remains the single disk-write action. Layered undo +
//  a crash stash guard the source: Discard (pre-apply), "Undo Format"
//  (post-apply, survives Save until dismiss), and a "Restore pre-Format
//  version?" banner if the app was killed mid-review. The feature
//  graceful-degrades: the button is hidden (or shown disabled with a fix
//  hint) whenever the model is unavailable — it never blocks or crashes.
//

import SwiftUI
import UIKit

struct ScriptEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    let file: ScriptFile
    let cachedSource: String?
    let initialOffset: Int
    let onSaved: () -> Void

    /// The on-device formatter. Injected so previews / tests can pass a mock;
    /// production builds resolve it from the factory (real on iOS 26+, noop
    /// below). Read live for availability on each open.
    let formatter: any ScriptFormatting

    init(
        file: ScriptFile,
        cachedSource: String?,
        initialOffset: Int,
        onSaved: @escaping () -> Void,
        formatter: (any ScriptFormatting)? = nil
    ) {
        self.file = file
        self.cachedSource = cachedSource
        self.initialOffset = initialOffset
        self.onSaved = onSaved
        self.formatter = formatter ?? ScriptFormatterFactory.make()
    }

    @State private var text: String = ""
    @State private var original: String = ""
    @State private var isLoading: Bool = true
    @State private var isSaving: Bool = false
    @State private var error: String?
    @State private var confirmDiscard: Bool = false
    @State private var pendingFocusOffset: Int?

    // MARK: Format state
    @State private var runController: FormatRunController?
    @State private var presetStore = FormatPresetStore()
    @State private var showPromptEditor: Bool = false
    @State private var showRestoreBanner: Bool = false
    @State private var appleIntelligenceHintVisible: Bool = false
    private let stash = FormatUndoStash()

    private var hasChanges: Bool { text != original }

    /// Formatter availability, read live so a model download finishing
    /// between opens flips the button on without a relaunch.
    private var formatAvailability: FormatAvailability { formatter.availability }

    /// Show the Format control only when the model can run OR the one
    /// user-fixable case (Apple Intelligence off) — everything else hides it.
    private var showFormatControl: Bool {
        formatAvailability.isAvailable || formatAvailability.isUserFixable
    }

    private var isFormatting: Bool { runController?.isBusy ?? false }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.bg.ignoresSafeArea()

                if isLoading {
                    ProgressView().tint(Theme.fg)
                } else if let error, text.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 36))
                        Text("Couldn't open this file.")
                            .font(.system(size: 16, weight: .bold))
                        Text(error)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Theme.muted)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                    }
                    .foregroundStyle(Theme.fg)
                } else {
                    VStack(spacing: 0) {
                        if showRestoreBanner {
                            FormatRestoreBanner(
                                onRestore: { restorePreFormat() },
                                onDismiss: { dismissRestoreBanner() }
                            )
                        }

                        TeleportingTextEditor(
                            text: $text,
                            focusOffset: $pendingFocusOffset
                        )
                        .background(Theme.bg)
                        .disabled(isFormatting)
                        .opacity(isFormatting ? 0.35 : 1)
                        .overlay { streamingOverlay }

                        if let error {
                            Text(error)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(Theme.red)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Theme.red.opacity(0.08))
                        }

                        if let message = runController?.errorMessage {
                            Text(message)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(Theme.amber)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Theme.amber.opacity(0.08))
                        }
                    }
                }
            }
            .navigationTitle(file.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        if hasChanges { confirmDiscard = true } else { dismiss() }
                    }
                    .foregroundStyle(Theme.fg)
                    .disabled(isFormatting)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    formatToolbarItem
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await save() }
                    } label: {
                        if isSaving {
                            ProgressView().tint(Theme.green)
                        } else {
                            Text("Save").bold()
                        }
                    }
                    .disabled(!hasChanges || isSaving || isFormatting)
                    .foregroundStyle(hasChanges ? Theme.green : Theme.muted)
                }
            }
            .task { await load() }
            .confirmationDialog(
                "Discard changes?",
                isPresented: $confirmDiscard,
                titleVisibility: .visible
            ) {
                Button("Discard", role: .destructive) { dismiss() }
                Button("Keep Editing", role: .cancel) { }
            } message: {
                Text("Unsaved edits will be lost.")
            }
            .sheet(isPresented: confirmSheetBinding) {
                if case .confirming(let formattedText)? = runController?.phase {
                    FormatConfirmSheet(
                        formattedText: formattedText,
                        onApply: { applyFormatted(formattedText) },
                        onDiscard: { runController?.discard() }
                    )
                }
            }
            .sheet(isPresented: $showPromptEditor) {
                FormatPromptEditorSheet(store: presetStore)
            }
            .alert(
                "Apple Intelligence is off",
                isPresented: $appleIntelligenceHintVisible,
                actions: { Button("OK", role: .cancel) {} },
                message: { Text(formatAvailability.userFixHint) }
            )
        }
    }

    // MARK: - Format toolbar item

    @ViewBuilder
    private var formatToolbarItem: some View {
        if runController?.canUndo == true {
            // Post-apply: the ✨ menu is replaced by "Undo Format" — survives
            // Save until the sheet dismisses.
            Button {
                undoFormat()
            } label: {
                Label("Undo Format", systemImage: "arrow.uturn.backward")
            }
            .foregroundStyle(Theme.amber)
            .disabled(isFormatting)
        } else if isFormatting {
            // While running: the control is a Cancel + spinner.
            Button {
                runController?.cancel()
            } label: {
                HStack(spacing: 6) {
                    ProgressView()
                    Text("Cancel")
                }
            }
            .foregroundStyle(Theme.fg)
        } else if showFormatControl {
            formatMenu
        }
    }

    @ViewBuilder
    private var formatMenu: some View {
        Menu {
            if formatAvailability.isAvailable {
                Button {
                    runPreset(.format)
                } label: {
                    Label("Format", systemImage: "wand.and.stars")
                }
                Button {
                    runPreset(.cleanup)
                } label: {
                    Label("Cleanup", systemImage: "sparkles")
                }
                Button {
                    runPreset(.custom)
                } label: {
                    Label(presetStore.preset(for: .custom).name, systemImage: "pencil.and.outline")
                }
                Divider()
                Button {
                    showPromptEditor = true
                } label: {
                    Label("Edit prompts…", systemImage: "slider.horizontal.3")
                }
            } else {
                // User-fixable (Apple Intelligence off): a single explanatory
                // action instead of the run options.
                Button {
                    appleIntelligenceHintVisible = true
                } label: {
                    Label("Turn on Apple Intelligence…", systemImage: "exclamationmark.circle")
                }
            }
        } label: {
            Label("Format", systemImage: "wand.and.stars")
                .foregroundStyle(formatAvailability.isAvailable ? Theme.green : Theme.muted)
        }
        .disabled(isSaving)
    }

    // MARK: - Streaming overlay

    @ViewBuilder
    private var streamingOverlay: some View {
        if case .streaming(let snapshot)? = runController?.phase {
            VStack(spacing: 12) {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("formatting on-device…")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Theme.fg)
                }
                if !snapshot.isEmpty {
                    ScrollView {
                        Text(snapshot)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(Theme.muted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                    }
                    .frame(maxHeight: 220)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                Text("your words are preserved — only formatting changes")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.dim)
            }
            .padding(20)
            .frame(maxWidth: 360)
            .background(Theme.bg.opacity(0.92), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Theme.border, lineWidth: 1)
            )
            .padding(24)
        }
    }

    /// Drives the confirm sheet purely from the controller's phase, so
    /// dismissing the sheet routes back through Discard.
    private var confirmSheetBinding: Binding<Bool> {
        Binding(
            get: {
                if case .confirming? = runController?.phase { return true }
                return false
            },
            set: { presenting in
                if !presenting {
                    // Sheet dismissed without a button (swipe-down) → Discard.
                    if case .confirming? = runController?.phase {
                        runController?.discard()
                    }
                }
            }
        )
    }

    // MARK: - Format actions

    private func runPreset(_ kind: FormatPreset.Kind) {
        error = nil
        let preset = presetStore.preset(for: kind)
        runController?.run(source: text, preset: preset)
    }

    private func applyFormatted(_ formattedText: String) {
        runController?.apply(
            formattedText: formattedText,
            currentText: text,
            assign: { text = $0 }
        )
    }

    private func undoFormat() {
        runController?.undo(assign: { text = $0 })
    }

    private func restorePreFormat() {
        if let stashed = stash.read(for: file.url) {
            text = stashed
        }
        stash.clear(for: file.url)
        showRestoreBanner = false
    }

    private func dismissRestoreBanner() {
        stash.clear(for: file.url)
        showRestoreBanner = false
    }

    // MARK: - Actions

    private func load() async {
        isLoading = true
        defer { isLoading = false }

        // Build the run controller now that we know the file URL. Sharing the
        // stash instance keeps the restore-banner path and the apply path
        // pointed at the same directory.
        runController = FormatRunController(
            formatter: formatter,
            scriptURL: file.url,
            stash: stash
        )

        // Surface the crash-stash restore banner if a format was applied but
        // not saved before the app closed.
        showRestoreBanner = stash.hasStash(for: file.url)

        // Fast path: the prompter VM already holds the raw text, so we can
        // render the editor without an extra coordinated read round-trip.
        if let cached = cachedSource {
            text = cached
            original = cached
            error = nil
            pendingFocusOffset = initialOffset
            return
        }

        do {
            let contents = try await FileCoordinatorReader.readAsync(file.url)
            text = contents
            original = contents
            error = nil
            pendingFocusOffset = initialOffset
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        do {
            try await FileCoordinatorReader.writeAsync(text, to: file.url)
            original = text
            error = nil
            // If this save committed a formatted result, drop the crash stash
            // (the pre-format source is now the history the user chose). Undo
            // remains available in-memory until the sheet dismisses.
            runController?.didSaveFormatted()
            onSaved()
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - UITextView bridge with jump-to-offset

/// Wraps `UITextView` so we can scroll the cursor to a specific character
/// offset on first appearance — SwiftUI's `TextEditor` has no hook for this.
private struct TeleportingTextEditor: UIViewRepresentable {
    @Binding var text: String
    @Binding var focusOffset: Int?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        tv.delegate = context.coordinator
        tv.backgroundColor = .clear
        tv.textColor = UIColor(Theme.fg)
        tv.font = UIFont.monospacedSystemFont(ofSize: 15, weight: .regular)
        tv.tintColor = UIColor(Theme.green)
        tv.keyboardDismissMode = .interactive
        tv.alwaysBounceVertical = true
        tv.autocorrectionType = .no
        tv.autocapitalizationType = .none
        tv.smartQuotesType = .no
        tv.smartDashesType = .no
        tv.textContainerInset = UIEdgeInsets(top: 12, left: 12, bottom: 24, right: 12)
        return tv
    }

    func updateUIView(_ tv: UITextView, context: Context) {
        if tv.text != text {
            tv.text = text
        }
        if let offset = focusOffset {
            DispatchQueue.main.async {
                applyFocus(tv, offset: offset)
                self.focusOffset = nil
            }
        }
    }

    private func applyFocus(_ tv: UITextView, offset rawOffset: Int) {
        let bounded = max(0, min(rawOffset, (tv.text as NSString).length))
        let range = NSRange(location: bounded, length: 0)
        tv.selectedRange = range
        if let position = tv.position(from: tv.beginningOfDocument, offset: bounded),
           let rect = tv.textRange(from: position, to: position).map({ tv.firstRect(for: $0) }),
           rect.origin.y.isFinite {
            // Put the jumped-to position about a third of the way down.
            let target = max(0, rect.origin.y - tv.bounds.height * 0.3)
            tv.setContentOffset(CGPoint(x: 0, y: target), animated: false)
        }
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        let parent: TeleportingTextEditor
        init(_ parent: TeleportingTextEditor) { self.parent = parent }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
        }
    }
}
