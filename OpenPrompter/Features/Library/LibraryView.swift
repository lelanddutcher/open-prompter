//
//  LibraryView.swift
//  OpenPrompter
//
//  Lists markdown files from the chosen folder. Header shows a mono
//  `$ ls <folder>` path using the actual picked folder so it's obvious
//  which directory you're in. Includes a "Change Folder" menu entry and a
//  primary "New Script" action that creates a .md file and opens the
//  editor on it directly.
//

import SwiftUI

struct LibraryView: View {
    @Environment(AppState.self) private var state
    @State private var isCreating: Bool = false
    @State private var newScriptName: String = ""
    @State private var createError: String?
    @State private var showSettings: Bool = false

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
            .padListWidth()
            .frame(maxWidth: .infinity)
            .background(Theme.bg)
            .navigationTitle("scripts")
            .navigationBarTitleDisplayMode(.inline)
            .refreshable {
                state.watcher.refresh()
                try? await Task.sleep(nanoseconds: 400_000_000)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    OpenPrompterLogo(height: 24)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 10) {
                        Button {
                            newScriptName = ""
                            createError = nil
                            isCreating = true
                        } label: {
                            Image(systemName: "square.and.pencil")
                                .foregroundStyle(Theme.green)
                        }
                        .accessibilityLabel("New script")

                        Menu {
                            Button("Settings", systemImage: "gearshape") {
                                showSettings = true
                            }
                            Button("Change Folder", systemImage: "folder") {
                                state.returnToPicker()
                            }
                            Button("Refresh Now", systemImage: "arrow.clockwise") {
                                state.watcher.refresh()
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                                .foregroundStyle(Theme.fg)
                        }
                    }
                }
            }
            .alert("Name your script", isPresented: $isCreating) {
                TextField("launch-announcement", text: $newScriptName)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Create") { createScript() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("A new .md file will be created in your folder.")
            }
            .alert("Couldn't create script", isPresented: .constant(createError != nil), presenting: createError) { _ in
                Button("OK") { createError = nil }
            } message: { err in
                Text(err)
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
            }
        }
    }

    // MARK: - Sub-views

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer().frame(height: 40)
            Image(systemName: "doc.text")
                .font(.system(size: 42))
                .foregroundStyle(Theme.ghost)

            Text(loadingText)
                .font(.system(size: 15))
                .foregroundStyle(Theme.muted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            if state.watcher.isRunning {
                Button {
                    newScriptName = ""
                    createError = nil
                    isCreating = true
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "plus.circle.fill")
                        Text("Create new script")
                            .font(.system(size: 14, weight: .semibold))
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .background(Theme.green)
                    .foregroundStyle(Color(red: 0.03, green: 0.09, blue: 0.05))
                    .clipShape(RoundedRectangle(cornerRadius: Theme.radiusMd))
                }
                .padding(.top, 8)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var loadingText: String {
        if !state.watcher.isRunning {
            return "Folder not connected. Tap the menu to pick one."
        }
        if state.watcher.files.isEmpty {
            return "No markdown files in this folder yet."
        }
        return ""
    }

    // MARK: - Actions

    private func createScript() {
        let trimmed = newScriptName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            createError = "Please enter a filename."
            return
        }
        guard let folder = state.watcher.scopeURL else {
            createError = "No folder selected."
            return
        }
        let filename = trimmed.hasSuffix(".md") ? trimmed : trimmed + ".md"
        let url = folder.appendingPathComponent(filename)

        // Default body — follows the design language script-shape convention.
        let body = """
        # \(trimmed.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " "))

        INT. LOCATION — TIME

        Your first line goes here.

        [ beat ]

        Keep writing.
        """

        do {
            try Data(body.utf8).write(to: url, options: [.atomic])
            state.watcher.refresh()
            // Open the newly-created file directly in the prompter, which
            // already has a pencil edit button next to the reload chip.
            let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate) ?? .now
            let file = ScriptFile(
                id: url,
                name: filename,
                mtime: mtime,
                downloadState: .current
            )
            state.open(file)
        } catch {
            createError = error.localizedDescription
        }
    }
}
