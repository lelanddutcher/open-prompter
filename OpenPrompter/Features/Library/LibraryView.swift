//
//  LibraryView.swift
//  OpenPrompter
//
//  Lists markdown files from the chosen folder, sorted by modified-date.
//  Tap a row to open the prompter. Pull-to-refresh forces a re-scan.
//

import SwiftUI

struct LibraryView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        NavigationStack {
            List {
                if state.watcher.files.isEmpty {
                    emptyState
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                } else {
                    ForEach(state.watcher.files) { file in
                        LibraryRow(file: file)
                            .listRowBackground(Theme.bg)
                            .listRowSeparatorTint(Theme.dim.opacity(0.2))
                            .onTapGesture {
                                state.open(file)
                                Haptics.tap()
                            }
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Theme.bg)
            .navigationTitle("Scripts")
            .navigationBarTitleDisplayMode(.inline)
            .refreshable {
                // NSMetadataQuery auto-updates, but pulling feels better for
                // users who want to force a re-scan.
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Change Folder", systemImage: "folder") {
                            state.returnToPicker()
                        }
                        // v1.1: Settings
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .foregroundStyle(Theme.fg)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer().frame(height: 60)
            Image(systemName: "doc.text")
                .font(.system(size: 48))
                .foregroundStyle(Theme.dim)
            Text(loadingText)
                .font(.system(size: Theme.sizeBody + 1, weight: .medium))
                .foregroundStyle(Theme.dim)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity)
    }

    private var loadingText: String {
        if !state.watcher.isRunning {
            return "Folder not connected. Tap the menu to pick one."
        }
        if state.watcher.files.isEmpty {
            return "No markdown files yet. Try adding a .md file to your folder on your Mac."
        }
        return ""
    }
}
