//
//  SettingsView.swift
//  OpenPrompter
//
//  Minimal settings. Toggle aggressive markdown stripping, default speed
//  and font, credits. No account, no sync toggles — there's nothing to sync.
//

import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var appState
    @State private var aggressiveStripping: Bool = Prefs.aggressiveStripping
    @State private var defaultSpeed: Double = Prefs.defaultSpeed
    @State private var defaultFont: Double = Prefs.defaultFont
    @State private var hMirrorDefault: Bool = Prefs.hMirrorDefault
    @State private var vMirrorDefault: Bool = Prefs.vMirrorDefault
    @State private var appearance: Prefs.Appearance = Prefs.appearance
    @State private var prompterFont: String = Prefs.prompterFont.rawValue

    /// Labs entries gate in-progress features. Default is DEBUG-only on, see
    /// `Prefs.swift` for the per-build default. The Labs section at the
    /// bottom of Settings exposes each flag with a master toggle.
    @AppStorage(PrefKey.labsBluetoothRemote.rawValue) private var labsBluetoothRemote: Bool = {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }()
    @AppStorage(PrefKey.labsCameraStyle.rawValue) private var labsCameraStyle: Bool = {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }()
    @AppStorage(PrefKey.labsRecording.rawValue) private var labsRecording: Bool = {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }()
    /// Read live so the camera section can decide whether to render once
    /// the user has picked a non-`.off` mode (regardless of the Labs flag).
    @AppStorage(PrefKey.cameraStyle.rawValue) private var cameraStyleRaw: String = "off"

    #if DEBUG
    /// Self-test result alert state. Lives behind `#if DEBUG` so production
    /// builds carry no overhead from this surface.
    @State private var selfTestRunning: Bool = false
    @State private var selfTestAlertTitle: String = ""
    @State private var selfTestAlertMessage: String = ""
    @State private var selfTestAlertVisible: Bool = false
    #endif

    var body: some View {
        NavigationStack {
            Form {
                Section("appearance") {
                    Picker("mode", selection: $appearance) {
                        Text("dark").tag(Prefs.Appearance.dark)
                        Text("light").tag(Prefs.Appearance.light)
                        Text("system").tag(Prefs.Appearance.system)
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: appearance) { _, new in
                        Prefs.appearance = new
                    }
                    Text("dark is best behind teleprompter glass. light is for the library and settings.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.dim)
                }

                Section("parsing") {
                    Toggle("aggressive markdown stripping", isOn: $aggressiveStripping)
                        .onChange(of: aggressiveStripping) { _, new in
                            Prefs.aggressiveStripping = new
                        }
                    Text("strips frontmatter, callouts, footnotes, and visual-direction brackets like [B-roll: …]. turn off if you want to see your cues on camera.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.dim)
                }

                Section("defaults") {
                    HStack {
                        Text("speed")
                        Spacer()
                        Text("\(Int(defaultSpeed))")
                    }
                    Slider(value: $defaultSpeed, in: 5...200, step: 5)
                        .onChange(of: defaultSpeed) { _, new in Prefs.defaultSpeed = new }

                    HStack {
                        Text("font size")
                        Spacer()
                        Text("\(Int(defaultFont))")
                    }
                    Slider(value: $defaultFont, in: 32...160, step: 4)
                        .onChange(of: defaultFont) { _, new in Prefs.defaultFont = new }
                }

                Section("mirror") {
                    Toggle(isOn: $hMirrorDefault) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("horizontal flip")
                            Text("reverse left ↔ right (for beam-splitter rigs)")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.dim)
                        }
                    }
                    .onChange(of: hMirrorDefault) { _, new in Prefs.hMirrorDefault = new }

                    Toggle(isOn: $vMirrorDefault) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("vertical flip")
                            Text("reverse top ↔ bottom (for upside-down or periscope rigs)")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.dim)
                        }
                    }
                    .onChange(of: vMirrorDefault) { _, new in Prefs.vMirrorDefault = new }

                    Text("the in-prompter mirror chip flips horizontal. flip both for a 180° rotation.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.dim)
                }

                Section("prompter font") {
                    Picker("font", selection: $prompterFont) {
                        ForEach(PrompterFont.allCases) { font in
                            Text(font.displayName).tag(font.rawValue)
                        }
                    }
                    .pickerStyle(.menu)
                    .onChange(of: prompterFont) { _, new in
                        if let value = PrompterFont(rawValue: new) {
                            Prefs.prompterFont = value
                        }
                    }
                    Text(PrompterFont(rawValue: prompterFont)?.designerNote ?? "")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.dim)
                }

                // Camera Style + PiP (V2 Feature 1). Hidden from users who
                // never opted in — visible when EITHER the Labs flag is on
                // OR the user already picked a non-`.off` style. That way a
                // user who turned on PiP via the chip never loses the
                // settings entry, even if a future build flips Labs off.
                if labsCameraStyle || cameraStyleRaw != "off" {
                    CameraSettingsView(recordingState: appState.recordingState)
                }

                // Recording (Features 2 + 4). Behind the labs flag and only
                // surfaces when the user has the recording feature enabled.
                // Settings opens from the library — outside any prompter
                // session — so the route monitor needs to be started here so
                // the "current source" row reflects what iOS picks up right
                // now, not whatever was active the last time the prompter
                // was on screen.
                if labsRecording {
                    RecordingSettingsView(routeMonitor: appState.audioRouteMonitor)
                        .onAppear { appState.audioRouteMonitor.start() }
                }

                // Remote Control (Feature 7). Behind the labs flag — shipped
                // off by default in Release until the feature graduates from
                // Labs. The whole subview lives in RemoteControlSettingsView.
                if labsBluetoothRemote {
                    RemoteControlSettingsView(
                        bindings: appState.remoteBindings,
                        monitor: appState.keyboardMonitor
                    )
                }

                Section("about") {
                    Link(destination: URL(string: "https://openprompter.app")!) {
                        Label("openprompter.app", systemImage: "safari")
                    }
                    Link(destination: URL(string: "https://github.com/lelanddutcher/open-prompter")!) {
                        Label("source on github", systemImage: "chevron.left.forwardslash.chevron.right")
                    }
                    Link(destination: URL(string: "https://openprompter.app/privacy")!) {
                        Label("privacy policy", systemImage: "hand.raised")
                    }
                    Text("open prompter · MIT · made by @lelanddutcher")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.dim)
                }

                // Labs — opt-in toggles for in-progress features. First entry
                // is Bluetooth remote (Feature 7). Pattern: each flag is a
                // single toggle with copy explaining what's still being built.
                Section("labs") {
                    Toggle("bluetooth remote", isOn: $labsBluetoothRemote)
                    Text("in-progress: keyboard, presenter, and media-key control with user-remappable bindings. surface a remote control section above when on.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.dim)

                    Toggle("camera style", isOn: $labsCameraStyle)
                    Text("in-progress: three-mode camera composition picker (off, picture-in-picture, behind text) with a draggable corner-snapping pip tile. surface a camera section above when on.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.dim)

                    Toggle("recording", isOn: $labsRecording)
                    Text("in-progress: front-camera recording with quality + framerate + mic source pickers, dynamic island live activity, and save-to-photos / save-next-to-script destinations. surface a recording section above when on.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.dim)

                    #if DEBUG
                    // Recording self-test harness — DEBUG only. Reads back
                    // the most recent .mov in Documents/Recordings/ and
                    // writes Documents/SelfTest.json so the orchestrator
                    // can pull it via devicectl. See RecordingSelfTest.swift.
                    selfTestRow
                    #endif
                }
            }
            .navigationTitle("settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
            }
            #if DEBUG
            .alert(selfTestAlertTitle,
                   isPresented: $selfTestAlertVisible,
                   actions: { Button("OK", role: .cancel) {} },
                   message: { Text(selfTestAlertMessage) })
            #endif
        }
    }

    #if DEBUG
    /// "Run Recording Self-Test" row + helper button. Reads the most-recent
    /// .mov from `Documents/Recordings/`, runs assertions, writes the JSON
    /// report to `Documents/SelfTest.json`, and surfaces a pass/fail
    /// summary. The orchestrator pulls the JSON via `xcrun devicectl`.
    @ViewBuilder
    private var selfTestRow: some View {
        Button {
            runSelfTest()
        } label: {
            HStack {
                Text(selfTestRunning ? "running self-test…" : "run recording self-test")
                Spacer()
                if selfTestRunning {
                    ProgressView()
                }
            }
        }
        .disabled(selfTestRunning)
        Text("debug only. analyzes the most recent recording in Documents/Recordings/, writes Documents/SelfTest.json with dimensions / duration / bitrate / frame brightness assertions. record a take first, then tap.")
            .font(.system(size: 12))
            .foregroundStyle(Theme.dim)
    }

    private func runSelfTest() {
        selfTestRunning = true
        Task { @MainActor in
            defer { selfTestRunning = false }
            guard let result = await RecordingSelfTest.runOnMostRecentRecording() else {
                selfTestAlertTitle = "no recording found"
                selfTestAlertMessage = "Documents/Recordings/ is empty. record a take in the prompter, then run the self-test."
                selfTestAlertVisible = true
                return
            }
            _ = RecordingSelfTest.writeReport(result)

            let passed = result.assertions.filter { $0.passed }.count
            let failed = result.assertions.filter { !$0.passed }
            let summaryHeader = "\(passed)/\(result.assertions.count) checks passed · \(result.recordingName)"
            if failed.isEmpty {
                selfTestAlertTitle = "self-test passed"
                selfTestAlertMessage = summaryHeader + "\n\n" +
                    "dims \(result.videoWidth)×\(result.videoHeight) · " +
                    String(format: "%.2f s", result.durationSeconds) + " · " +
                    String(format: "%.0f Mbps", Double(result.computedBitrateBps) / 1_000_000) + " · " +
                    String(format: "%.1f fps", result.nominalFrameRate) + "\n\n" +
                    "JSON: Documents/SelfTest.json"
            } else {
                selfTestAlertTitle = "self-test: \(failed.count) failed"
                let failureLines = failed.prefix(5).map { "✗ \($0.name)\n  \($0.detail)" }.joined(separator: "\n\n")
                selfTestAlertMessage = summaryHeader + "\n\n" + failureLines + "\n\nfull JSON: Documents/SelfTest.json"
            }
            selfTestAlertVisible = true
        }
    }
    #endif
}
