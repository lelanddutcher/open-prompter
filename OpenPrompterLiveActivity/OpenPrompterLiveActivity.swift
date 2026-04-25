//
//  OpenPrompterLiveActivity.swift
//  OpenPrompterLiveActivity (Widget Extension target)
//
//  Live Activity widget for the Recording feature (V2 Features 2 + 4).
//  Three presentations:
//
//    - Compact (next to the Dynamic Island): leading red REC dot
//      (pulsing while recording, solid otherwise) + trailing elapsed
//      time or countdown numeral.
//
//    - Expanded (long-press on the island): top-left REC dot + REC
//      label, top-right elapsed timer, bottom row script title. NO
//      stop button — V2 Design 02 review note 5: tapping there smudges
//      the front-camera lens. The user comes back to the app to stop.
//
//    - Lock-screen banner: same content as expanded, full-width. Tap
//      bounces back into the OpenPrompter app.
//
//  ActivityAttributes is in `PrompterRecordingAttributes.swift`, shared
//  between this target and the main app target via `project.yml`.
//

import ActivityKit
import SwiftUI
import WidgetKit

@main
struct OpenPrompterLiveActivityBundle: WidgetBundle {
    var body: some Widget {
        OpenPrompterLiveActivity()
    }
}

struct OpenPrompterLiveActivity: Widget {

    var body: some WidgetConfiguration {
        ActivityConfiguration(for: PrompterRecordingAttributes.self) { context in
            // Lock-screen / banner presentation.
            LockScreenPresentation(state: context.state)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 6) {
                        ExpandedRECDot(phase: context.state.phase)
                        Text("REC")
                            .font(.system(size: 14, weight: .bold, design: .monospaced))
                            .tracking(0.8)
                            .foregroundStyle(.white)
                    }
                    .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    expandedTrailing(state: context.state)
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if !context.state.scriptTitle.isEmpty {
                        Text(context.state.scriptTitle)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.85))
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 8)
                            .padding(.bottom, 4)
                    }
                }
            } compactLeading: {
                CompactRECDot(phase: context.state.phase)
            } compactTrailing: {
                compactTrailing(state: context.state)
            } minimal: {
                CompactRECDot(phase: context.state.phase)
            }
            .keylineTint(.red)
        }
    }

    /// Expanded-region trailing presentation. While recording, render a
    /// system-managed timer (`Text(startedAt, style: .timer)`) so the
    /// displayed time updates every second without `Activity.update`
    /// pushes (V2 Design 02 review note 4).
    @ViewBuilder
    private func expandedTrailing(
        state: PrompterRecordingAttributes.PrompterRecordingState
    ) -> some View {
        switch state.phase {
        case "countdown":
            Text("\(max(0, state.elapsedSeconds))")
                .font(.system(size: 14, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white)
        case "recording":
            Text(state.startedAt, style: .timer)
                .font(.system(size: 14, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white)
                .monospacedDigit()
        case "finalizing", "saving":
            Text("saving")
                .font(.system(size: 14, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white)
        default:
            EmptyView()
        }
    }

    /// Compact-trailing presentation. Same approach as expanded — system
    /// timer for the running clock.
    @ViewBuilder
    private func compactTrailing(
        state: PrompterRecordingAttributes.PrompterRecordingState
    ) -> some View {
        switch state.phase {
        case "countdown":
            Text("\(max(0, state.elapsedSeconds))")
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white)
        case "recording":
            Text(state.startedAt, style: .timer)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white)
                .monospacedDigit()
        case "finalizing", "saving":
            Text("·")
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white)
        default:
            EmptyView()
        }
    }
}

// MARK: - Compact + expanded REC dot

private struct CompactRECDot: View {
    let phase: String
    var body: some View {
        Circle()
            .fill(Color(red: 1.0, green: 0.121, blue: 0.121))
            .frame(width: 10, height: 10)
            .opacity(phase == "recording" ? 1.0 : 0.7)
    }
}

private struct ExpandedRECDot: View {
    let phase: String
    var body: some View {
        Circle()
            .fill(Color(red: 1.0, green: 0.121, blue: 0.121))
            .frame(width: 10, height: 10)
    }
}

// MARK: - Lock-screen presentation

private struct LockScreenPresentation: View {
    let state: PrompterRecordingAttributes.PrompterRecordingState

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(Color(red: 1.0, green: 0.121, blue: 0.121))
                        .frame(width: 10, height: 10)
                    Text("RECORDING")
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .tracking(0.8)
                        .foregroundStyle(.white)
                }
                if !state.scriptTitle.isEmpty {
                    Text(state.scriptTitle)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(1)
                }
            }
            Spacer()
            timeDisplay
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .activityBackgroundTint(.black)
        .activitySystemActionForegroundColor(.white)
    }

    @ViewBuilder
    private var timeDisplay: some View {
        switch state.phase {
        case "countdown":
            Text("\(max(0, state.elapsedSeconds))")
                .font(.system(size: 18, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white)
        case "recording":
            // System-managed timer — updates without Activity.update pushes
            // (V2 Design 02 review note 4).
            Text(state.startedAt, style: .timer)
                .font(.system(size: 18, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white)
                .monospacedDigit()
        case "finalizing", "saving":
            Text("saving")
                .font(.system(size: 18, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white)
        default:
            EmptyView()
        }
    }
}
