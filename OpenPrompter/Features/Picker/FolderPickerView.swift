//
//  FolderPickerView.swift
//  OpenPrompter
//
//  Empty-state invitation to pick a folder. Leads with the `[open] prompter`
//  wordmark per design-language.md §7.1, mono ghost path as a subtitle
//  label, primary + ghost buttons per §7.2.
//

import SwiftUI

struct FolderPickerView: View {
    @Environment(AppState.self) private var state
    @State private var showPicker: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            Wordmark(size: 24)
                .padding(.bottom, 8)

            HStack(spacing: 4) {
                Text("$").foregroundStyle(Theme.green)
                Text("open ").foregroundStyle(Theme.ghost)
                Text("~/scripts").foregroundStyle(Theme.muted)
            }
            .font(.system(size: 12, weight: .semibold, design: .monospaced))
            .tracking(0.6)
            .padding(.top, 4)

            Text("Pick a folder with your markdown scripts.")
                .font(.system(size: 17))
                .foregroundStyle(Theme.muted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
                .padding(.top, 24)

            Text("iCloud Drive, your Obsidian vault, or anywhere the Files app can reach.")
                .font(.system(size: 14))
                .foregroundStyle(Theme.ghost)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
                .padding(.top, 8)

            Spacer()

            // Primary CTA — Open Green fill, ink-black glyph.
            Button(action: { showPicker = true }) {
                HStack(spacing: 8) {
                    Image(systemName: "folder")
                        .font(.system(size: 13, weight: .bold))
                    Text("$ pick folder")
                        .font(.system(size: 14, weight: .semibold, design: .monospaced))
                        .tracking(0.5)
                }
                .frame(maxWidth: .infinity)
                .frame(height: Theme.hitCTA)
                .background(Theme.green)
                .foregroundStyle(Color(red: 0.03, green: 0.09, blue: 0.05))
                .clipShape(RoundedRectangle(cornerRadius: Theme.radiusMd, style: .continuous))
            }
            .padding(.horizontal, 24)

            // Ghost CTA — transparent, hairline border.
            Button(action: { state.openDemoScript() }) {
                Text("try the demo script")
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .tracking(0.5)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .foregroundStyle(Theme.muted)
                    .background(Color.clear)
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.radiusMd, style: .continuous)
                            .stroke(Theme.border, lineWidth: 1)
                    )
            }
            .padding(.horizontal, 24)
            .padding(.top, 10)
            .padding(.bottom, 28)
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
