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
                    title: "open prompter",
                    body: "a free teleprompter for the markdown files you already have.",
                    subdued: "no account. no subscription. no paste."
                )

                slide(
                    index: 1,
                    title: "what's a markdown file?",
                    body: "a plain text file with a .md extension. obsidian, bear, ia writer, vs code, even textedit can open one.",
                    subdued: "universal, human-readable, yours forever. open prompter reads them as-is."
                )

                slide(
                    index: 2,
                    title: "how it syncs",
                    body: "edit on your mac, the file shows up here. usually within a minute, depending on your sync service.",
                    subdued: "icloud is fastest. dropbox and google drive take longer. if you're in a hurry, pull down on the script list to refresh."
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
                Text(page < 2 ? "Next" : "Pick my folder")
                    .font(.system(size: 17, weight: .bold))
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
                .font(.system(size: 32, weight: .bold))
                .foregroundStyle(Theme.fg)
                .multilineTextAlignment(.center)
            Text(body)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(Theme.fg.opacity(0.9))
                .multilineTextAlignment(.center)
            Text(subdued)
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(Theme.dim)
                .multilineTextAlignment(.center)
            Spacer()
            Spacer()
        }
        .padding(.horizontal, 32)
        .tag(index)
    }
}
