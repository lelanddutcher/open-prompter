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
    // Driven by the `appearance` pref. UserDefaults-backed so flipping this
    // from Settings updates the scene colorScheme immediately, and the same
    // storage is mirrored to iCloud KVS by UbiquitousPrefsMirror.
    @AppStorage(PrefKey.appearance.rawValue) private var appearanceRaw: String =
        Prefs.Appearance.dark.rawValue

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
                .preferredColorScheme(preferredScheme)
                .onAppear { UbiquitousPrefsMirror.start() }
        }
        .modelContainer(modelContainer)
    }

    /// Nil means "follow the system", which lets iOS pick light/dark.
    /// Otherwise, honor the user's explicit choice.
    private var preferredScheme: ColorScheme? {
        switch Prefs.Appearance(rawValue: appearanceRaw) ?? .dark {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }
}
