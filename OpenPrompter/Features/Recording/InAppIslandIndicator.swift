//
//  InAppIslandIndicator.swift
//  OpenPrompter
//
//  Custom in-app indicator that mimics the Dynamic Island shape and content,
//  shown ONLY while the app is foreground AND a recording is in flight.
//
//  ActivityKit's Dynamic Island presentation is suppressed by iOS while the
//  originating app is foreground (the system assumes the app surfaces its
//  own state). The dogfood report flagged that there's no top-of-screen
//  indicator in-app — only the OS's tiny green camera-in-use dot. This
//  view fills that gap with a capsule pill anchored to the top safe-area
//  inset, just below where the actual Dynamic Island would sit.
//
//  Visibility:
//  - countdown / recording / finalizing / saving: pill shows
//  - idle / error: pill hides
//
//  When the app backgrounds, the system Live Activity takes over the actual
//  island — the in-app indicator is bound to the SwiftUI view tree so it
//  hides automatically (the prompter view itself is no longer visible).
//

import SwiftUI

struct InAppIslandIndicator: View {
    @Bindable var state: RecordingState

    @Environment(\.accessibilityReduceMotion) private var reduceMotion: Bool

    /// Pure-red REC color — matches the tally light and the chip indicator
    /// so the three "we are recording" affordances feel like one visual.
    private static let recRed = Color(red: 0xFF / 255, green: 0x1F / 255, blue: 0x1F / 255)

    var body: some View {
        if isShowing {
            HStack(spacing: 8) {
                recDot
                label
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(Capsule().fill(.black))
            .frame(height: 36)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityLabel)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    /// The phase-driven REC dot. Idle in countdown (solid), pulses during
    /// recording, becomes a spinner during finalize/save. Mirrors the chip
    /// language so the user reads the two indicators as the same state.
    @ViewBuilder
    private var recDot: some View {
        switch state.phase {
        case .countdown:
            Circle()
                .fill(Self.recRed)
                .frame(width: 9, height: 9)
        case .recording:
            if reduceMotion {
                Circle()
                    .fill(Self.recRed)
                    .frame(width: 9, height: 9)
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                    Circle()
                        .fill(Self.recRed)
                        .frame(width: 9, height: 9)
                        .opacity(pulseOpacity(at: context.date))
                }
            }
        case .finalizing, .saving:
            ProgressView()
                .progressViewStyle(.circular)
                .tint(.white)
                .scaleEffect(0.6)
                .frame(width: 9, height: 9)
        default:
            Circle()
                .fill(Self.recRed)
                .frame(width: 9, height: 9)
        }
    }

    /// Label content. Recording phase ticks via `Text(date, style: .timer)`
    /// so we don't need a per-second redraw — the system handles cadence.
    @ViewBuilder
    private var label: some View {
        switch state.phase {
        case .countdown(let remaining):
            Text("\(remaining)")
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white)
                .monospacedDigit()
        case .recording(let started):
            Text(started, style: .timer)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white)
                .monospacedDigit()
        case .finalizing, .saving:
            Text("saving")
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white)
        default:
            EmptyView()
        }
    }

    /// Only render while the app is foreground (Live Activity takes over
    /// when backgrounded). Keep visible during countdown so the user has
    /// immediate feedback that REC was tapped.
    private var isShowing: Bool {
        Self.shouldShow(for: state.phase)
    }

    /// Pure visibility predicate — exposed so tests can pin which phases
    /// produce the in-app pill (must match the `isShowing` switch above).
    static func shouldShow(for phase: RecordingPhase) -> Bool {
        switch phase {
        case .countdown, .recording, .finalizing, .saving: return true
        case .idle, .error:                                return false
        }
    }

    /// Sine-wave opacity in [0.6, 1.0] over a 2s period — same cadence as
    /// the tally-light pulse, so the three indicators throb together.
    private func pulseOpacity(at date: Date) -> Double {
        let pulsePeriod: TimeInterval = 2.0
        let t = date.timeIntervalSinceReferenceDate
        let phase = (t / pulsePeriod).truncatingRemainder(dividingBy: 1.0)
        let raw = sin(phase * 2 * .pi)
        return 0.8 + 0.2 * raw
    }

    private var accessibilityLabel: Text {
        switch state.phase {
        case .countdown(let r):    return Text("recording in \(r) seconds")
        case .recording:           return Text("recording in progress")
        case .finalizing, .saving: return Text("saving recording")
        default:                   return Text("")
        }
    }
}
