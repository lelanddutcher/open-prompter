//
//  FormatPromptEditorSheet.swift
//  OpenPrompter
//
//  "Edit prompts…" surface (V3 Design 04 §2.3). One row per preset (Format,
//  Cleanup, Custom); selecting a preset reveals the EXACT prompt string sent
//  to the model in a multiline TextEditor — WYSIWYG, no hidden wrapping.
//  Reset-to-default per built-in preset (disabled if unchanged). The Custom
//  preset's name is editable; built-ins are fixed. Changes persist
//  immediately via `FormatPresetStore` → `Prefs`.
//

import SwiftUI

struct FormatPromptEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var store: FormatPresetStore

    /// Which preset's prompt is being edited. Drives the detail editor.
    @State private var editingKind: FormatPreset.Kind?

    var body: some View {
        NavigationStack {
            Form {
                Section("presets") {
                    ForEach(FormatPreset.Kind.allCases, id: \.self) { kind in
                        Button {
                            editingKind = kind
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(store.preset(for: kind).name)
                                        .font(.system(size: 15, weight: .semibold))
                                        .foregroundStyle(Theme.fg)
                                    Text(subtitle(for: kind))
                                        .font(.system(size: 12))
                                        .foregroundStyle(Theme.dim)
                                }
                                Spacer()
                                if store.preset(for: kind).isEdited {
                                    Text("EDITED")
                                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                                        .tracking(0.8)
                                        .foregroundStyle(Theme.amber)
                                }
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(Theme.ghost)
                            }
                        }
                    }
                }

                Section {
                    Text("the prompt you edit here is exactly what's sent to the on-device model as its instructions — your script flows in as the content. nothing is wrapped or hidden.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.dim)
                }
            }
            .navigationTitle("edit prompts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .navigationDestination(item: $editingKind) { kind in
                FormatPromptDetailEditor(store: store, kind: kind)
            }
        }
    }

    private func subtitle(for kind: FormatPreset.Kind) -> String {
        switch kind {
        case .format:  return "spacing, dividers, sparing emphasis"
        case .cleanup: return "light tidy — spacing & broken markdown"
        case .custom:  return "your own prompt"
        }
    }
}

// MARK: - Per-preset detail editor

/// Detail screen: edit the literal prompt string (and, for Custom, the name),
/// with a per-built-in reset-to-default. Persists on change.
private struct FormatPromptDetailEditor: View {
    @Bindable var store: FormatPresetStore
    let kind: FormatPreset.Kind

    @State private var draftPrompt: String = ""
    @State private var draftName: String = ""

    var body: some View {
        Form {
            if kind == .custom {
                Section("name") {
                    TextField("Custom", text: $draftName)
                        .autocorrectionDisabled()
                        .onChange(of: draftName) { _, new in
                            store.setCustomName(new)
                        }
                }
            }

            Section("prompt sent to the model") {
                TextEditor(text: $draftPrompt)
                    .font(.system(size: 13, design: .monospaced))
                    .frame(minHeight: 260)
                    .autocorrectionDisabled()
                    .onChange(of: draftPrompt) { _, new in
                        store.setPrompt(new, for: kind)
                    }
            }

            Section {
                Button(role: .destructive) {
                    store.resetToDefault(kind)
                    draftPrompt = FormatPreset.defaultPrompt(for: kind)
                } label: {
                    Label("reset to default", systemImage: "arrow.counterclockwise")
                }
                .disabled(!isEdited)

                Text(isEdited
                     ? "this prompt differs from the shipped default."
                     : "this is the shipped default prompt.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.dim)
            }
        }
        .navigationTitle(store.preset(for: kind).name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            let preset = store.preset(for: kind)
            draftPrompt = preset.prompt
            draftName = preset.name
        }
    }

    private var isEdited: Bool {
        draftPrompt != FormatPreset.defaultPrompt(for: kind)
    }
}
