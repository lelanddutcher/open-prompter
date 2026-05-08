//
//  PrompterControlsView.swift
//  OpenPrompter
//
//  Bottom control strip. Monospaced labels, tight tracking, Rig Gray
//  surfaces with hairline borders — per design-language.md §7.3, §7.6.
//  Primary play = Open Green fill with ink-black glyph. Mirror ON swaps
//  to Mirror Red and is the only place red appears.
//

import SwiftUI

struct PrompterControlsView: View {
    var vm: PrompterViewModel
    /// Voice tracker injected from `AppState` so the right half of the
    /// play row can read `.isActive` and re-render when the tracker
    /// flips. Action handling lives in the parent (`TeleprompterView`)
    /// so the orchestration logic — permission flow, mutual exclusion
    /// with PLAY — has access to both `vm` and `appState`.
    var voiceTracker: VoiceTracker
    var onPlayTap: () -> Void
    var onVoiceTap: () -> Void

    private let rowHeight: CGFloat = 40
    private let buttonHeight: CGFloat = 44
    private let iconButton: CGFloat = 40
    private let corner: CGFloat = 10

    var body: some View {
        VStack(spacing: 6) {
            // Voice-tracking HUD strip — only renders when voice is
            // active. Sits ABOVE the play/voice row, no blur, hides
            // automatically with the rest of the bottom chrome on
            // focus mode (the parent VStack handles opacity).
            VoiceTrackingHUDStrip(tracker: voiceTracker)
            // Row 1 — primary action. PLAY (left half) and VOICE (right
            // half) are mutually exclusive; tapping either stops the
            // other (orchestration handled by parent's onPlayTap /
            // onVoiceTap closures).
            HStack(spacing: 6) {
                Button(action: onPlayTap) {
                    HStack(spacing: 6) {
                        Image(systemName: vm.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 12, weight: .bold))
                        Text(vm.isPlaying ? "PAUSE" : "PLAY")
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                            .tracking(1.0)
                    }
                    .frame(height: buttonHeight)
                    .frame(maxWidth: .infinity)
                    // 2.0.10: when the user taps the prompter to toggle
                    // play while voice tracking is active, the VM sets
                    // playTapConflict for ~0.4s. Flash the button red
                    // (background + border) in that window so the user
                    // sees the conflict instead of silently no-oping.
                    .background(
                        vm.playTapConflict
                            ? Color(red: 0.78, green: 0.20, blue: 0.20)
                            : (vm.isPlaying ? Theme.green : Theme.surface)
                    )
                    .foregroundStyle(
                        vm.playTapConflict
                            ? Color.white
                            : (vm.isPlaying ? Color(red: 0.03, green: 0.09, blue: 0.05) : Theme.fg)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: corner, style: .continuous)
                            .stroke(
                                vm.playTapConflict
                                    ? Color(red: 1.0, green: 0.30, blue: 0.30)
                                    : (vm.isPlaying ? Theme.green : Theme.border),
                                lineWidth: vm.playTapConflict ? 1.5 : 1
                            )
                    )
                    .animation(.easeInOut(duration: 0.12), value: vm.playTapConflict)
                }

                Button(action: onVoiceTap) {
                    HStack(spacing: 6) {
                        Image(systemName: voiceTracker.isActive ? "waveform.circle.fill" : "waveform")
                            .font(.system(size: 12, weight: .bold))
                        Text(voiceTracker.isActive ? "TRACK" : "VOICE")
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                            .tracking(1.0)
                    }
                    .frame(height: buttonHeight)
                    .frame(maxWidth: .infinity)
                    .background(voiceTracker.isActive ? Theme.green : Theme.surface)
                    .foregroundStyle(voiceTracker.isActive ? Color(red: 0.03, green: 0.09, blue: 0.05) : Theme.fg)
                    .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: corner, style: .continuous)
                            .stroke(voiceTracker.isActive ? Theme.green : Theme.border, lineWidth: 1)
                    )
                }
                .accessibilityLabel(voiceTracker.isActive ? "Stop voice tracking" : "Start voice tracking")
            }

            // Row 2 — speed
            HStack(spacing: 10) {
                Text("SPEED \(Int(vm.speed))")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .tracking(1.0)
                    .foregroundStyle(Theme.muted)
                    .frame(width: 80, alignment: .leading)
                Slider(
                    value: Binding(get: { vm.speed }, set: { vm.setSpeed($0) }),
                    in: 5...200,
                    step: 5
                )
                .tint(Theme.green)
            }
            .padding(.horizontal, 12)
            .frame(height: rowHeight)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: corner, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .stroke(Theme.border, lineWidth: 1)
            )

            // Row 3 — font + focus + jump
            HStack(spacing: 8) {
                Text("FONT \(Int(vm.fontSize))")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .tracking(1.0)
                    .foregroundStyle(Theme.muted)
                    .frame(width: 72, alignment: .leading)
                Slider(
                    value: Binding(get: { vm.fontSize }, set: { vm.setFontSize($0) }),
                    in: 16...160,
                    step: 2
                )
                .tint(Theme.green)

                Button(action: { vm.toggleFocus() }) {
                    Image(systemName: "eye.slash")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: iconButton, height: iconButton)
                        .background(Theme.surface2, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .foregroundStyle(Theme.fg)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(Theme.border, lineWidth: 1)
                        )
                }
                .accessibilityLabel("Hide controls")

                Button(action: { vm.jumpToStart() }) {
                    Image(systemName: "arrow.uturn.up")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: iconButton, height: iconButton)
                        .background(Theme.surface2, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .foregroundStyle(Theme.fg)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(Theme.border, lineWidth: 1)
                        )
                }
                .accessibilityLabel("Jump to start")
            }
            .padding(.horizontal, 8)
            .frame(height: buttonHeight + 4)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: corner, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .stroke(Theme.border, lineWidth: 1)
            )
        }
        .padding(.horizontal, 10)
    }
}
