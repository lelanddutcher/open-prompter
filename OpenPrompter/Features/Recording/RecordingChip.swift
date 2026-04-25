//
//  RecordingChip.swift
//  OpenPrompter
//
//  The bottom-bar REC chip. Four visual states keyed off `RecordingState.phase`:
//
//  - idle       red dot + "REC" label              tap → start countdown
//  - countdown  red dot + remaining numeral        tap → cancel
//  - recording  pulsing red dot + elapsed timer    tap → stop
//  - finalizing spinner + "saving"                 disabled
//
//  Sits in the prompter bottom-bar group, just to the right of the camera
//  style chip. Hidden when `cameraStyle == .off` (recording requires a live
//  preview) or when `labs.recording` is off.
//
//  Style follows the existing chip language (Surface bg + hairline border,
//  lowercase mono label, 44pt hit target).
//

import SwiftUI

struct RecordingChip: View {
    @Bindable var state: RecordingState
    /// Non-isolated callback bag. SwiftUI rebuilds the chip on every phase
    /// transition; we hand the parent these two callbacks so the chip
    /// doesn't need to know about `RecordingSession` directly.
    let onTap: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion: Bool

    private static let recRed = Color(red: 0xFF / 255, green: 0x1F / 255, blue: 0x1F / 255)

    var body: some View {
        Button {
            onTap()
        } label: {
            HStack(spacing: 6) {
                indicator
                label
                if showsMicWarning {
                    micWarning
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(minHeight: Theme.hitMin)
            .background(Theme.surface, in: Capsule())
            .foregroundStyle(Theme.fg)
            .overlay(Capsule().stroke(borderColor, lineWidth: 1))
            .contentShape(Capsule())
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(Text(accessibilityValue))
        .accessibilityAddTraits(.isButton)
        .disabled(isDisabled)
    }

    /// True when the writer setup couldn't attach a microphone for this
    /// take. Surfaced as a strikethrough-mic glyph next to the chip so the
    /// user sees during the take (V2 Design 02 review note 6) — distinct
    /// from the post-take error path.
    private var showsMicWarning: Bool {
        // Only show during in-flight takes (countdown / recording). Hide
        // on idle, error, finalizing, saving where it would be confusing.
        switch state.phase {
        case .countdown, .recording: return state.micUnavailableForThisTake
        default:                     return false
        }
    }

    private var micWarning: some View {
        Image(systemName: "mic.slash.fill")
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(Theme.amber)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var indicator: some View {
        switch state.phase {
        case .idle, .countdown:
            Circle()
                .fill(Self.recRed)
                .frame(width: 10, height: 10)
        case .recording:
            // Pulsing red dot — use a TimelineView so the pulse keeps phase
            // even when the prompter scroll is active under it.
            if reduceMotion {
                Circle()
                    .fill(Self.recRed)
                    .frame(width: 10, height: 10)
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                    Circle()
                        .fill(Self.recRed)
                        .frame(width: 10, height: 10)
                        .opacity(pulseOpacity(at: context.date))
                }
            }
        case .finalizing, .saving:
            ProgressView()
                .progressViewStyle(.circular)
                .scaleEffect(0.65)
                .frame(width: 10, height: 10)
        case .error:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Theme.amber)
        }
    }

    @ViewBuilder
    private var label: some View {
        // The elapsed timer needs to tick once per second while recording.
        // Wrap the recording-phase label in a `TimelineView(.periodic)` so
        // the chip re-renders every 500ms and we always show a current
        // value without explicit timer plumbing.
        switch state.phase {
        case .recording:
            TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                Text(displayText(now: .now))
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .tracking(0.8)
            }
        default:
            Text(displayText(now: .now))
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .tracking(0.8)
        }
    }

    private func displayText(now: Date) -> String {
        switch state.phase {
        case .idle:                          return "REC"
        case .countdown(let remaining):      return "\(remaining)"
        case .recording:
            let secs = state.elapsedSeconds(now: now)
            return formatElapsed(secs)
        case .finalizing:                    return "saving"
        case .saving:                        return "saving"
        case .error:                         return "error"
        }
    }

    private var borderColor: Color {
        switch state.phase {
        case .idle, .finalizing, .saving:    return Theme.border
        case .countdown, .recording:         return Self.recRed
        case .error:                         return Theme.amber
        }
    }

    private var isDisabled: Bool {
        switch state.phase {
        case .finalizing, .saving:           return true
        default:                             return false
        }
    }

    private var accessibilityLabel: String {
        switch state.phase {
        case .idle:        return "start recording"
        case .countdown:   return "cancel countdown"
        case .recording:   return "stop recording"
        case .finalizing:  return "saving recording"
        case .saving:      return "saving recording"
        case .error:       return "recording error"
        }
    }

    private var accessibilityValue: String {
        let micNote = state.micUnavailableForThisTake ? ", microphone unavailable" : ""
        switch state.phase {
        case .idle:                        return ""
        case .countdown(let r):            return "\(r) seconds remaining\(micNote)"
        case .recording:                   return formatElapsedSpoken(state.elapsedSeconds()) + micNote
        case .finalizing, .saving:         return "saving"
        case .error(let msg):              return msg
        }
    }

    /// Formats elapsed seconds as `M:SS` for ≤59:59 and `H:MM:SS` thereafter
    /// (V2 Design 02 §"Recording appearance").
    private func formatElapsed(_ secs: Int) -> String {
        let h = secs / 3600
        let m = (secs % 3600) / 60
        let s = secs % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }

    private func formatElapsedSpoken(_ secs: Int) -> String {
        let m = secs / 60
        let s = secs % 60
        if m > 0 {
            return "\(m) minute\(m == 1 ? "" : "s") \(s) seconds"
        }
        return "\(s) seconds"
    }

    /// 1.5-second pulse: 0.6 → 1.0 → 0.6. Sine-wave so the user perceives a
    /// continuous breath rather than a flicker.
    private func pulseOpacity(at date: Date) -> Double {
        let period = 1.5
        let t = date.timeIntervalSinceReferenceDate
        let phase = (t / period).truncatingRemainder(dividingBy: 1.0)
        let raw = sin(phase * 2 * .pi)
        return 0.8 + 0.2 * raw
    }
}
