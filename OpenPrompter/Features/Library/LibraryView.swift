//
//  LibraryView.swift
//  OpenPrompter
//
//  Lists markdown files from the chosen folder. Mono nav title ("scripts"
//  lowercase per §1 voice spine), ghost path-style empty state, hairline
//  row separators — aligned with design-language.md §7.4.
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
                            .listRowSeparatorTint(Theme.border)
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
            .navigationTitle("scripts")
            .navigationBarTitleDisplayMode(.inline)
            .refreshable {
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    OpenPrompterLogo(height: 24)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Change Folder", systemImage: "folder") {
                            state.returnToPicker()
                        }
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
            HStack(spacing: 4) {
                Text("$").foregroundStyle(Theme.green)
                Text("ls ").foregroundStyle(Theme.ghost)
                Text("~/scripts").foregroundStyle(Theme.muted)
            }
            .font(.system(size: 13, weight: .semibold, design: .monospaced))
            .tracking(0.5)

            Image(systemName: "doc.text")
                .font(.system(size: 42))
                .foregroundStyle(Theme.ghost)
                .padding(.top, 8)

            Text(loadingText)
                .font(.system(size: 15))
                .foregroundStyle(Theme.muted)
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
