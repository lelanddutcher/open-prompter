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
    @State private var aggressiveStripping: Bool = Prefs.aggressiveStripping
    @State private var defaultSpeed: Double = Prefs.defaultSpeed
    @State private var defaultFont: Double = Prefs.defaultFont
    @State private var mirrorDefault: Bool = Prefs.mirrorDefault
    @State private var appearance: Prefs.Appearance = Prefs.appearance

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

                    Toggle("mirror on by default", isOn: $mirrorDefault)
                        .onChange(of: mirrorDefault) { _, new in Prefs.mirrorDefault = new }
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
