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
                }
            }
            .navigationTitle("settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
