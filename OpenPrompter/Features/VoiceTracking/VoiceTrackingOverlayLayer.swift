//
//  VoiceTrackingOverlayLayer.swift
//  OpenPrompter
//
//  Voice-tracking on-screen UI surfaces, factored into a dedicated
//  View struct so its type-checking lives outside `TeleprompterView`'s
//  body budget (the consolidated overlay tipped that body's body
//  expression past Swift's type-check ceiling otherwise).
//
//  Two pieces compose here, both gated on `tracker.isActive`:
//
//  - **Audio meter HUD** (left edge): an 8-segment vertical bar fed
//    by `VoiceTracker.audioLevel`, plus the last few recognized words
//    and a RESET button.
//  - **Reading-line indicator** (full width): a thin horizontal line
//    at `viewportHeight * readingLineFraction`, with a draggable
//    chevron handle on the right that updates the fraction binding.
//

import SwiftUI

struct VoiceTrackingOverlayLayer: View {
    let tracker: VoiceTracker
    @Binding var readingLineFraction: Double

    var body: some View {
        ZStack {
            VoiceTrackingHUDView(tracker: tracker)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            VoiceReadingLineIndicatorView(
                isActive: tracker.isActive,
                fraction: $readingLineFraction
            )
        }
        .allowsHitTesting(tracker.isActive)
    }
}

// MARK: - ViewModifier wrapper

/// Bundles voice-tracking modifiers (overlay + cursor-advance change
/// listener) into a single `ViewModifier` so applying them to
/// `TeleprompterView.body` adds only ONE entry to its modifier chain.
/// Without this, the body's view-tree complexity exceeded SwiftUI's
/// type-check budget on Swift 5.10.
struct VoiceTrackingChrome: ViewModifier {
    let tracker: VoiceTracker
    @Binding var readingLineFraction: Double
    let onCursorChange: () -> Void

    func body(content: Content) -> some View {
        content
            .overlay {
                VoiceTrackingOverlayLayer(
                    tracker: tracker,
                    readingLineFraction: $readingLineFraction
                )
            }
            .onChange(of: tracker.lastMatch?.cursorIndex) { _, _ in
                onCursorChange()
            }
    }
}

// MARK: - HUD

private struct VoiceTrackingHUDView: View {
    let tracker: VoiceTracker

    var body: some View {
        if tracker.isActive {
            content
        }
    }

    @ViewBuilder
    private var content: some View {
        let level = CGFloat(tracker.audioLevel)
        let activeSegments = max(1, Int(level * 8))
        VStack(alignment: .leading, spacing: 6) {
            audioMeter(activeSegments: activeSegments)
            Text("VOICE")
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .tracking(0.5)
                .foregroundStyle(Theme.green)
            recognizedWordsView
            resetButton
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6))
        .padding(.leading, 6)
    }

    private func audioMeter(activeSegments: Int) -> some View {
        VStack(spacing: 2) {
            ForEach(0..<8, id: \.self) { i in
                let segIndex = 8 - i
                let isLit = segIndex <= activeSegments
                Rectangle()
                    .fill(isLit ? Theme.green : Theme.surface2)
                    .frame(width: 6, height: 8)
                    .opacity(isLit ? 1.0 : 0.35)
            }
        }
        .animation(.linear(duration: 0.05), value: activeSegments)
    }

    @ViewBuilder
    private var recognizedWordsView: some View {
        let recent = tracker.lastRecognizedWords.suffix(3).joined(separator: " ")
        if !recent.isEmpty {
            Text(recent)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(Theme.muted)
                .lineLimit(2)
                .truncationMode(.tail)
                .frame(maxWidth: 90, alignment: .leading)
        }
    }

    private var resetButton: some View {
        Button(action: { tracker.resetCursor() }) {
            HStack(spacing: 3) {
                Image(systemName: "arrow.uturn.up")
                    .font(.system(size: 8, weight: .bold))
                Text("RESET")
                    .font(.system(size: 7, weight: .bold, design: .monospaced))
                    .tracking(0.5)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Theme.surface2, in: Capsule())
            .foregroundStyle(Theme.fg)
        }
    }
}

// MARK: - Reading-line indicator

private struct VoiceReadingLineIndicatorView: View {
    let isActive: Bool
    @Binding var fraction: Double

    var body: some View {
        if isActive {
            GeometryReader { geo in
                content(geo: geo)
            }
            .allowsHitTesting(true)
        }
    }

    private func content(geo: GeometryProxy) -> some View {
        let y = geo.size.height * CGFloat(fraction)
        return ZStack(alignment: .topLeading) {
            Color.clear
            Rectangle()
                .fill(Theme.green.opacity(0.35))
                .frame(height: 1)
                .padding(.leading, geo.size.width * 0.6)
                .padding(.trailing, 60)
                .offset(y: y)
            handle(geo: geo, y: y)
        }
    }

    private func handle(geo: GeometryProxy, y: CGFloat) -> some View {
        HStack(spacing: 3) {
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 9, weight: .bold))
            Text("READ")
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .tracking(0.5)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(Theme.surface, in: Capsule())
        .overlay(Capsule().stroke(Theme.green.opacity(0.5), lineWidth: 1))
        .foregroundStyle(Theme.green)
        .offset(x: geo.size.width - 64, y: y - 12)
        .gesture(
            DragGesture()
                .onChanged { value in
                    let height = geo.size.height
                    let newY = max(40, min(height - 40, value.location.y))
                    fraction = Double(newY / height)
                }
        )
    }
}
