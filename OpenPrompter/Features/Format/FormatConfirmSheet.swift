//
//  FormatConfirmSheet.swift
//  OpenPrompter
//
//  Confirm-before-apply surface (V3 Design 04 §2.2). The model's output is
//  STAGED, not applied — this sheet shows a scrollable read-only preview of
//  the formatted markdown with Apply (primary) and Discard. A confirmation
//  dialog is too small for a script preview, so this is a `.sheet` with a
//  `NavigationStack`. v1 ships a plain preview; a line-level diff is a
//  flagged follow-up.
//

import SwiftUI

struct FormatConfirmSheet: View {
    /// The staged formatted markdown to preview.
    let formattedText: String
    let onApply: () -> Void
    let onDiscard: () -> Void

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.bg.ignoresSafeArea()

                ScrollView {
                    Text(formattedText)
                        .font(.system(size: 14, design: .monospaced))
                        .foregroundStyle(Theme.fg)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                }
            }
            .navigationTitle("apply formatting?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Discard", role: .cancel) { onDiscard() }
                        .foregroundStyle(Theme.fg)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        onApply()
                    } label: {
                        Text("Apply").bold()
                    }
                    .foregroundStyle(Theme.green)
                }
            }
            .safeAreaInset(edge: .top) {
                Text("review the reformatted script. your words are unchanged — only spacing, dividers, and emphasis. apply stages it into the editor; you still tap Save to write the file.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.dim)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Theme.surface)
            }
        }
    }
}
