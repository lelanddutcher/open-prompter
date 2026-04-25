//
//  CameraStyleChip.swift
//  OpenPrompter
//
//  Bottom-bar pill that cycles between camera composition modes. Tap goes
//  off → pip → behind → off; long-press swaps front/rear (no-op in `.off`).
//  Style follows the existing prompter chip language (Surface bg + hairline
//  border, lowercase mono label, 44pt hit target).
//
//  VoiceOver: one element, `.adjustable` trait. Swipe up cycles forward,
//  swipe down cycles backward.
//

import SwiftUI

struct CameraStyleChip: View {
    @Bindable var store: CameraStore

    var body: some View {
        Button {
            // Cycle styles. The store handles the permission gating and
            // the "snap back to off" path on denial.
            Task {
                await store.setStyle(store.style.nextStyle)
                Haptics.tap()
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: store.style.symbolName)
                    .font(.system(size: 12, weight: .bold))
                Text(store.style.displayName)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .tracking(0.8)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(minHeight: Theme.hitMin)
            .background(Theme.surface, in: Capsule())
            .foregroundStyle(Theme.fg)
            .overlay(Capsule().stroke(Theme.border, lineWidth: 1))
            .contentShape(Capsule())
        }
        // Long-press cycles front/rear without moving styles. Confirms with
        // a medium-impact haptic so the user feels the swap distinct from a
        // short-tap cycle.
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.5)
                .onEnded { _ in
                    Task {
                        await store.swapCamera()
                        Haptics.tap(.medium)
                    }
                }
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("camera style")
        .accessibilityValue(Text(store.style.settingsDisplayName))
        .accessibilityAddTraits(.isButton)
        .accessibilityAdjustableAction { direction in
            // Adjustable widget: swipe up = forward, down = backward.
            Task {
                let next: CameraStyle
                switch direction {
                case .increment: next = store.style.nextStyle
                case .decrement: next = store.style.nextStyle.nextStyle
                @unknown default: return
                }
                await store.setStyle(next)
            }
        }
    }
}
