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

    // Fallback short-date formatter for files modified more than a week ago,
    // where relative phrasing ("2w AGO") is less scannable than "APR 21".
    private static let shortDate: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
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

            // Sync status chip — shows when the file on disk was last
            // edited (via its mtime), so the author can confirm an iCloud
            // sync from their Mac has arrived. `reloadAvailable` flips the
            // chip amber with a "RELOAD" action when the watcher sees a
            // newer mtime than what's currently loaded in the prompter.
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
        } else if let mtime = vm.fileMTime {
            // File has an on-disk modification date — show when the author
            // last saved it. This is what the user glances at to confirm
            // a freshly-edited version has landed from iCloud.
            LiveChip(status: .live, label: "EDITED · \(syncLabel(for: mtime))")
        } else if vm.isLoading {
            LiveChip(status: .syncing, label: "LOADING…", pulse: true)
        } else {
            // Bundled demo or other file with no mtime metadata — the
            // "last edited" story doesn't apply, so fall back to a neutral
            // ready state that identifies the file without lying about time.
            LiveChip(status: .live, label: "READY · \(vm.file.displayName.uppercased())")
        }
    }

    /// Human-readable "time since edit" for the green chip.
    /// - < 15s: "NOW"
    /// - < 7 days: RelativeDateTimeFormatter abbreviated ("30S AGO", "12M AGO", "3H AGO", "2D AGO")
    /// - >= 7 days: short date ("APR 21") — relative phrasing stops being scannable past a week
    private func syncLabel(for mtime: Date) -> String {
        let delta = now.timeIntervalSince(mtime)
        if delta < 15 { return "NOW" }
        let week: TimeInterval = 7 * 24 * 60 * 60
        if delta >= week {
            return Self.shortDate.string(from: mtime).uppercased()
        }
        return Self.relative
            .localizedString(for: mtime, relativeTo: now)
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
