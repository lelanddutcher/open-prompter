//
//  LabsSettingsView.swift
//  OpenPrompter
//
//  "Labs" drill-down of the Settings overhaul (V3 Sprint item 2). Holds the
//  opt-in master toggles for in-progress features PLUS every DEBUG-only
//  developer row that used to live at the bottom of the flat `SettingsView`:
//    - master toggles: bluetooth remote, camera style, recording, on-device
//      format, iOS 26 speech engine
//    - on-device Format availability diagnostics
//    - #if DEBUG: recording self-test, voice-sample replay, iOS 26 speech
//      engine toggle, wide-front preview angle-cycler
//
//  All of this is a mechanical move out of the flat view. No `PrefKey`
//  changes — the flags keep their DEBUG-on / Release-off defaults, and the
//  sub-views/harnesses they surface (Camera & recording, Bluetooth remote)
//  are reached from `SettingsHomeView`, which re-reads the same flags.
//
//  Note: the DEBUG "learn my remote" capture tool is NOT duplicated here — it
//  is structurally part of `RemoteControlSettingsView` (reused unchanged) and
//  stays reachable from the Bluetooth remote drill-down.
//

import SwiftUI

struct LabsSettingsView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

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
    /// On-device Format (V3 item C). DEBUG-on / Release-off until it graduates.
    @AppStorage(PrefKey.labsFormat.rawValue) private var labsFormat: Bool = {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }()
    /// iOS 26 SpeechAnalyzer voice-tracking engine (V3 item B, Slice B).
    /// Surfaced only behind `#if DEBUG` + `if #available(iOS 26)` — a no-op on
    /// earlier OSes.
    @AppStorage(PrefKey.voiceUseSpeechAnalyzer.rawValue) private var voiceUseSpeechAnalyzer: Bool = {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }()

    #if DEBUG
    /// Self-test result alert state. Behind `#if DEBUG` so production builds
    /// carry no overhead from this surface.
    @State private var selfTestRunning: Bool = false
    @State private var selfTestAlertTitle: String = ""
    @State private var selfTestAlertMessage: String = ""
    @State private var selfTestAlertVisible: Bool = false

    /// Mirrors `OrientationPolicy.debugWideFrontPreviewAngleOverride` so the
    /// angle-cycler row re-renders its label when tapped. `nil` = ship the
    /// UNVERIFIED hypothesis. See V3 Design 06 §5.
    @State private var wideFrontPreviewAngleOverride: CGFloat? =
        OrientationPolicy.debugWideFrontPreviewAngleOverride

    /// On-prompter voice-follow diagnostics overlay. Plain UserDefaults key
    /// (not a PrefKey) — a DEBUG diagnostic surface, not a user preference.
    /// Default ON so dogfood builds show the readout unless opted out.
    @AppStorage("debug.voice.followDiagnostics")
    private var voiceFollowDiagnostics: Bool = true
    #endif

    /// Live availability of the on-device Format model, one-lined for the Labs
    /// diagnostics row. Resolves the real formatter on iOS 26+, the noop below —
    /// so the summary reflects the actual device state.
    private var formatAvailabilitySummary: String {
        ScriptFormatterFactory.make().availability.diagnosticSummary
    }

    var body: some View {
        Form {
            // Labs — opt-in toggles for in-progress features. Each flag is a
            // single toggle with copy explaining what's still being built.
            Section("labs") {
                Toggle("bluetooth remote", isOn: $labsBluetoothRemote)
                Text("in-progress: keyboard, presenter, and media-key control with user-remappable bindings. surface a remote control section above when on.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.dim)

                Toggle("camera style", isOn: $labsCameraStyle)
                Text("camera composition picker (off / picture-in-picture). tap the pip tile to expand to full-screen preview.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.dim)

                Toggle("recording", isOn: $labsRecording)
                Text("in-progress: front-camera recording with quality + framerate + mic source pickers, dynamic island live activity, and save-to-photos / save-next-to-script destinations. surface a recording section above when on.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.dim)

                Toggle("on-device format", isOn: $labsFormat)
                Text("in-progress: a ✨ Format button in the script editor that runs the on-device apple model to tidy spacing, dividers, and emphasis — without changing your words. confirm-before-apply + undo. requires apple intelligence (iphone 15 pro / 16 / 17 family).")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.dim)
                // Availability diagnostics — tells the founder WHY the Format
                // button is hidden on a given device without guessing. Reads
                // the live formatter availability.
                HStack(spacing: 8) {
                    Circle()
                        .fill(formatAvailabilitySummary == "available" ? Theme.green : Theme.ghost)
                        .frame(width: 8, height: 8)
                    Text("format model: \(formatAvailabilitySummary)")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Theme.muted)
                    Spacer()
                }

                #if DEBUG
                // Recording self-test harness — DEBUG only. Reads back the
                // most recent .mov in Documents/Recordings/ and writes
                // Documents/SelfTest.json so the orchestrator can pull it via
                // devicectl. See RecordingSelfTest.swift.
                selfTestRow

                // Voice-tracking replay harness — DEBUG only. Plays the
                // bundled sample audio through SFSpeechRecognizer so we can
                // iterate on alignment / scroll math without reading aloud.
                voiceSampleReplayRow

                // iOS 26 SpeechAnalyzer voice engine (V3 item B). Hidden
                // entirely on iOS < 26 (the toggle would be a no-op).
                speechAnalyzerEngineRow

                // Wide-front preview angle-cycler — DEBUG only. The closed-loop
                // tool for confirming the iPhone-13-Pro-class preview angle
                // (GitHub #2 / V3 Design 06 §5). Cycles the .wideFrontSensor
                // override nil→0→90→180→270→nil. Only affects devices
                // classified .wideFrontSensor; on the founder's iPhone 17
                // (.squareFrontSensor) it's a no-op.
                wideFrontPreviewAngleRow

                // Voice-follow diagnostics overlay toggle — DEBUG only.
                voiceFollowDiagnosticsRow
                #endif
            }
        }
        .navigationTitle("labs")
        .navigationBarTitleDisplayMode(.inline)
        #if DEBUG
        .alert(selfTestAlertTitle,
               isPresented: $selfTestAlertVisible,
               actions: { Button("OK", role: .cancel) {} },
               message: { Text(selfTestAlertMessage) })
        #endif
    }

    #if DEBUG
    /// "Run Recording Self-Test" row + helper button. Reads the most-recent
    /// .mov from `Documents/Recordings/`, runs assertions, writes the JSON
    /// report to `Documents/SelfTest.json`, and surfaces a pass/fail summary.
    /// The orchestrator pulls the JSON via `xcrun devicectl`.
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

    /// Wide-front (iPhone-13-Pro-class) preview angle-cycler. GitHub #2: the
    /// 4:3-front-sensor preview renders rotated 90° and locked, and we don't
    /// own the device to confirm the corrective angle. This row cycles the
    /// `.wideFrontSensor` preview override through nil→0→90→180→270→nil so the
    /// #2 reporter can find the upright value live, then we bake it into
    /// `OrientationPolicy.PREVIEW_ANGLE_WIDE_FRONT_UNVERIFIED`. No-op on
    /// `.squareFrontSensor` devices (the founder's iPhone 17).
    @ViewBuilder
    private var wideFrontPreviewAngleRow: some View {
        let hint = OrientationPolicy.DeviceGenerationHint.from(
            modelIdentifier: OrientationPolicy.currentDeviceModelIdentifier
        )
        Button {
            wideFrontPreviewAngleOverride = OrientationPolicy.cycleDebugWideFrontPreviewAngle()
        } label: {
            HStack {
                Text("wide-front preview angle")
                Spacer()
                Text(wideFrontPreviewAngleOverride.map { "\(Int($0))°" } ?? "hypothesis (270°)")
                    .foregroundStyle(Theme.dim)
            }
        }
        Text("debug only. github #2: iphone 13 pro (4:3 front sensor) preview is rotated 90° + locked. cycle the override to find the upright angle on that device class, then confirm it. this device is classified '\(hint.rawValue)'\(hint == .wideFrontSensor ? "" : " — cycling is a no-op here").")
            .font(.system(size: 12))
            .foregroundStyle(Theme.dim)
    }

    /// Voice-follow diagnostics overlay toggle (DEBUG). Gates the three-line
    /// on-prompter readout (match verdict / aim path / chase state) used for
    /// on-device diagnosis of the voice-follow pipeline. Default ON; flip off
    /// for a clean prompter screen.
    @ViewBuilder
    private var voiceFollowDiagnosticsRow: some View {
        Toggle("voice-follow diagnostics", isOn: $voiceFollowDiagnostics)
        Text("debug only. shows the three-line match/aim/chase readout on the prompter while voice tracking is active — the tool used to diagnose the read-line stranding fix. harmless to leave on; never ships in release builds.")
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

    /// Voice-tracking replay harness — plays the bundled audio file
    /// (`voice-tracking-test-sample.m4a`) through `SFSpeechRecognizer` so the
    /// alignment + scroll pipeline gets exercised against a known recording.
    /// The user must have a script open AND have tapped VOICE at least once
    /// (so the tracker has a tokenized script to align against). The current
    /// sample was recorded against the `beta premiere color testing` script —
    /// tracking against any other script produces mostly no-match results
    /// (still useful for observing scroll behavior under noise).
    private var voiceSampleReplayRow: some View {
        Button {
            replayVoiceSample()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "waveform.badge.magnifyingglass")
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text("replay voice sample")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.fg)
                    Text("Plays bundled audio through SFSpeechRecognizer. Open the 'beta premiere color testing' script and tap VOICE briefly first to load the aligner.")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.dim)
                }
            }
        }
    }

    /// iOS 26 SpeechAnalyzer voice-tracking engine toggle (V3 item B, Slice B).
    /// Only rendered on iOS 26+ — on earlier OSes the analyzer backend doesn't
    /// exist and the toggle would be a no-op, so we hide it entirely. Copy
    /// notes it improves recognition of names + jargon and falls back to the
    /// classic engine when the on-device model isn't ready.
    @ViewBuilder
    private var speechAnalyzerEngineRow: some View {
        if #available(iOS 26, *) {
            Toggle("use iOS 26 speech engine (beta)", isOn: $voiceUseSpeechAnalyzer)
            Text("in-progress: routes voice tracking through the iOS 26 SpeechAnalyzer engine, which biases toward the script's distinctive names + jargon for tighter matches. falls back to the classic engine automatically when the on-device model isn't installed yet.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.dim)
        }
    }

    private func replayVoiceSample() {
        guard let url = Bundle.main.url(
            forResource: "voice-tracking-test-sample",
            withExtension: "m4a"
        ) else {
            selfTestAlertTitle = "voice sample missing"
            selfTestAlertMessage = "voice-tracking-test-sample.m4a not in bundle. Run xcodegen + rebuild."
            selfTestAlertVisible = true
            return
        }
        // Stop any live tracking so we don't have two recognizers.
        appState.voiceTracker.stop()
        if appState.voiceTracker.startWithSampleAudio(url: url) {
            dismiss()
        } else {
            selfTestAlertTitle = "voice replay failed"
            selfTestAlertMessage = "Open a script first and tap VOICE briefly so the aligner gets loaded with the script's tokens, then re-try."
            selfTestAlertVisible = true
        }
    }
    #endif
}
