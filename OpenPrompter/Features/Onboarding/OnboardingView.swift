//
//  OnboardingView.swift
//  OpenPrompter
//
//  Three-slide intro. Educates the user on markdown as a universal text
//  format and sets honest expectations about sync latency. Shown once
//  before the first folder pick.
//

import SwiftUI

struct OnboardingView: View {
    @Environment(AppState.self) private var state
    @State private var page: Int = 0

    var body: some View {
        VStack(spacing: 0) {
            // Pager content
            TabView(selection: $page) {
                slide(
                    index: 0,
                    title: "Open Prompter",
                    body: "A free teleprompter for the markdown files you already have.",
                    subdued: "No account. No subscription. No paste."
                )

                slide(
                    index: 1,
                    title: "What's a Markdown File?",
                    body: "A plain text file with a .md extension. Obsidian, Bear, iA Writer, VS Code, and even TextEdit can open one.",
                    subdued: "Universal, human-readable, yours forever. Open Prompter reads them as-is."
                )

                slide(
                    index: 2,
                    title: "How It Syncs",
                    body: "Edit on your Mac and the file shows up here, usually within a minute depending on your sync service.",
                    subdued: "iCloud is fastest. Dropbox and Google Drive take longer. If you're in a hurry, pull down on the script list to refresh."
                )
            }
            #if os(iOS)
            .tabViewStyle(.page(indexDisplayMode: .never))
            #endif

            // Custom dots
            HStack(spacing: 8) {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .fill(i == page ? Theme.fg : Theme.dim.opacity(0.4))
                        .frame(width: 7, height: 7)
                }
            }
            .padding(.bottom, 20)

            // Advance / finish button
            Button(action: advance) {
                Text(page < 2 ? "Next" : "Pick My Folder")
                    .font(.system(size: Theme.sizeButton, weight: .bold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 56)
                    .background(Theme.fg)
                    .foregroundStyle(Color.black)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius))
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
        .background(Theme.bg)
    }

    private func advance() {
        if page < 2 {
            withAnimation { page += 1 }
        } else {
            state.completeOnboarding()
        }
    }

    @ViewBuilder
    private func slide(index: Int, title: String, body: String, subdued: String) -> some View {
        VStack(spacing: 20) {
            Spacer()
            Text(title)
                .font(.system(size: Theme.sizeDisplay, weight: .bold))
                .foregroundStyle(Theme.fg)
                .multilineTextAlignment(.center)
            Text(body)
                .font(.system(size: Theme.sizeButton + 2, weight: .medium))
                .foregroundStyle(Theme.fg.opacity(0.9))
                .multilineTextAlignment(.center)
            Text(subdued)
                .font(.system(size: Theme.sizeBody, weight: .regular))
                .foregroundStyle(Theme.dim)
                .multilineTextAlignment(.center)
            Spacer()
            Spacer()
        }
        .padding(.horizontal, 32)
        .tag(index)
    }
}
