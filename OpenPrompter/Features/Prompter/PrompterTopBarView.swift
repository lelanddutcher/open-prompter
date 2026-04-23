//
//  PrompterTopBarView.swift
//  OpenPrompter
//
//  Top-of-screen chrome. Persistent mirror state pill + reload banner +
//  back/edit buttons. Outside the mirrored stage so it's always readable.
//

import SwiftUI

struct PrompterTopBarView: View {
    @Environment(AppState.self) private var state
    var vm: PrompterViewModel

    var body: some View {
        HStack(spacing: 8) {
            Button(action: { state.closeScript() }) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 16, weight: .bold))
                    .frame(width: 40, height: 32)
                    .background(Theme.controlBg, in: Capsule())
                    .foregroundStyle(Theme.fg)
                    .overlay(Capsule().stroke(Theme.controlBorder, lineWidth: 1))
            }

            Spacer()

            if vm.mirroredHorizontal || vm.mirroredVertical {
                Pill(text: mirrorPillText, alert: true)
            } else {
                Pill(text: "Mirror OFF")
            }

            Spacer()

            if vm.reloadAvailable {
                Button(action: { Task { await vm.reload() } }) {
                    Label("Reload", systemImage: "arrow.clockwise")
                        .font(.system(size: 13, weight: .bold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Theme.accent, in: Capsule())
                        .foregroundStyle(Color.black)
                }
            }
        }
        .padding(.horizontal, 12)
    }

    private var mirrorPillText: String {
        switch (vm.mirroredHorizontal, vm.mirroredVertical) {
        case (true, true): return "MIRROR H+V"
        case (true, false): return "MIRROR H"
        case (false, true): return "MIRROR V"
        default: return "Mirror OFF"
        }
    }
}
