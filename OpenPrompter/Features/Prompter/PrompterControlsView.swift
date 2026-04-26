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

    private let rowHeight: CGFloat = 40
    private let buttonHeight: CGFloat = 44
    private let iconButton: CGFloat = 40
    private let corner: CGFloat = 10

    var body: some View {
        VStack(spacing: 6) {
            // Row 1 — primary action. The MIRROR button lived alongside
            // PLAY here until the post-merge dogfood-pass-2 control move
            // centralized mirror handling on the bottom chip strip
            // (`TeleprompterView.mirrorStatusPill` does the toggle there).
            // PLAY now spans the row width.
            HStack(spacing: 8) {
                Button(action: { vm.togglePlay() }) {
                    HStack(spacing: 6) {
                        Image(systemName: vm.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 12, weight: .bold))
                        Text(vm.isPlaying ? "PAUSE" : "PLAY")
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                            .tracking(1.0)
                    }
                    .frame(height: buttonHeight)
                    .frame(maxWidth: .infinity)
                    .background(vm.isPlaying ? Theme.green : Theme.surface)
                    .foregroundStyle(vm.isPlaying ? Color(red: 0.03, green: 0.09, blue: 0.05) : Theme.fg)
                    .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: corner, style: .continuous)
                            .stroke(vm.isPlaying ? Theme.green : Theme.border, lineWidth: 1)
                    )
                }
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
