//
//  RecordingSettingsView.swift
//  OpenPrompter
//
//  Settings section for the recording feature (V2 Design 02 §"Settings UI").
//  Sits in `SettingsView` between Camera and Remote Control. Shown when
//  EITHER `labs.recording` is on OR the user has previously interacted with
//  the recording feature (we infer that from the photo-permission flag —
//  asking for photo permission is conclusive proof the user has touched
//  recording at least once).
//

import AVFoundation
import SwiftUI

struct RecordingSettingsView: View {
    /// Live audio-route monitor so the status row can show what iOS is
    /// actually picking up right now. Owned by AppState so the routing
    /// observer survives sheet presentation cycles.
    @Bindable var routeMonitor: AudioRouteMonitor

    // @AppStorage so picker changes here propagate to a foreground prompter
    // view without re-mounting the prompter.
    @AppStorage(PrefKey.recordingQuality.rawValue) private var qualityRaw: String = "high"
    @AppStorage(PrefKey.recordingFramerate.rawValue) private var framerateRaw: String = "fps30"
    @AppStorage(PrefKey.recordingAspect.rawValue) private var aspectRaw: String = "ratio9x16"
    @AppStorage(PrefKey.recordingStabilization.rawValue) private var stabilizationRaw: String = "off"
    @AppStorage(PrefKey.recordingCountdown.rawValue) private var countdownRaw: String = "three"
    @AppStorage(PrefKey.recordingIndicator.rawValue) private var indicatorRaw: String = "both"
    @AppStorage(PrefKey.recordingSaveToScriptFolder.rawValue) private var saveToScriptFolder: Bool = false

    /// Pinned mic source — port UID, "auto", or "builtin". Read live so the
    /// status row updates when route changes flip the available list.
    @State private var pinnedMic: String

    init(routeMonitor: AudioRouteMonitor) {
        self.routeMonitor = routeMonitor
        _pinnedMic = State(initialValue: Prefs.recordingMicSource ?? "builtin")
    }

    var body: some View {
        Group {
            Section("recording") {
                Picker("quality", selection: $qualityRaw) {
                    ForEach(RecordingQuality.allCases, id: \.rawValue) { q in
                        Text(q.descriptionWithStorageEstimate(framerate: framerate))
                            .tag(q.rawValue)
                    }
                }
                .pickerStyle(.menu)
                Text("standard is fine for social. high gives more headroom for editing.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.dim)

                Picker("framerate", selection: $framerateRaw) {
                    ForEach(RecordingFramerate.allCases, id: \.rawValue) { f in
                        Text(f.displayName).tag(f.rawValue)
                    }
                }
                .pickerStyle(.menu)
                Text("30 is the social-platform standard. 60 is for slow-mo in post.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.dim)

                // Aspect ratio. `availableAspects` filters by OS — 9:16 and
                // 1:1 require the iOS 26 dynamic-aspect API to land at non-
                // native crops on the iPhone front sensor, so we hide them
                // on older iOS rather than silently demoting the user's
                // choice. The other three (4:3, 16:9, open gate) work
                // everywhere via the existing largest-area fallback.
                Picker("aspect ratio", selection: $aspectRaw) {
                    ForEach(availableAspects, id: \.rawValue) { aspect in
                        Text(aspect.displayName).tag(aspect.rawValue)
                    }
                }
                .pickerStyle(.menu)
                Text("9:16 records vertically end-to-end. open gate keeps the full sensor for reframing in post. 1:1 is iphone 17 only.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.dim)

                // Microphone — status row + picker
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("current source")
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .tracking(0.5)
                            .foregroundStyle(Theme.dim)
                        Spacer()
                        Text(routeMonitor.currentRouteName.lowercased())
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(Theme.fg)
                    }
                }

                Picker("preferred input", selection: $pinnedMic) {
                    Text("auto").tag("auto")
                    Text("built-in").tag("builtin")
                    ForEach(routeMonitor.availableInputs) { input in
                        Text(input.displayName).tag(input.id)
                    }
                    // If the user pinned an accessory that isn't currently
                    // present, show it in italic so they know the pin is
                    // preserved for when it reconnects.
                    if let pinnedUID = pinIfNotConnected() {
                        Text("\(pinnedUID) (not connected)")
                            .italic()
                            .tag(pinnedMic)
                    }
                }
                .pickerStyle(.menu)
                .onChange(of: pinnedMic) { _, new in
                    Prefs.recordingMicSource = new
                }
                Text("auto lets ios pick — it can grab whatever bluetooth headset you have nearby. built-in is safer if you keep airpods on your desk.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.dim)

                Picker("stabilization", selection: $stabilizationRaw) {
                    ForEach(RecordingStabilization.allCases, id: \.rawValue) { s in
                        Text(s.displayName).tag(s.rawValue)
                    }
                }
                .pickerStyle(.menu)
                Text("off is best when the phone is mounted. standard helps for hand-held.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.dim)

                Picker("countdown", selection: $countdownRaw) {
                    ForEach(RecordingCountdown.allCases, id: \.rawValue) { c in
                        Text(c.displayName).tag(c.rawValue)
                    }
                }
                .pickerStyle(.menu)

                // Save destinations
                Toggle("photos library", isOn: .constant(true))
                    .disabled(true)
                Toggle("also save next to script", isOn: $saveToScriptFolder)
                Text("saves a copy of each recording into the same folder as your script. files app handles uploading to icloud automatically if your script lives there.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.dim)

                // Recording indicator
                Picker("recording indicator", selection: $indicatorRaw) {
                    if RecordingIndicatorPref.deviceSupportsLiveActivity {
                        Text("dynamic island only").tag("islandOnly")
                        Text("both dynamic island and tally light").tag("both")
                    }
                    Text("tally light only").tag("tallyOnly")
                }
                .pickerStyle(.menu)
                Text(RecordingIndicatorPref.deviceSupportsLiveActivity
                     ? "dynamic island shows the recording state across apps. tally light is the in-app red border."
                     : "this device doesn't support dynamic island, so only the in-app tally light is available.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.dim)
            }
        }
    }

    private var framerate: RecordingFramerate {
        RecordingFramerate(rawValue: framerateRaw) ?? .fps30
    }

    /// Aspect-ratio cases the picker should show. Hidden:
    ///   - `.ratio9x16` and `.ratio1x1` on pre-iOS-26 (the dynamic-aspect API
    ///     they need to land at a non-native crop is iOS 26+). The picker
    ///     surfaces them again automatically once the user upgrades iOS.
    /// Order: 9:16 first (the new social-share default) → 1:1 → 4:3 → 16:9
    /// → open gate. Matches the canonical UX order in the spec.
    private var availableAspects: [RecordingAspect] {
        let canonical: [RecordingAspect] = [
            .ratio9x16, .ratio1x1, .ratio4x3, .ratio16x9, .openGate
        ]
        if #available(iOS 26.0, *) {
            return canonical
        }
        return canonical.filter { !$0.requiresIOS26 }
    }

    private func pinIfNotConnected() -> String? {
        guard pinnedMic != "auto", pinnedMic != "builtin" else { return nil }
        let connected = Set(routeMonitor.availableInputs.map { $0.id })
        if connected.contains(pinnedMic) { return nil }
        return pinnedMic
    }
}
