//
//  MarkChip.swift
//  OpenPrompter
//
//  The bottom-bar "mark" chip (V3 headline video markers, H0a manual). One
//  tap drops a marker into the in-flight `.mov` at the exact tap frame, so a
//  keeper take is findable in an NLE / Photos scrubber without scrubbing.
//
//  Sits in the prompter bottom-bar chip strip next to the camera-style toggle
//  and the REC chip. Only meaningful WHILE recording — the parent gates its
//  presence on `state.isRecording`, but the chip also disables itself outside
//  the recording phase as a belt-and-suspenders guard so a stray tap during
//  finalize / countdown is inert.
//
//  Style clones `RecordingChip`'s chip language: Surface bg + hairline border,
//  mono glyph, 44pt hit target, medium impact haptic on tap (the haptic fires
//  inside `RecordingSession.tapMark()`, not here, so a remote-driven mark
//  feels identical).
//

import SwiftUI

struct MarkChip: View {
    @Bindable var state: RecordingState
    /// Fired on tap. The parent routes this to `RecordingSession.tapMark()`
    /// so the chip stays ignorant of the recording session (mirrors
    /// `RecordingChip`'s callback-bag pattern).
    let onTap: () -> Void

    private static let markBlue = Color(red: 0x3A / 255, green: 0x8E / 255, blue: 0xFF / 255)

    var body: some View {
        Button {
            onTap()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "bookmark.fill")
                    .font(.system(size: 11, weight: .bold))
                Text("MARK")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .tracking(0.8)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(minHeight: Theme.hitMin)
            .foregroundStyle(isEnabled ? Self.markBlue : Theme.dim)
            .glassSurface(in: Capsule())
            .overlay(Capsule().stroke(isEnabled ? Self.markBlue.opacity(0.6) : Theme.border, lineWidth: 1))
            .contentShape(Capsule())
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Drop marker")
        .accessibilityHint("Marks the current moment in the recording")
        .accessibilityAddTraits(.isButton)
        .disabled(!isEnabled)
    }

    /// Enabled only while a real take is in progress. Outside `.recording`
    /// there's no writer timeline to anchor a marker to.
    private var isEnabled: Bool {
        if case .recording = state.phase { return true }
        return false
    }
}
