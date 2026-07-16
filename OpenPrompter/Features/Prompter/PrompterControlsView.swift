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
    private let iconButton: CGFloat = 44
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
                    // 2.0.10: when the user taps the prompter to toggle play
                    // while voice tracking is active, the VM sets
                    // playTapConflict for ~0.4s — flash the glass red in that
                    // window so the tap isn't a silent no-op. Active PLAY reads
                    // as green-tinted glass; the pause glyph + label carry state.
                    .foregroundStyle(
                        vm.playTapConflict
                            ? Color.white
                            : (vm.isPlaying ? Color(red: 0.03, green: 0.09, blue: 0.05) : Theme.fg)
                    )
                    .glassSurface(
                        in: RoundedRectangle(cornerRadius: corner, style: .continuous),
                        tint: vm.playTapConflict
                            ? Color(red: 0.82, green: 0.22, blue: 0.22)
                            : (vm.isPlaying ? Theme.green : nil)
                    )
                    .animation(.easeInOut(duration: 0.12), value: vm.playTapConflict)
                    .animation(.easeInOut(duration: 0.12), value: vm.isPlaying)
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
                    .foregroundStyle(voiceTracker.isActive ? Color(red: 0.03, green: 0.09, blue: 0.05) : Theme.fg)
                    .glassSurface(
                        in: RoundedRectangle(cornerRadius: corner, style: .continuous),
                        tint: voiceTracker.isActive ? Theme.green : nil
                    )
                    .animation(.easeInOut(duration: 0.12), value: voiceTracker.isActive)
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
            .glassSurface(in: RoundedRectangle(cornerRadius: corner, style: .continuous), interactive: false)

            // Row 3 — font + focus + jump. Spacing (10), label width (80),
            // and horizontal padding (12) match Row 2 exactly so the SPEED
            // and FONT sliders start at the same x and line up. The two
            // trailing icon buttons are plain 44×44 tap targets (HIG minimum,
            // via `iconButton`) — NO per-button glass, because they sit on
            // this row's own glass card and glass-over-glass reads muddy
            // (Apple HIG). contentShape keeps the full 44×44 tappable.
            HStack(spacing: 10) {
                Text("FONT \(Int(vm.fontSize))")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .tracking(1.0)
                    .foregroundStyle(Theme.muted)
                    .frame(width: 80, alignment: .leading)
                Slider(
                    value: Binding(get: { vm.fontSize }, set: { vm.setFontSize($0) }),
                    in: 16...160,
                    step: 2
                )
                .tint(Theme.green)

                Button(action: { vm.toggleFocus() }) {
                    Image(systemName: "eye.slash")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.fg)
                        .frame(width: iconButton, height: iconButton)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Hide controls")

                Button(action: { vm.jumpToStart() }) {
                    Image(systemName: "arrow.uturn.up")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.fg)
                        .frame(width: iconButton, height: iconButton)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Jump to start")
            }
            .padding(.horizontal, 12)
            .frame(height: buttonHeight + 4)
            .glassSurface(in: RoundedRectangle(cornerRadius: corner, style: .continuous), interactive: false)
        }
        .padding(.horizontal, 10)
    }
}
