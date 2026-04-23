//
//  ScriptEditorSheet.swift
//  OpenPrompter
//
//  v1 stub — opens the raw markdown in an editable TextEditor sheet. Writes
//  back to the file via FileCoordinatorReader.writeAsync. Most users will
//  prefer editing on their Mac; this exists for one-off tweaks.
//

import SwiftUI

struct ScriptEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    let file: ScriptFile

    @State private var text: String = ""
    @State private var isLoading: Bool = true
    @State private var error: String?
    @State private var hasChanges: Bool = false

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.bg.ignoresSafeArea()
                if isLoading {
                    ProgressView().tint(Theme.fg)
                } else if let error {
                    VStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle").font(.system(size: 36))
                        Text(error).foregroundStyle(Theme.dim).padding()
                    }
                    .foregroundStyle(Theme.fg)
                } else {
                    TextEditor(text: $text)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(Theme.fg)
                        .scrollContentBackground(.hidden)
                        .background(Theme.bg)
                        .padding(12)
                        .onChange(of: text) { _, _ in hasChanges = true }
                }
            }
            .navigationTitle(file.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(Theme.fg)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") {
                        Task { await save() }
                    }
                    .disabled(!hasChanges)
                    .foregroundStyle(hasChanges ? Theme.accent : Theme.dim)
                }
            }
            .task { await load() }
        }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            text = try await FileCoordinatorReader.readAsync(file.url)
            hasChanges = false
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func save() async {
        do {
            try await FileCoordinatorReader.writeAsync(text, to: file.url)
            hasChanges = false
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
