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
        let diskConfig = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: false,
            cloudKitDatabase: .none
        )
        if let container = try? ModelContainer(for: schema, configurations: diskConfig) {
            return container
        }
        // On-disk store init failed (corrupted store, migration problem, disk
        // pressure). RecentScript is a cache — losing it is acceptable. Fall
        // back to an in-memory container so the app launches instead of
        // crashing on first paint.
        let memoryConfig = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
        if let container = try? ModelContainer(for: schema, configurations: memoryConfig) {
            return container
        }
        // As an ultimate last resort, build the container with default config.
        // If even this throws, SwiftData itself is broken on this device and
        // we have no good recovery path — but we propagate the error via the
        // try, not fatalError, so the crash happens at a place a symbolicated
        // stack trace is informative.
        return try! ModelContainer(for: schema)
    }()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appState)
                .preferredColorScheme(preferredScheme)
                .onAppear { UbiquitousPrefsMirror.start() }
                // 2.0.1: prime Camera + Microphone + Speech Recognition at
                // launch. `.task` runs once when the scene mounts, on the
                // main actor — exactly what `PermissionPrimer` expects.
                // Already-answered permissions are skipped silently so this
                // is cheap on warm launches.
                //
                // After permissions resolve, start the camera session if the
                // PERSISTED `cameraStyle != .off`, so a returning user who
                // left the camera on gets a live preview without cycling the
                // chip. The registered default is `.off` (camera is opt-in —
                // see `Prefs.cameraStyle`), so a fresh install no-ops here and
                // never auto-mounts a black PiP tile. `bootstrapCameraIfNeeded`
                // guards on `style != .off` internally.
                .task {
                    await PermissionPrimer.requestAllIfNeeded()
                    await PermissionPrimer.bootstrapCameraIfNeeded(appState.cameraStore)
                }
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
