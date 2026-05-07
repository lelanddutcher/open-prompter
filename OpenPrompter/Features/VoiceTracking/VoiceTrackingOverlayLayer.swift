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
//  - **READ / FEATHER indicator** (right edge): a sharp READ line at
//    the top where matched (just-spoken) words are aimed to land,
//    plus a softly fading FEATHER teardrop below it whose vertical
//    extent maps to the velocity controller's smoothness:
//      • Tight (READ ≈ FEATHER) → snappy, in-lockstep follow.
//      • Wide → smoother momentum, easier on the eyes.
//    Pre-2.0.2 the bottom edge was unwired in scroll math; the
//    teardrop visualizes that the gap is what the user is dialing.
//

import SwiftUI

struct VoiceTrackingOverlayLayer: View {
    let tracker: VoiceTracker
    @Binding var readFraction: Double
    @Binding var featherFraction: Double
    /// 2.0.8: when the eyeball / focus button hides the lower chrome,
    /// dim the READ/FEATHER overlay to 20% opacity instead of hiding
    /// it entirely. Founder feedback: "I should still be able to drag
    /// them as I go without bringing the UI back." Hit-testing stays
    /// on so dragging works in dimmed state too.
    var focusDimmed: Bool = false

    var body: some View {
        // The audio-meter HUD moved into `PrompterControlsView` as a
        // horizontal strip (see VoiceTrackingHUDStrip). This overlay
        // now only paints the READ / FEATHER indicator on the prompter.
        VoiceReadFeatherIndicatorView(
            isActive: tracker.isActive,
            readFraction: $readFraction,
            featherFraction: $featherFraction
        )
        .opacity(focusDimmed ? 0.2 : 1.0)
        .animation(.easeInOut(duration: Theme.focusAnim), value: focusDimmed)
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
    /// Bundle of values that, when ANY changes, should re-aim the
    /// lerp target. Passed as a value-typed `Equatable` so SwiftUI's
    /// `.onChange` reliably fires (observing the @Binding's wrapped
    /// value directly was unreliable on device — drag updates didn't
    /// always re-render the target until voice was toggled off/on).
    struct LayoutKey: Equatable {
        let fontSize: Double
        /// Font-size change re-fires onChange AFTER the GeometryReader
        /// has measured the new content height. Without this, the
        /// recompute used a stale contentHeight and the scroll target
        /// landed at the wrong offset.
        let contentHeight: CGFloat
        /// Same reasoning — viewport changes (rotation, keyboard)
        /// re-aim the target.
        let viewportHeight: CGFloat
        // Note: box top/bottom fractions are deliberately NOT in this
        // key. Dragging the box should NOT trigger scroll — that was
        // the "phantom movement" reported on device. The box's bottom
        // edge is read at the next genuine cursor advance instead.
    }

    let tracker: VoiceTracker
    @Binding var readFraction: Double
    @Binding var featherFraction: Double
    let onCursorChange: () -> Void
    let layoutKey: LayoutKey
    /// 2.0.8: when the prompter is in focus mode (eyeball pressed),
    /// dim the READ/FEATHER overlay to 20% so the user can still drag
    /// to adjust without un-focusing the chrome.
    var focusDimmed: Bool = false

    func body(content: Content) -> some View {
        content
            .overlay {
                VoiceTrackingOverlayLayer(
                    tracker: tracker,
                    readFraction: $readFraction,
                    featherFraction: $featherFraction,
                    focusDimmed: focusDimmed
                )
            }
            .onChange(of: tracker.lastMatch?.cursorIndex) { _, _ in
                onCursorChange()
            }
            .onChange(of: layoutKey) { _, _ in
                onCursorChange()
            }
    }
}

// MARK: - HUD strip

/// Horizontal status strip rendered ABOVE the prompter controls
/// (inside `PrompterControlsView`). No background blur — sits
/// directly on the prompter backdrop. Auto-hides with the rest of
/// the bottom chrome when focus mode is on (because it's part of
/// the bottom VStack, which already inherits the focus opacity).
struct VoiceTrackingHUDStrip: View {
    let tracker: VoiceTracker

    var body: some View {
        if tracker.isActive {
            content
        }
    }

    @ViewBuilder
    private var content: some View {
        let level = CGFloat(tracker.audioLevel)
        let activeSegments = max(0, Int(level * 8))
        HStack(spacing: 8) {
            // Horizontal level meter — 8 segments fill left-to-right
            // as audio level rises.
            HStack(spacing: 2) {
                ForEach(0..<8, id: \.self) { i in
                    let isLit = i < activeSegments
                    Rectangle()
                        .fill(isLit ? Theme.green : Theme.surface2)
                        .frame(width: 4, height: 10)
                        .opacity(isLit ? 1.0 : 0.4)
                }
            }
            .animation(.linear(duration: 0.05), value: activeSegments)
            // Last-recognized-words preview, monospaced so the strip
            // doesn't reflow as recognition delivers new content.
            let recent = tracker.lastRecognizedWords.suffix(4).joined(separator: " ")
            Text(recent.isEmpty ? "listening…" : recent)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(recent.isEmpty ? Theme.dim : Theme.muted)
                .lineLimit(1)
                .truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .leading)
            // RESET — drops the cursor to start of script.
            Button(action: { tracker.resetCursor() }) {
                HStack(spacing: 3) {
                    Image(systemName: "arrow.uturn.up")
                        .font(.system(size: 9, weight: .bold))
                    Text("RESET")
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .tracking(0.5)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .foregroundStyle(Theme.green)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 24)
    }
}

// MARK: - READ / FEATHER indicator

/// 2.0.2 redesign of the voice-tracking band.
///
/// The previous "TOP + BOT" model was misleading: only the top edge
/// affected scroll math, the bottom was visual-only. The founder's
/// intuition that "spread the band for smoother glide" had no wiring,
/// so the user was tuning a knob that did nothing. This view replaces
/// that with two semantically-named handles:
///
///   • **READ** — the line where matched (just-spoken) words land.
///     Same role the old TOP cursor had; same storage key.
///   • **FEATHER** — the bottom of a tapered teardrop whose vertical
///     extent drives the velocity controller's smoothness. Tighter
///     gap → snappier P-controller (cursor stays in lockstep with
///     recognized words). Wider gap → smoother momentum, glides
///     toward target.
///
/// Visual: a sharp horizontal READ line on the right side of the
/// prompter, a vertical green gradient teardrop fanning slightly out
/// underneath it, ending in a softer FEATHER line. The tapering
/// teardrop is the user-facing metaphor: tighter teardrop = tighter
/// follow. Width-wise the indicator is intentionally narrow (right
/// 28% of viewport) so it doesn't intrude into reading area.
private struct VoiceReadFeatherIndicatorView: View {
    let isActive: Bool
    @Binding var readFraction: Double
    @Binding var featherFraction: Double

    var body: some View {
        if isActive {
            GeometryReader { geo in
                content(geo: geo)
            }
            .allowsHitTesting(true)
        }
    }

    private func content(geo: GeometryProxy) -> some View {
        let readY = geo.size.height * CGFloat(readFraction)
        let featherY = geo.size.height * CGFloat(featherFraction)
        // Right-edge column the indicator lives in. Left-padding
        // 72% of width = right 28% — narrower than the pre-2.0.2
        // band (45%), per founder direction "shorten the green bar
        // that juts into the frame."
        let leftPad = geo.size.width * 0.72
        let rightPad: CGFloat = 16
        let columnWidth = max(0, geo.size.width - leftPad - rightPad)
        return ZStack(alignment: .topLeading) {
            Color.clear
            // The teardrop gradient — narrow at the READ line,
            // flaring outward and fading away at FEATHER. A path
            // shape so the geometry IS the metaphor: bigger drop =
            // more smoothing.
            FeatherTeardropShape(narrowFraction: 0.10)
                .fill(
                    LinearGradient(
                        stops: [
                            .init(color: Theme.green.opacity(0.32), location: 0.0),
                            .init(color: Theme.green.opacity(0.10), location: 0.55),
                            .init(color: Theme.green.opacity(0.0), location: 1.0),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(width: columnWidth, height: max(0, featherY - readY))
                .offset(x: leftPad, y: readY)
                .allowsHitTesting(false)
            // READ line — bright, sharp. The actual scroll target.
            Rectangle()
                .fill(Theme.green.opacity(0.85))
                .frame(height: 1.5)
                .padding(.leading, leftPad)
                .padding(.trailing, rightPad + 56)
                .offset(y: readY)
                .allowsHitTesting(false)
            // FEATHER line — soft, dotted-feel via low opacity.
            // Visually marks where smoothing fades to nothing.
            Rectangle()
                .fill(Theme.green.opacity(0.20))
                .frame(height: 1)
                .padding(.leading, leftPad + columnWidth * 0.10)
                .padding(.trailing, rightPad + 56)
                .offset(y: featherY)
                .allowsHitTesting(false)
            // Handles — labeled READ + FEATHER. Same drag gesture
            // contract as the old TOP/BOT, same min-spacing clamp.
            handle(
                label: "READ",
                geo: geo,
                y: readY,
                isRead: true,
                emphasis: .strong
            )
            handle(
                label: "FEATHER",
                geo: geo,
                y: featherY,
                isRead: false,
                emphasis: .soft
            )
        }
    }

    /// Two visual emphases for the handles — READ is the load-
    /// bearing line (bright + opaque), FEATHER is the smoothness
    /// dial (softer outline so the user reads it as adjustable but
    /// secondary).
    private enum HandleEmphasis { case strong, soft }

    private func handle(
        label: String,
        geo: GeometryProxy,
        y: CGFloat,
        isRead: Bool,
        emphasis: HandleEmphasis
    ) -> some View {
        let foreground = emphasis == .strong ? Theme.green : Theme.green.opacity(0.7)
        let stroke = emphasis == .strong ? Theme.green.opacity(0.55) : Theme.green.opacity(0.30)
        return HStack(spacing: 3) {
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 9, weight: .bold))
            Text(label)
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .tracking(0.5)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(Theme.surface, in: Capsule())
        .overlay(Capsule().stroke(stroke, lineWidth: 1))
        .foregroundStyle(foreground)
        .offset(x: geo.size.width - 76, y: y - 12)
        .gesture(
            DragGesture()
                .onChanged { value in
                    let height = geo.size.height
                    let raw = max(20, min(height - 20, value.location.y))
                    let newFrac = Double(raw / height)
                    if isRead {
                        // 2.0.4: READ drags push FEATHER along to
                        // preserve their previous spacing. Pre-2.0.4
                        // the symmetric clamp pinned READ behind
                        // FEATHER — if both were stacked at the top,
                        // the user couldn't move READ down without
                        // first moving FEATHER, which read as a
                        // holdover from the BOT cursor era.
                        let previousGap = max(0.05, featherFraction - readFraction)
                        readFraction = max(0.0, min(newFrac, 1.0 - 0.05))
                        // If FEATHER is now within minimum spacing of
                        // the new READ position, push it forward.
                        if featherFraction < readFraction + 0.05 {
                            featherFraction = min(1.0, readFraction + previousGap)
                        }
                    } else {
                        // FEATHER drag stays simple — clamp to at
                        // least 0.05 below READ. We don't push READ
                        // backward (that would be confusing — the user
                        // touched FEATHER, not READ).
                        featherFraction = max(newFrac, readFraction + 0.05)
                    }
                }
        )
    }
}

/// Teardrop / parabola shape opening downward. `narrowFraction`
/// controls how tight the top of the drop is — a small value makes
/// the READ line read as a precise point that fans outward toward
/// the FEATHER line. Implemented as two quadratic curves so the
/// silhouette feels organic rather than geometric.
private struct FeatherTeardropShape: Shape {
    /// Width at the READ end as a fraction of the column width.
    /// 0.10 = 10% of column width at the top, full width at the
    /// bottom — visually communicates "tight at READ, loose at
    /// FEATHER."
    var narrowFraction: CGFloat = 0.10

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let topInset = rect.width * (1 - narrowFraction) / 2
        let topLeft = CGPoint(x: rect.minX + topInset, y: rect.minY)
        let topRight = CGPoint(x: rect.maxX - topInset, y: rect.minY)
        let botLeft = CGPoint(x: rect.minX, y: rect.maxY)
        let botRight = CGPoint(x: rect.maxX, y: rect.maxY)
        // Control points 60% down — flares early, then settles
        // toward the wider base. Result reads as a teardrop /
        // hyperbola, not a simple wedge.
        let cpLeft = CGPoint(x: rect.minX + topInset * 0.35, y: rect.minY + rect.height * 0.60)
        let cpRight = CGPoint(x: rect.maxX - topInset * 0.35, y: rect.minY + rect.height * 0.60)
        p.move(to: topLeft)
        p.addLine(to: topRight)
        p.addQuadCurve(to: botRight, control: cpRight)
        p.addLine(to: botLeft)
        p.addQuadCurve(to: topLeft, control: cpLeft)
        p.closeSubpath()
        return p
    }
}
