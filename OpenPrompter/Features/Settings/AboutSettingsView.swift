//
//  AboutSettingsView.swift
//  OpenPrompter
//
//  "About" drill-down of the Settings overhaul (V3 Sprint item 2). Carries
//  over the old flat view's "about" section (site, source, privacy, credit
//  line) and adds two things the sprint spec called for on this page:
//    - a version / build string read from the bundle
//    - a "buy me a coffee" support link
//
//  No `PrefKey` usage here — this page is static links + bundle metadata.
//

import SwiftUI

struct AboutSettingsView: View {
    /// Marketing version + build number from the bundle (e.g. "2.0.11 (42)").
    /// `CFBundleShortVersionString` / `CFBundleVersion` resolve from
    /// `$(MARKETING_VERSION)` / `$(CURRENT_PROJECT_VERSION)` at build time.
    private var versionString: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        return "\(short) (\(build))"
    }

    var body: some View {
        Form {
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

            Section("support") {
                Link(destination: URL(string: "https://buymeacoffee.com/lelanddutcher")!) {
                    Label("buy me a coffee", systemImage: "cup.and.saucer")
                }
                Text("open prompter is free and open source. a coffee keeps the updates coming — entirely optional.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.dim)
            }

            Section("version") {
                HStack {
                    Text("version")
                        .font(.system(size: 13))
                    Spacer()
                    Text(versionString)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(Theme.muted)
                        .textSelection(.enabled)
                }
            }
        }
        .navigationTitle("about")
        .navigationBarTitleDisplayMode(.inline)
    }
}
