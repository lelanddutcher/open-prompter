//
//  OpenPrompterApp.swift
//  OpenPrompter
//
//  Entry point. Configures the scene, wires SwiftData container, pushes
//  AppState through environment. iOS 17+.
//

import SwiftUI
import SwiftData

@main
struct OpenPrompterApp: App {
    @State private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appState)
                .preferredColorScheme(.dark)
                .onAppear { UbiquitousPrefsMirror.start() }
        }
        .modelContainer(for: RecentScript.self)
    }
}
