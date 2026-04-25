//
//  AppState.swift
//  OpenPrompter
//
//  Observable global state. Tracks the chosen folder, the current watcher,
//  the selected script, and high-level navigation state. Owned by
//  OpenPrompterApp and passed down via .environment.
//

import Foundation
import Observation
import SwiftData

@Observable
@MainActor
final class AppState {
    enum Route: Equatable {
        case onboarding
        case picker
        case library
        case prompter(ScriptFile)
    }

    // MARK: - Navigation

    var route: Route = .picker

    // MARK: - Folder

    private(set) var folderURL: URL?
    private(set) var folderIsAccessible: Bool = false

    // MARK: - Watcher

    let watcher = ICloudWatcher()

    // MARK: - Remote control (Feature 7)

    /// App-wide store of (RemoteKey → RemoteEvent) bindings. Settings opens
    /// from the library — outside any prompter session — so the binding
    /// editor needs an instance that exists before/after the prompter view
    /// has been on screen. The active prompter session reads through to
    /// this same instance.
    let remoteBindings = RemoteBindingStore()

    /// `GCKeyboard.coalesced` presence indicator, used by Settings and the
    /// (future) prompter top-bar chip.
    let keyboardMonitor = KeyboardConnectionMonitor()

    // MARK: - Camera (V2 Feature 1)

    /// App-wide camera owner. The prompter view binds this to the chip,
    /// the preview, and the PiP tile. Lives on AppState (not on the
    /// per-VM PrompterViewModel) so the AVCaptureSession lifecycle survives
    /// the prompter open/close cycle and so Settings can render a section
    /// for camera prefs without a live prompter.
    let cameraStore = CameraStore()

    /// Recording-state flag (V2 Design 01 §"Tally-light border indicator")
    /// promoted in Feature 2 to a full state machine via `RecordingPhase`.
    /// `isRecording` is still computed from `phase == .recording(_)` so
    /// the existing tally-light wiring is unchanged.
    let recordingState = RecordingState()

    /// Audio-route monitor for the recording feature's microphone status
    /// row. Owned by AppState so the route observer survives Settings sheet
    /// presentation cycles. Started lazily — the prompter view triggers
    /// `start()` on appear so non-recording users don't pay the listener.
    let audioRouteMonitor = AudioRouteMonitor()

    /// Recording session — drives the writer pipeline + Live Activity.
    /// Initialized in `init` once the camera store + recording state are
    /// available. Stored on AppState so the session lifecycle survives
    /// the prompter open/close cycle (a force-quit during finalize would
    /// otherwise lose the take).
    let recordingSession: RecordingSession

    // MARK: - Banner

    enum BannerKind: Equatable {
        case reloadAvailable(URL)
        case syncing
        case stale(String)
    }
    var banner: BannerKind?

    // MARK: - Error surface

    var userFacingError: String?

    // MARK: - Lifecycle

    init() {
        Prefs.register()
        // The session needs both the camera store and the recording state,
        // both of which are stored properties initialized above. Init this
        // before bookmark resolution so a recovery scan that immediately
        // posts to the state machine has a session ready to handle it.
        self.recordingSession = RecordingSession(
            state: self.recordingState,
            cameraStore: self.cameraStore
        )
        resolveBookmarkAndStart()
        scanForInterruptedRecording()
        // Debug-only: launch flag `-autoDemo 1` opens the demo prompter
        // immediately, bypassing folder pick. Used by simulator runs.
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-autoDemo") {
            openDemoScript()
        }
        #endif
    }

    /// Recovery scan — if there's a stale `.mov` in Documents/Recordings/
    /// at launch, the previous run was force-quit mid-take. Surface a
    /// banner so the user can recover or discard. Per V2 Design 02 review
    /// note 8.
    private func scanForInterruptedRecording() {
        if let stale = RecordingFileStore.mostRecentStaleRecording() {
            recordingState.surfaceRecovery(url: stale)
        }
    }

    // MARK: - Navigation actions

    func open(_ file: ScriptFile) {
        route = .prompter(file)
        Prefs.lastFileURL = file.url.absoluteString
    }

    func closeScript() {
        route = .library
    }

    func returnToPicker() {
        stopWatcher()
        BookmarkStore.clear()
        folderURL = nil
        folderIsAccessible = false
        route = .picker
    }

    func completeOnboarding() {
        Prefs.onboardingCompleted = true
        if folderIsAccessible {
            route = .library
        } else {
            route = .picker
        }
    }

    /// Jump straight into the prompter with the bundled demo script.
    /// Useful for first-run exploration without requiring folder selection,
    /// and as a test harness for the markdown parsing pipeline.
    func openDemoScript() {
        guard let url = Bundle.main.url(forResource: "demo-everything", withExtension: "md") else {
            userFacingError = "Demo script is missing from the app bundle."
            return
        }
        let name = url.lastPathComponent
        let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .now
        let file = ScriptFile(id: url, name: name, mtime: mtime, downloadState: .current)
        route = .prompter(file)
    }

    // MARK: - Folder adoption

    /// Track whether we currently hold an active security scope so every
    /// startAccessingSecurityScopedResource is balanced with a stop.
    private var folderAccessActive: Bool = false

    /// Called from the document picker delegate when the user selects a folder.
    /// Saves a security-scoped bookmark and spins up the watcher.
    func adoptFolder(_ url: URL) {
        // Release any prior scope before opening a new one.
        stopWatcher()

        guard url.startAccessingSecurityScopedResource() else {
            userFacingError = "Could not access the selected folder. Pick it again?"
            folderIsAccessible = false
            return
        }
        folderAccessActive = true

        do {
            try BookmarkStore.save(url)
            folderURL = url
            folderIsAccessible = true
            watcher.start(scope: url)
            route = .library
        } catch {
            // Failed to save the bookmark — release the scope we just opened.
            url.stopAccessingSecurityScopedResource()
            folderAccessActive = false
            userFacingError = "Could not save folder: \(error.localizedDescription)"
            folderIsAccessible = false
        }
    }

    // MARK: - Private

    private func resolveBookmarkAndStart() {
        let onboardingDone = Prefs.onboardingCompleted
        if !onboardingDone {
            route = .onboarding
            return
        }

        do {
            guard let url = try BookmarkStore.resolve() else {
                route = .picker
                return
            }
            guard url.startAccessingSecurityScopedResource() else {
                userFacingError = "Saved folder is no longer accessible. Pick it again."
                folderIsAccessible = false
                route = .picker
                return
            }
            folderAccessActive = true
            folderURL = url
            folderIsAccessible = true
            watcher.start(scope: url)
            route = .library
        } catch {
            userFacingError = error.localizedDescription
            folderIsAccessible = false
            route = .picker
        }
    }

    private func stopWatcher() {
        watcher.stop()
        if folderAccessActive, let url = folderURL {
            url.stopAccessingSecurityScopedResource()
            folderAccessActive = false
        }
    }
}
