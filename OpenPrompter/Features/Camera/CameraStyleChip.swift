//
//  CameraStyleChip.swift
//  OpenPrompter
//
//  Bottom-bar pill that cycles between camera composition modes. Tap goes
//  off → pip → behind → off. The chip is selfie-only — the front/rear long-
//  press was dropped in the post-merge dogfooding pass; selfie creators are
//  the dominant audience and the swap was confusing on-device.
//
//  Style follows the existing prompter chip language (Surface bg + hairline
//  border, lowercase mono label, 44pt hit target).
//
//  VoiceOver: one element, `.adjustable` trait. Swipe up cycles forward,
//  swipe down cycles backward.
//

import SwiftUI
import os

#if DEBUG
fileprivate let behindLog = Logger(
    subsystem: "app.openprompter.camera",
    category: "Behind-Mode-Debug"
)
#endif

struct CameraStyleChip: View {
    @Bindable var store: CameraStore

    var body: some View {
        Button {
            // Cycle styles. The store handles the permission gating and
            // the "snap back to off" path on denial. Style flips
            // optimistically so the chip label updates instantly even
            // before the AVCaptureSession finishes starting.
            let next = store.style.nextStyle
            #if DEBUG
            behindLog.info(
                "chip tap current=\(store.style.rawValue, privacy: .public) -> \(next.rawValue, privacy: .public)"
            )
            #endif
            Task {
                await store.setStyle(next)
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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("camera style")
        .accessibilityValue(Text(store.style.settingsDisplayName))
        .accessibilityAddTraits(.isButton)
        .accessibilityAdjustableAction { direction in
            // Adjustable widget: swipe up = forward, down = backward.
            let next: CameraStyle
            switch direction {
            case .increment: next = store.style.nextStyle
            case .decrement: next = store.style.nextStyle.nextStyle
            @unknown default: return
            }
            Task { await store.setStyle(next) }
        }
    }
}
