//
//  OpenPrompterLogo.swift
//  OpenPrompter
//
//  The animated brand wordmark — two square brackets with an "o" and a "p"
//  inside that sweep left→right like a reader's eyes and blink on a slower
//  cadence. Direct port of the spec in logo-animation.md; source SVG
//  viewBox is 702×603. Everything is rendered procedurally in one `Canvas`
//  so the whole mark scales to a single coordinate system.
//
//  Accessibility: respects `UIAccessibility.isReduceMotionEnabled` — when
//  on, the logo renders in the open, reading-position state with no loop.
//

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct OpenPrompterLogo: View {
    /// Height in points. Width scales automatically to the 702/603 ratio.
    var height: CGFloat = 40
    /// If false, renders a still open state (used for splash / print / icons).
    var animated: Bool = true
    /// Bracket color. Defaults to the surrounding foreground so the logo
    /// composes inside text.
    var bracketColor: Color? = nil
    /// Eye + stem accent. Open Green per design-language.md.
    var accent: Color = Color(red: 0x3F / 255, green: 0xEE / 255, blue: 0x7A / 255)

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var shouldAnimate: Bool { animated && !reduceMotion }

    var body: some View {
        TimelineView(.animation(paused: !shouldAnimate)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            let eyeOffset = shouldAnimate ? readingOffset(at: t) : Self.staticEyeOffset
            let blink = shouldAnimate ? blinkAmount(at: t) : 1.0

            Canvas { g, size in
                let vbW: CGFloat = 702, vbH: CGFloat = 603
                let scale = min(size.width / vbW, size.height / vbH)
                let dx = (size.width - vbW * scale) / 2
                let dy = (size.height - vbH * scale) / 2
                g.translateBy(x: dx, y: dy)
                g.scaleBy(x: scale, y: scale)

                // Static brackets.
                let bracketFill = GraphicsContext.Shading.color(bracketColor ?? .primary)
                g.fill(Self.leftBracketPath, with: bracketFill)
                g.fill(Self.rightBracketPath, with: bracketFill)

                // Translation group — eyes + p-stem ride the reading sweep.
                g.drawLayer { layer in
                    layer.translateBy(x: eyeOffset * Self.translateScale, y: 0)

                    let ry: CGFloat = Self.eyeRyOpen * blink
                    let rx: CGFloat = Self.eyeRx
                    let cy: CGFloat = Self.eyeCy
                    let strokeW: CGFloat = Self.eyeStroke
                    let accentFill = GraphicsContext.Shading.color(accent)

                    // Left eye (the "o").
                    let leftEye = Path(ellipseIn: CGRect(
                        x: Self.leftEyeCx - rx,
                        y: cy - ry,
                        width: rx * 2,
                        height: ry * 2
                    ))
                    layer.stroke(leftEye, with: accentFill, lineWidth: strokeW)

                    // Right eye (the bowl of the "p").
                    let rightEye = Path(ellipseIn: CGRect(
                        x: Self.rightEyeCx - rx,
                        y: cy - ry,
                        width: rx * 2,
                        height: ry * 2
                    ))
                    layer.stroke(rightEye, with: accentFill, lineWidth: strokeW)

                    // Descender of the "p". Shortens during the blink so the
                    // letterform still reads as a "p" when the bowl is closed.
                    let stemHeight: CGFloat = blink > Self.stemShortenThreshold
                        ? Self.stemHeightOpen
                        : Self.stemHeightOpen * Self.stemBlinkMultiplier
                    let stem = Path(roundedRect: CGRect(
                        x: Self.rightEyeCx + Self.stemXOffset,
                        y: cy,
                        width: Self.stemWidth,
                        height: stemHeight
                    ), cornerRadius: Self.stemCorner)
                    layer.fill(stem, with: accentFill)
                }
            }
        }
        .frame(width: height * (702.0 / 603.0), height: height)
        .accessibilityElement()
        .accessibilityLabel("Open Prompter")
    }

    // MARK: - Timelines

    private func readingOffset(at t: TimeInterval) -> CGFloat {
        let phase = (t.truncatingRemainder(dividingBy: Self.readPeriod)) / Self.readPeriod
        if phase < 0.70 {
            let n = phase / 0.70
            return CGFloat(-0.85 + n * 1.70)
        } else if phase < 0.78 {
            let n = (phase - 0.70) / 0.08
            return CGFloat(0.85 - n * 1.70)
        } else {
            return -0.85
        }
    }

    private func blinkAmount(at t: TimeInterval) -> CGFloat {
        let phase = (t.truncatingRemainder(dividingBy: Self.blinkPeriod)) / Self.blinkPeriod
        guard phase > 0.94 && phase < 0.98 else { return 1 }
        let local = (phase - 0.94) / 0.04
        return CGFloat(1 - sin(local * .pi))
    }

    // MARK: - Constants (logo-animation.md §9)

    private static let readPeriod: TimeInterval = 3.0
    private static let blinkPeriod: TimeInterval = 4.5
    private static let translateScale: CGFloat = 45
    /// Where the eyes sit in the static/icon state — reading-position-left,
    /// so the logo reads "about to start."
    private static let staticEyeOffset: CGFloat = -0.6

    private static let leftEyeCx: CGFloat = 210
    private static let rightEyeCx: CGFloat = 410
    private static let eyeCy: CGFloat = 305
    private static let eyeRx: CGFloat = 72
    private static let eyeRyOpen: CGFloat = 82
    private static let eyeStroke: CGFloat = 44

    private static let stemXOffset: CGFloat = -94
    private static let stemWidth: CGFloat = 44
    private static let stemHeightOpen: CGFloat = 190
    private static let stemBlinkMultiplier: CGFloat = 0.6
    private static let stemCorner: CGFloat = 2
    private static let stemShortenThreshold: CGFloat = 0.3

    // MARK: - Bracket paths (ported from open prompter_no padding...svg)
    //
    // Path data copied from the canonical SVG, translated into Path commands.
    // Source control points preserved verbatim so the brackets match the
    // vector export at any scale.

    private static let leftBracketPath: Path = {
        var p = Path()
        p.move(to: CGPoint(x: 0, y: 63))
        // v495 — line down to (0, 558)
        p.addLine(to: CGPoint(x: 0, y: 558))
        // c0,19.88, 16.12,36, 36,36 — ctrl1 (0,577.88), ctrl2 (16.12,594), end (36,594)
        p.addCurve(
            to: CGPoint(x: 36, y: 594),
            control1: CGPoint(x: 0, y: 577.88),
            control2: CGPoint(x: 16.12, y: 594)
        )
        // h63 — line to (99,594)
        p.addLine(to: CGPoint(x: 99, y: 594))
        // v-63 — line to (99,531)
        p.addLine(to: CGPoint(x: 99, y: 531))
        // c-19.88,0, -36,-16.12, -36,-36 — ctrl1 (79.12,531), ctrl2 (63,514.88), end (63,495)
        p.addCurve(
            to: CGPoint(x: 63, y: 495),
            control1: CGPoint(x: 79.12, y: 531),
            control2: CGPoint(x: 63, y: 514.88)
        )
        // V99 — line to (63,99)
        p.addLine(to: CGPoint(x: 63, y: 99))
        // c0,-19.88, 16.12,-36, 36,-36 — ctrl1 (63,79.12), ctrl2 (79.12,63), end (99,63)
        p.addCurve(
            to: CGPoint(x: 99, y: 63),
            control1: CGPoint(x: 63, y: 79.12),
            control2: CGPoint(x: 79.12, y: 63)
        )
        // V0 — line to (99,0)
        p.addLine(to: CGPoint(x: 99, y: 0))
        // h-63 — line to (36,0)
        p.addLine(to: CGPoint(x: 36, y: 0))
        // C16.12,0, 0,16.12, 0,36 — absolute
        p.addCurve(
            to: CGPoint(x: 0, y: 36),
            control1: CGPoint(x: 16.12, y: 0),
            control2: CGPoint(x: 0, y: 16.12)
        )
        // v27 — line to (0,63)
        p.addLine(to: CGPoint(x: 0, y: 63))
        p.closeSubpath()
        return p
    }()

    private static let rightBracketPath: Path = {
        var p = Path()
        p.move(to: CGPoint(x: 702, y: 72))
        // v498.23 — to (702, 570.23)
        p.addLine(to: CGPoint(x: 702, y: 570.23))
        // c0,18.1, -14.67,32.77, -32.77,32.77 — end (669.23, 603)
        p.addCurve(
            to: CGPoint(x: 669.23, y: 603),
            control1: CGPoint(x: 702, y: 588.33),
            control2: CGPoint(x: 687.33, y: 603)
        )
        // h-63 — to (606.23, 603)
        p.addLine(to: CGPoint(x: 606.23, y: 603))
        // c-1.78,0, -3.23,-1.45, -3.23,-3.23 — end (603, 599.77)
        p.addCurve(
            to: CGPoint(x: 603, y: 599.77),
            control1: CGPoint(x: 604.45, y: 603),
            control2: CGPoint(x: 603, y: 601.55)
        )
        // v-56.54 — to (603, 543.23)
        p.addLine(to: CGPoint(x: 603, y: 543.23))
        // c0,-1.78, 1.45,-3.23, 3.23,-3.23 — end (606.23, 540)
        p.addCurve(
            to: CGPoint(x: 606.23, y: 540),
            control1: CGPoint(x: 603, y: 541.45),
            control2: CGPoint(x: 604.45, y: 540)
        )
        // c18.1,0, 32.77,-14.67, 32.77,-32.77 — end (639, 507.23)
        p.addCurve(
            to: CGPoint(x: 639, y: 507.23),
            control1: CGPoint(x: 624.33, y: 540),
            control2: CGPoint(x: 639, y: 525.33)
        )
        // V104.77 — line to (639, 104.77)
        p.addLine(to: CGPoint(x: 639, y: 104.77))
        // c0,-18.1, -14.67,-32.77, -32.77,-32.77 — end (606.23, 72)
        p.addCurve(
            to: CGPoint(x: 606.23, y: 72),
            control1: CGPoint(x: 639, y: 86.67),
            control2: CGPoint(x: 624.33, y: 72)
        )
        // c-1.78,0, -3.23,-1.45, -3.23,-3.23 — end (603, 68.77)
        p.addCurve(
            to: CGPoint(x: 603, y: 68.77),
            control1: CGPoint(x: 604.45, y: 72),
            control2: CGPoint(x: 603, y: 70.55)
        )
        // V12.23 — line to (603, 12.23)
        p.addLine(to: CGPoint(x: 603, y: 12.23))
        // c0,-1.78, 1.45,-3.23, 3.23,-3.23 — end (606.23, 9)
        p.addCurve(
            to: CGPoint(x: 606.23, y: 9),
            control1: CGPoint(x: 603, y: 10.45),
            control2: CGPoint(x: 604.45, y: 9)
        )
        // h63 — to (669.23, 9)
        p.addLine(to: CGPoint(x: 669.23, y: 9))
        // c18.1,0, 32.77,14.67, 32.77,32.77 — end (702, 41.77)
        p.addCurve(
            to: CGPoint(x: 702, y: 41.77),
            control1: CGPoint(x: 687.33, y: 9),
            control2: CGPoint(x: 702, y: 23.67)
        )
        // v30.23 — line to (702, 72)
        p.addLine(to: CGPoint(x: 702, y: 72))
        p.closeSubpath()
        return p
    }()
}

// MARK: - Wordmark row (logo + type)

/// The logo + "open prompter" lockup used on marketing-y surfaces.
/// Pass `animated: false` where motion would be inappropriate (icons,
/// splash, dense lists).
struct OpenPrompterWordmark: View {
    var height: CGFloat = 30
    var animated: Bool = true

    var body: some View {
        HStack(spacing: height * 0.35) {
            OpenPrompterLogo(height: height, animated: animated)
            Text("open prompter")
                .font(.system(size: height * 0.72, weight: .heavy, design: .monospaced))
                .tracking(-height * 0.01)
                .foregroundStyle(Theme.fg)
        }
    }
}

#Preview("Logo sizes") {
    VStack(spacing: 28) {
        OpenPrompterLogo(height: 28)
        OpenPrompterLogo(height: 48)
        OpenPrompterLogo(height: 80)
        OpenPrompterLogo(height: 120, animated: false)
        OpenPrompterWordmark(height: 32)
    }
    .padding()
    .background(Theme.bg)
}
