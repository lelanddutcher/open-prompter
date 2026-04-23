//
//  PrompterTopBarView.swift
//  OpenPrompter
//
//  Top chrome. Back button, mirror-state pill, sync/reload status, edit
//  button. Lives outside the mirrored stage so it stays legible regardless
//  of flip state. Styling follows design-language.md §7.2–§7.3.
//

import SwiftUI

struct PrompterTopBarView: View {
    @Environment(AppState.self) private var state
    var vm: PrompterViewModel
    @State private var showEditor: Bool = false
    @State private var now: Date = .now

    // Relative-time formatter for the sync chip.
    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    var body: some View {
        HStack(spacing: 8) {
            Button(action: { state.closeScript() }) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 13, weight: .bold))
                    .frame(width: 36, height: 32)
                    .background(Theme.surface, in: Capsule())
                    .foregroundStyle(Theme.fg)
                    .overlay(Capsule().stroke(Theme.border, lineWidth: 1))
            }

            // Sync status chip — shows last time the script was loaded
            // from disk. `reloadAvailable` flips it to an actionable
            // button that triggers the reparse.
            syncChip

            Spacer(minLength: 6)

            if vm.mirroredHorizontal || vm.mirroredVertical {
                Pill(text: mirrorPillText, alert: true)
            } else {
                Pill(text: "MIRROR OFF")
            }

            Spacer(minLength: 6)

            Button(action: { showEditor = true }) {
                Image(systemName: "pencil")
                    .font(.system(size: 13, weight: .bold))
                    .frame(width: 36, height: 32)
                    .background(Theme.surface, in: Capsule())
                    .foregroundStyle(Theme.fg)
                    .overlay(Capsule().stroke(Theme.border, lineWidth: 1))
            }
            .accessibilityLabel("Edit script")
        }
        .padding(.horizontal, 10)
        .sheet(isPresented: $showEditor) {
            ScriptEditorSheet(
                file: vm.file,
                cachedSource: vm.rawText.isEmpty ? nil : vm.rawText,
                initialOffset: vm.sourceOffsetForCurrentView(),
                onSaved: {
                    Task { await vm.reload() }
                }
            )
        }
        // Refresh the "x min ago" label once a minute while visible.
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                now = .now
            }
        }
    }

    @ViewBuilder
    private var syncChip: some View {
        if vm.reloadAvailable {
            // Upstream changed — offer to pull the new version.
            Button(action: { Task { await vm.reload() } }) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(Theme.amber)
                        .frame(width: 6, height: 6)
                        .shadow(color: Theme.amber.opacity(0.85), radius: 3)
                    Text("RELOAD")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .tracking(0.8)
                        .foregroundStyle(Theme.amber)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Theme.surface, in: Capsule())
                .overlay(Capsule().stroke(Theme.amber.opacity(0.6), lineWidth: 1))
            }
        } else if let synced = vm.lastSyncedAt {
            LiveChip(status: .live, label: "SYNCED · \(syncLabel(for: synced))")
        } else if vm.isLoading {
            LiveChip(status: .syncing, label: "LOADING…", pulse: true)
        }
    }

    private func syncLabel(for synced: Date) -> String {
        let delta = now.timeIntervalSince(synced)
        if delta < 15 { return "NOW" }
        return Self.relative
            .localizedString(for: synced, relativeTo: now)
            .uppercased()
    }

    private var mirrorPillText: String {
        switch (vm.mirroredHorizontal, vm.mirroredVertical) {
        case (true, true): return "MIRROR H+V"
        case (true, false): return "MIRROR H"
        case (false, true): return "MIRROR V"
        default: return "MIRROR OFF"
        }
    }
}
