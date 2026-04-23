//
//  FolderPickerView.swift
//  OpenPrompter
//
//  Empty-state invitation to pick a folder. Shown when no bookmark is
//  persisted. Opens a UIDocumentPickerViewController folder picker.
//

import SwiftUI

struct FolderPickerView: View {
    @Environment(AppState.self) private var state
    @State private var showPicker: Bool = false

    var body: some View {
        VStack(spacing: 16) {
            Spacer()

            Text("Open Prompter")
                .font(.system(size: Theme.sizeDisplay, weight: .bold))
                .foregroundStyle(Theme.fg)

            Text("Pick a folder with your markdown scripts.")
                .font(.system(size: Theme.sizeBody + 1, weight: .regular))
                .foregroundStyle(Theme.dim)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            Text("iCloud Drive, your Obsidian vault, or anywhere the Files app can reach.")
                .font(.system(size: Theme.sizeBody - 1, weight: .regular))
                .foregroundStyle(Theme.dim.opacity(0.8))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
                .padding(.bottom, 8)

            Spacer()

            Button(action: { showPicker = true }) {
                Text("Pick Folder")
                    .font(.system(size: Theme.sizeButton, weight: .bold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 56)
                    .background(Theme.fg)
                    .foregroundStyle(Color.black)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius))
            }
            .padding(.horizontal, 24)

            Button(action: { state.openDemoScript() }) {
                Text("Try the Demo Script")
                    .font(.system(size: Theme.sizeBody, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .foregroundStyle(Theme.dim)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
        .background(Theme.bg)
        #if os(iOS)
        .sheet(isPresented: $showPicker) {
            DocumentPickerRepresentable(
                onPick: { url in
                    state.adoptFolder(url)
                    showPicker = false
                },
                onCancel: {
                    showPicker = false
                }
            )
            .ignoresSafeArea()
        }
        #endif
    }
}
