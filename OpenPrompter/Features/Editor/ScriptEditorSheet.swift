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

import SwiftUI
import UIKit

struct ScriptEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    let file: ScriptFile
    let cachedSource: String?
    let initialOffset: Int
    let onSaved: () -> Void

    @State private var text: String = ""
    @State private var original: String = ""
    @State private var isLoading: Bool = true
    @State private var isSaving: Bool = false
    @State private var error: String?
    @State private var confirmDiscard: Bool = false
    @State private var pendingFocusOffset: Int?

    private var hasChanges: Bool { text != original }

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
                        TeleportingTextEditor(
                            text: $text,
                            focusOffset: $pendingFocusOffset
                        )
                        .background(Theme.bg)

                        if let error {
                            Text(error)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(Theme.red)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Theme.red.opacity(0.08))
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
                    .disabled(!hasChanges || isSaving)
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
        }
        // Inherit the app-level appearance (dark default, user may pick
        // light or system in Settings). The editor is chrome, not the
        // reading surface — no glass-glare reason to force dark.
    }

    // MARK: - Actions

    private func load() async {
        isLoading = true
        defer { isLoading = false }

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
