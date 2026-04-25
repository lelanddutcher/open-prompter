//
//  PipTile.swift
//  OpenPrompter
//
//  The draggable FaceTime-style camera tile that anchors to one of five
//  positions on screen. Wraps `CameraPreview` and applies all the gestures
//  documented in V2 Design 01 §"PiP tile behavior":
//
//  - Drag → live tile follows finger; release snaps to nearest corner via
//    `spring(response: 0.32, dampingFraction: 0.78)`.
//  - Double-tap → cycle preset sizes (small / medium / large).
//  - Two-finger swipe down → hide off-screen, leaving a 24×72pt chevron tab
//    on the nearest edge. Tap chevron to restore.
//  - Single tap → reserved for the future "promote tile to full-frame"
//    interaction (V2 Design 01 §"Gesture vocabulary"). Wired here as a
//    `View.onTapGesture` slot so it's easy to extend.
//
//  Reduce-Motion: every spring becomes an instant cut. The tile still moves;
//  it just doesn't bounce.
//

import SwiftUI

struct PipTile: View {
    @Bindable var store: CameraStore
    /// Whether the user opted into the `pref.coachMarkCameraStyleShown`
    /// banner — wired in by the parent so the chevron tab shows the right
    /// affordance label on first restore.
    var horizontalMirror: Bool
    var verticalMirror: Bool
    /// Promotion handler — called when the user single-taps the tile. The
    /// parent flips the prompter into a "preview is full frame, text is in
    /// a bottom band" mode. Feature 1 ships the gesture and persists the
    /// position; the promote/demote layout shift comes when the parent
    /// adopts it.
    var onPromote: (() -> Void)? = nil

    @State private var size: PipSize
    @State private var corner: PipCorner
    /// Live-drag offset relative to the snapped center. Reset on drag end.
    @State private var dragOffset: CGSize = .zero
    /// True while the tile is hidden off-screen waiting for a chevron tap.
    /// Strong-flick-down sets this; chevron tap or VoiceOver action clears
    /// it. Per-session by design — the chevron tab IS the within-session
    /// restore. To dismiss the tile permanently, the user picks `.off` in
    /// the chip or Settings; we don't persist `hidden` because re-entering
    /// the prompter from Library should give the user their tile back.
    @State private var hidden: Bool = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion: Bool

    init(
        store: CameraStore,
        horizontalMirror: Bool,
        verticalMirror: Bool,
        onPromote: (() -> Void)? = nil
    ) {
        self.store = store
        self.horizontalMirror = horizontalMirror
        self.verticalMirror = verticalMirror
        self.onPromote = onPromote
        // Seed from prefs so re-entry into the prompter remembers the user's
        // last-used corner and size. Falls back to medium / topCenter on
        // first launch (per V2 Design 01 §"Default state").
        _size = State(initialValue: PipSize(rawValue: Prefs.cameraPipSize) ?? .medium)
        _corner = State(initialValue: PipCorner(rawValue: Prefs.cameraPipCornerLast) ?? .topCenter)
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if hidden {
                    chevronTab(in: geo.size)
                } else {
                    tileBody(in: geo.size)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .allowsHitTesting(true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("camera tile")
        .accessibilityValue(Text("\(size.displayName), \(corner.displayName)"))
        .accessibilityHint("double tap to swap sizes; long-press to swap front and rear")
        .accessibilityAction(named: "cycle size") { cycleSize() }
        .accessibilityAction(named: "swap camera") {
            Task { await store.swapCamera() }
        }
        .accessibilityAction(named: hidden ? "show tile" : "hide tile") {
            if hidden { restoreTile() } else { hideTile() }
        }
    }

    // MARK: - Sub-views

    @ViewBuilder
    private func tileBody(in viewport: CGSize) -> some View {
        let dims = size.dimensions
        let anchor = corner.center(in: viewport, tileSize: dims, inset: 12)
        let tileCenter = CGPoint(
            x: anchor.x + dragOffset.width,
            y: anchor.y + dragOffset.height
        )

        CameraPreview(
            session: store.session,
            gravity: .resizeAspect,
            horizontalMirror: horizontalMirror,
            verticalMirror: verticalMirror
        )
        .frame(width: dims.width, height: dims.height)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Theme.border, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.35), radius: 8, x: 0, y: 4)
        .position(tileCenter)
        // Gesture ordering matters: SwiftUI evaluates `onTapGesture`
        // modifiers from outside-in, and a `count: 1` recognized first
        // commits before SwiftUI ever waits for the second tap. Apply the
        // higher-count gesture first (closer to the view) so single taps
        // get the chance to be recognized as the start of a double tap.
        // Double-tap → cycle preset sizes. Reduce-motion drops the spring;
        // the size still changes, just instantly.
        .onTapGesture(count: 2) { cycleSize() }
        // Single tap → promote (handled by parent). Currently `onPromote`
        // is unwired — Feature 2 adds the layout reorg that listens here.
        .onTapGesture(count: 1) { onPromote?() }
        // Drag → live track + spring snap on release.
        .gesture(
            DragGesture()
                .onChanged { value in dragOffset = value.translation }
                .onEnded { value in onDragEnded(value: value, in: viewport) }
        )
        // Two-finger swipe down → hide. SwiftUI's two-finger pattern is a
        // long-press on iOS isn't quite right for a swipe — we approximate
        // with a magnify gesture that detects a meaningful downward motion
        // via a simultaneous gesture. For Feature 1 we ship the simpler
        // accessibility action ("hide tile") so the gesture is reachable
        // even if the multi-touch path is fiddly to land. A follow-up can
        // tighten the multi-touch handler.
    }

    private func chevronTab(in viewport: CGSize) -> some View {
        // Chevron tab anchored on the nearest edge to the last position.
        // Picking a side from the snapped corner: leading corners → leading
        // edge; trailing or center corners → trailing edge so the user always
        // has a discoverable affordance.
        let dims = CGSize(width: 24, height: 72)
        let trailing = corner == .topTrailing || corner == .bottomTrailing || corner == .topCenter
        let x = trailing ? viewport.width - dims.width / 2 - 6 : dims.width / 2 + 6
        // Vertical position roughly mirrors the corner the tile came from.
        let y: CGFloat
        switch corner {
        case .topLeading, .topTrailing, .topCenter:
            y = max(dims.height / 2 + 60, viewport.height * 0.3)
        case .bottomLeading, .bottomTrailing:
            y = min(viewport.height - dims.height / 2 - 60, viewport.height * 0.7)
        }
        return Button(action: restoreTile) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Theme.surface)
                .overlay(
                    Image(systemName: trailing ? "chevron.left" : "chevron.right")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Theme.fg)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(Theme.border, lineWidth: 1)
                )
                .frame(width: dims.width, height: dims.height)
        }
        .position(x: x, y: y)
        .accessibilityLabel("show camera tile")
    }

    // MARK: - Gesture handlers

    private func onDragEnded(value: DragGesture.Value, in viewport: CGSize) {
        let dims = size.dimensions
        // The release point is the original anchor + the drag translation.
        let anchor = corner.center(in: viewport, tileSize: dims, inset: 12)
        let releasePoint = CGPoint(
            x: anchor.x + value.translation.width,
            y: anchor.y + value.translation.height
        )

        // If the user flicked downward strongly, treat that as the
        // "two-finger swipe down to hide" gesture — single finger reaches
        // the same outcome. The threshold is intentionally aggressive to
        // avoid stealing fast scroll attempts that happen to start on the
        // tile: predicted end ≥ 70% of viewport height, AND actual
        // translation ≥ 200pt (so the user clearly intended to throw the
        // tile and didn't just accidentally swipe), AND the motion is more
        // vertical than horizontal.
        let predicted = value.predictedEndTranslation
        let actual = value.translation
        if predicted.height > viewport.height * 0.7,
           actual.height > 200,
           predicted.height > abs(predicted.width) {
            dragOffset = .zero
            hideTile()
            return
        }

        let nearest = PipCorner.nearestCorner(
            to: releasePoint,
            in: viewport,
            tileSize: dims
        )
        if reduceMotion {
            // Reduce-motion: instant cut to the nearest corner.
            dragOffset = .zero
            corner = nearest
            persistCorner()
        } else {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) {
                dragOffset = .zero
                corner = nearest
            }
            persistCorner()
        }
        Haptics.tap()
    }

    private func cycleSize() {
        let next = size.nextSize
        if reduceMotion {
            size = next
        } else {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                size = next
            }
        }
        Prefs.cameraPipSize = next.rawValue
        Haptics.tap()
    }

    private func hideTile() {
        if reduceMotion {
            hidden = true
        } else {
            withAnimation(.easeInOut(duration: 0.22)) { hidden = true }
        }
        Haptics.tap(.medium)
    }

    private func restoreTile() {
        if reduceMotion {
            hidden = false
        } else {
            withAnimation(.easeInOut(duration: 0.22)) { hidden = false }
        }
        Haptics.tap()
    }

    private func persistCorner() {
        Prefs.cameraPipCornerLast = corner.rawValue
    }
}
