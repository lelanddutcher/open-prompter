//
//  RootView.swift
//  OpenPrompter
//
//  Routes between onboarding, picker, library, and prompter. One place to
//  add new top-level destinations as the app grows.
//

import SwiftUI

struct RootView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()

            switch state.route {
            case .onboarding:
                OnboardingView()
            case .picker:
                FolderPickerView()
            case .library:
                LibraryView()
            case .prompter(let file):
                TeleprompterView(file: file)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: routeKey)
    }

    private var routeKey: String {
        switch state.route {
        case .onboarding: return "onboarding"
        case .picker: return "picker"
        case .library: return "library"
        case .prompter(let file): return "prompter-\(file.url.absoluteString)"
        }
    }
}
