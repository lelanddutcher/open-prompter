//
//  ReadingSettingsView.swift
//  OpenPrompter
//
//  "Reading" drill-down of the Settings overhaul (V3 Sprint item 2). Gathers
//  every setting that shapes how a script READS on the prompter:
//    - appearance (dark / light / system)
//    - parsing (aggressive markdown stripping + hide stage directions)
//    - defaults (starting speed + font size)
//    - mirror (horizontal / vertical flip defaults)
//    - prompter font
//
//  These `Section`s are a mechanical cut/paste out of the old flat
//  `SettingsView`. No `PrefKey` changes — the local `@State` seeds still read
//  from `Prefs` and write back on change, byte-identical to before.
//

import SwiftUI

struct ReadingSettingsView: View {
    @State private var aggressiveStripping: Bool = Prefs.aggressiveStripping
    @State private var stripStageDirections: Bool = Prefs.stripStageDirections
    @State private var defaultSpeed: Double = Prefs.defaultSpeed
    @State private var defaultFont: Double = Prefs.defaultFont
    @State private var hMirrorDefault: Bool = Prefs.hMirrorDefault
    @State private var vMirrorDefault: Bool = Prefs.vMirrorDefault
    @State private var appearance: Prefs.Appearance = Prefs.appearance
    @State private var prompterFont: String = Prefs.prompterFont.rawValue
    @State private var showReadingProgressBar: Bool = Prefs.showReadingProgressBar
    @State private var voiceFollowSpeed: Double = Prefs.voiceFollowSpeedFactor

    var body: some View {
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

                Toggle("hide stage directions", isOn: $stripStageDirections)
                    .disabled(!aggressiveStripping)
                    .onChange(of: stripStageDirections) { _, new in
                        Prefs.stripStageDirections = new
                    }
                Text("also hides camera cues and stage directions like [Cut to: …], (beat), and ALL-CAPS shot notes (WIDE SHOT, CUT TO:) from the reading flow. your file is never changed.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.dim)
            }

            Section("progress") {
                Toggle(isOn: $showReadingProgressBar) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("reading-progress bar")
                        Text("thin green line down the left edge showing how far into the script you are")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.dim)
                    }
                }
                .onChange(of: showReadingProgressBar) { _, new in
                    Prefs.showReadingProgressBar = new
                }
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

            Section("voice following") {
                HStack {
                    Text("chase speed")
                    Spacer()
                    Text("\(Int(voiceFollowSpeed))×")
                }
                Slider(value: $voiceFollowSpeed, in: 3...16, step: 1)
                    .onChange(of: voiceFollowSpeed) { _, new in Prefs.voiceFollowSpeedFactor = new }
                Text("caps how fast the prompter chases your voice, as a multiple of font size per second (6× ≈ 4 lines/sec). when the word you're reading falls below mid-screen, a catch-up floor kicks in at up to 60% of this speed so the scroll recovers briskly. applies live to an open prompter.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.dim)
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
        }
        .navigationTitle("reading")
        .navigationBarTitleDisplayMode(.inline)
    }
}
