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

    private let modelContainer: ModelContainer = {
        let schema = Schema([RecentScript.self])
        // CloudKit is off for the local recent-scripts cache: the model uses
        // a unique constraint and non-optional fields, which CloudKit rejects.
        // The file content itself already syncs via iCloud Drive.
        let config = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: false,
            cloudKitDatabase: .none
        )
        do {
            return try ModelContainer(for: schema, configurations: config)
        } catch {
            fatalError("Failed to create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appState)
                .preferredColorScheme(.dark)
                .onAppear { UbiquitousPrefsMirror.start() }
        }
        .modelContainer(modelContainer)
    }
}
