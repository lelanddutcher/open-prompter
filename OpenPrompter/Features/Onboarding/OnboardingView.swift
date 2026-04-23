//
//  OnboardingView.swift
//  OpenPrompter
//
//  Three-slide intro. Uses the wordmark on slide 1, mono ghost ## path
//  labels over each slide title, Open Green pagination dot, and the
//  primary+ghost button pair per design-language.md §7.2.
//

import SwiftUI

struct OnboardingView: View {
    @Environment(AppState.self) private var state
    @State private var page: Int = 0

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $page) {
                slide(
                    index: 0,
                    pathLabel: "## hello.md",
                    title: "Open Prompter",
                    body: "A free teleprompter for the markdown files you already have.",
                    subdued: "No account. No subscription. No paste.",
                    isWordmark: true
                )

                slide(
                    index: 1,
                    pathLabel: "## what-is-markdown.md",
                    title: "What's a markdown file?",
                    body: "A plain text file with a .md extension. Obsidian, Bear, iA Writer, VS Code, even TextEdit can open one.",
                    subdued: "Universal, human-readable, yours forever. Open Prompter reads them as-is."
                )

                slide(
                    index: 2,
                    pathLabel: "## how-it-syncs.md",
                    title: "How it syncs",
                    body: "Edit on your Mac and the file shows up here, usually within a minute depending on your sync service.",
                    subdued: "iCloud is fastest. Dropbox and Google Drive take longer. Pull down on the script list to force a refresh."
                )
            }
            #if os(iOS)
            .tabViewStyle(.page(indexDisplayMode: .never))
            #endif

            HStack(spacing: 8) {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .fill(i == page ? Theme.green : Theme.ghost.opacity(0.5))
                        .frame(width: 7, height: 7)
                        .shadow(color: i == page ? Theme.green.opacity(0.7) : .clear, radius: 4)
                }
            }
            .padding(.bottom, 20)

            Button(action: advance) {
                HStack(spacing: 8) {
                    if page < 2 {
                        Text("next")
                            .font(.system(size: 14, weight: .semibold, design: .monospaced))
                            .tracking(0.5)
                        Image(systemName: "arrow.right")
                            .font(.system(size: 13, weight: .bold))
                    } else {
                        Image(systemName: "folder")
                            .font(.system(size: 13, weight: .bold))
                        Text("$ pick my folder")
                            .font(.system(size: 14, weight: .semibold, design: .monospaced))
                            .tracking(0.5)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: Theme.hitCTA)
                .background(Theme.green)
                .foregroundStyle(Color(red: 0.03, green: 0.09, blue: 0.05))
                .clipShape(RoundedRectangle(cornerRadius: Theme.radiusMd, style: .continuous))
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 28)
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
    private func slide(
        index: Int,
        pathLabel: String,
        title: String,
        body: String,
        subdued: String,
        isWordmark: Bool = false
    ) -> some View {
        VStack(spacing: 16) {
            Spacer()

            // Ghost "## path.md" label per §6.1.
            Text(pathLabel)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .tracking(0.6)
                .foregroundStyle(Theme.ghost)

            if isWordmark {
                Wordmark(size: 28)
            } else {
                Text(title)
                    .font(.system(size: 30, weight: .heavy, design: .monospaced))
                    .tracking(-0.6)
                    .foregroundStyle(Theme.fg)
                    .multilineTextAlignment(.center)
            }

            Text(body)
                .font(.system(size: 18))
                .foregroundStyle(Theme.fg.opacity(0.95))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 8)
                .padding(.top, 4)

            Text(subdued)
                .font(.system(size: 14))
                .foregroundStyle(Theme.muted)
                .multilineTextAlignment(.center)

            Spacer()
            Spacer()
        }
        .padding(.horizontal, 32)
        .tag(index)
    }
}
