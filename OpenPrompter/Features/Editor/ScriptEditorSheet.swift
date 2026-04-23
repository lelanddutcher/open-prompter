//
//  ScriptEditorSheet.swift
//  OpenPrompter
//
//  Edit the raw markdown of the currently-open script. Reads via
//  FileCoordinatorReader, writes via FileCoordinatorReader.writeAsync,
//  and calls `onSaved` so the prompter can reparse and refresh.
//
//  This is intentionally a thin editor. Most users will prefer editing
//  on their Mac; this handles typo fixes and quick line changes on-device.
//

import SwiftUI

struct ScriptEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    let file: ScriptFile
    let onSaved: () -> Void

    @State private var text: String = ""
    @State private var original: String = ""
    @State private var isLoading: Bool = true
    @State private var isSaving: Bool = false
    @State private var error: String?
    @State private var confirmDiscard: Bool = false

    private var hasChanges: Bool { text != original }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.bg.ignoresSafeArea()

                if isLoading {
                    ProgressView().tint(Theme.fg)
                } else if let error, text.isEmpty {
                    // Fatal read error — no text to edit.
                    VStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 36))
                        Text("Couldn't open this file.")
                            .font(.system(size: Theme.sizeButton, weight: .bold))
                        Text(error)
                            .font(.system(size: Theme.sizePill))
                            .foregroundStyle(Theme.dim)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                    }
                    .foregroundStyle(Theme.fg)
                } else {
                    VStack(spacing: 0) {
                        TextEditor(text: $text)
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(Theme.fg)
                            .scrollContentBackground(.hidden)
                            .background(Theme.bg)
                            .padding(.horizontal, 12)
                            .padding(.top, 8)

                        if let error {
                            Text(error)
                                .font(.system(size: Theme.sizePill))
                                .foregroundStyle(Theme.alert)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Theme.alert.opacity(0.08))
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
                            ProgressView().tint(Theme.accent)
                        } else {
                            Text("Save").bold()
                        }
                    }
                    .disabled(!hasChanges || isSaving)
                    .foregroundStyle(hasChanges ? Theme.accent : Theme.dim)
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
        .preferredColorScheme(.dark)
    }

    // MARK: - Actions

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let contents = try await FileCoordinatorReader.readAsync(file.url)
            text = contents
            original = contents
            error = nil
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
