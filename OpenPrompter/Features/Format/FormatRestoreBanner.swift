//
//  FormatRestoreBanner.swift
//  OpenPrompter
//
//  One-time "Restore pre-Format version?" banner (V3 Design 04 §2.2). Shown
//  when a crash stash exists for the script being opened in the editor — i.e.
//  the app was killed between Apply and Save. Mirrors the recording
//  RecoveryBanner's shape and copy discipline: restore (bring the pre-format
//  text back) or dismiss (keep the current text, delete the stash).
//

import SwiftUI

struct FormatRestoreBanner: View {
    let onRestore: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.uturn.backward")
                .font(.system(size: 13, weight: .bold))
            VStack(alignment: .leading, spacing: 2) {
                Text("pre-format version found")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .tracking(0.5)
                Text("a format was applied but not saved before the app closed")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button(action: onRestore) {
                Text("RESTORE")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .tracking(0.8)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Theme.green, in: Capsule())
                    .foregroundStyle(Color(red: 0.03, green: 0.09, blue: 0.05))
            }
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .frame(width: 28, height: 28)
                    .foregroundStyle(Theme.muted)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Theme.amber.opacity(0.6), lineWidth: 1)
        )
        .padding(.horizontal, 10)
        .padding(.top, 8)
    }
}
