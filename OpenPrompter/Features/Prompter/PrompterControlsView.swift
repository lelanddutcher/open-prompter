//
//  PrompterControlsView.swift
//  OpenPrompter
//
//  Bottom control bar. Three rows: mirror + play, speed slider, font slider
//  + focus + jump-to-start. Dims to 8% opacity in focus mode.
//

import SwiftUI

struct PrompterControlsView: View {
    var vm: PrompterViewModel

    var body: some View {
        VStack(spacing: 8) {
            // Row 1 — primary actions
            HStack(spacing: 8) {
                Button(action: { vm.toggleMirror() }) {
                    Text(vm.mirroredHorizontal ? "Mirror: ON" : "Mirror: OFF")
                        .font(.system(size: 15, weight: .bold))
                        .padding(.horizontal, 14)
                        .frame(minHeight: 48)
                        .frame(maxWidth: .infinity)
                        .background(vm.mirroredHorizontal ? Theme.alert : Color(white: 0.15))
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }

                Button(action: { vm.togglePlay() }) {
                    Label(vm.isPlaying ? "Pause" : "Play",
                          systemImage: vm.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 17, weight: .bold))
                        .padding(.horizontal, 14)
                        .frame(minHeight: 48)
                        .frame(maxWidth: .infinity)
                        .background(vm.isPlaying ? Theme.accent : Color(white: 0.15))
                        .foregroundStyle(vm.isPlaying ? Color.black : Theme.fg)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
            }

            // Row 2 — speed
            HStack(spacing: 12) {
                Text("SPEED \(Int(vm.speed))")
                    .font(.system(size: 12, weight: .bold))
                    .tracking(0.05 * 12)
                    .foregroundStyle(Theme.dim)
                    .frame(width: 90, alignment: .leading)
                Slider(
                    value: Binding(get: { vm.speed }, set: { vm.setSpeed($0) }),
                    in: 5...200,
                    step: 5
                )
                .tint(Theme.fg)
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 40)
            .background(Theme.controlBg, in: RoundedRectangle(cornerRadius: 10))

            // Row 3 — font + focus + jump
            HStack(spacing: 8) {
                Text("FONT \(Int(vm.fontSize))")
                    .font(.system(size: 12, weight: .bold))
                    .tracking(0.05 * 12)
                    .foregroundStyle(Theme.dim)
                    .frame(width: 70, alignment: .leading)
                Slider(
                    value: Binding(get: { vm.fontSize }, set: { vm.setFontSize($0) }),
                    in: 32...160,
                    step: 4
                )
                .tint(Theme.fg)

                Button(action: { vm.toggleFocus() }) {
                    Image(systemName: vm.focus ? "eye" : "eye.slash")
                        .font(.system(size: 17, weight: .semibold))
                        .frame(width: 42, height: 40)
                        .background(Color(white: 0.15), in: RoundedRectangle(cornerRadius: 10))
                        .foregroundStyle(Theme.fg)
                }

                Button(action: { vm.jumpToStart() }) {
                    Image(systemName: "arrow.uturn.up")
                        .font(.system(size: 17, weight: .semibold))
                        .frame(width: 42, height: 40)
                        .background(Color(white: 0.15), in: RoundedRectangle(cornerRadius: 10))
                        .foregroundStyle(Theme.fg)
                }
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 40)
            .background(Theme.controlBg, in: RoundedRectangle(cornerRadius: 10))
        }
        .padding(.horizontal, 10)
    }
}
