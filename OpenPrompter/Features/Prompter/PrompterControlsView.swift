//
//  PrompterControlsView.swift
//  OpenPrompter
//
//  Bottom control bar. Compact tool-strip: primary actions row, speed slider,
//  font slider + focus + jump. Sizes tuned to feel unobtrusive over text —
//  shrinks further in `focus` mode.
//

import SwiftUI

struct PrompterControlsView: View {
    var vm: PrompterViewModel

    // MARK: - Sizing
    private let rowHeight: CGFloat = 40
    private let buttonHeight: CGFloat = 42
    private let iconButton: CGFloat = 38
    private let corner: CGFloat = 10

    var body: some View {
        VStack(spacing: 6) {
            // Row 1 — primary actions
            HStack(spacing: 8) {
                Button(action: { vm.toggleMirror() }) {
                    HStack(spacing: 6) {
                        Image(systemName: vm.mirroredHorizontal ? "rectangle.2.swap" : "rectangle")
                            .font(.system(size: 13, weight: .bold))
                        Text("Mirror")
                            .font(.system(size: 14, weight: .bold))
                    }
                    .frame(height: buttonHeight)
                    .frame(maxWidth: .infinity)
                    .background(vm.mirroredHorizontal ? Theme.alert : Color(white: 0.15))
                    .foregroundStyle(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: corner))
                }

                Button(action: { vm.togglePlay() }) {
                    Label(vm.isPlaying ? "Pause" : "Play",
                          systemImage: vm.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 15, weight: .bold))
                        .frame(height: buttonHeight)
                        .frame(maxWidth: .infinity)
                        .background(vm.isPlaying ? Theme.accent : Color(white: 0.15))
                        .foregroundStyle(vm.isPlaying ? Color.black : Theme.fg)
                        .clipShape(RoundedRectangle(cornerRadius: corner))
                }
            }

            // Row 2 — speed
            HStack(spacing: 10) {
                Text("SPEED \(Int(vm.speed))")
                    .font(.system(size: 10, weight: .bold))
                    .tracking(0.08 * 10)
                    .foregroundStyle(Theme.dim)
                    .frame(width: 76, alignment: .leading)
                Slider(
                    value: Binding(get: { vm.speed }, set: { vm.setSpeed($0) }),
                    in: 5...200,
                    step: 5
                )
                .tint(Theme.fg)
            }
            .padding(.horizontal, 12)
            .frame(height: rowHeight)
            .background(Theme.controlBg, in: RoundedRectangle(cornerRadius: corner))

            // Row 3 — font + focus + jump
            HStack(spacing: 8) {
                Text("FONT \(Int(vm.fontSize))")
                    .font(.system(size: 10, weight: .bold))
                    .tracking(0.08 * 10)
                    .foregroundStyle(Theme.dim)
                    .frame(width: 68, alignment: .leading)
                Slider(
                    value: Binding(get: { vm.fontSize }, set: { vm.setFontSize($0) }),
                    in: 16...160,
                    step: 2
                )
                .tint(Theme.fg)

                Button(action: { vm.toggleFocus() }) {
                    Image(systemName: "eye.slash")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: iconButton, height: iconButton)
                        .background(Color(white: 0.15), in: RoundedRectangle(cornerRadius: 8))
                        .foregroundStyle(Theme.fg)
                }
                .accessibilityLabel("Hide controls")

                Button(action: { vm.jumpToStart() }) {
                    Image(systemName: "arrow.uturn.up")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: iconButton, height: iconButton)
                        .background(Color(white: 0.15), in: RoundedRectangle(cornerRadius: 8))
                        .foregroundStyle(Theme.fg)
                }
                .accessibilityLabel("Jump to start")
            }
            .padding(.horizontal, 8)
            .frame(height: buttonHeight + 4)
            .background(Theme.controlBg, in: RoundedRectangle(cornerRadius: corner))
        }
        .padding(.horizontal, 10)
    }
}
