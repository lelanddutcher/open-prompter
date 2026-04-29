//
//  PipTile.swift
//  OpenPrompter
//
//  The draggable FaceTime-style camera tile. As of the post-merge dogfooding
//  pass, the tile is _free-positioned_ — there's no corner snapping. The user
//  drops it wherever they want it, including the middle of the screen. The
//  position survives across rotation and across paired devices via a pair of
//  normalized 0..1 prefs (`cameraPipPositionX` / `cameraPipPositionY`).
//
//  Gestures:
//  - Drag → live tile follows finger; on release the tile stays exactly
//    where the user dropped it. We clamp to safe-area bounds (top inset,
//    bottom-chrome strip) so the tile can't be dragged under the controls.
//  - Double-tap → cycle preset sizes (small / medium / large).
//  - Strong flick down → hide off-screen, leaving a 24×72pt chevron tab on
//    the nearest screen edge. Tap chevron to restore at the previous
//    position.
//  - Single tap → reserved for the future "promote tile to full-frame"
//    interaction. Wired here as a `View.onTapGesture` slot so it's easy
//    to extend.
//
//  Reduce-Motion: every spring becomes an instant cut. The tile still moves;
//  it just doesn't bounce.
//

import SwiftUI

/// Frame of the currently-rendered PiP tile, in viewport coordinates.
/// Published by `PipTile` upward via SwiftUI preference so the parent
/// (`TeleprompterView`) can position its single shared `CameraPreview`
/// at the same rect. This is the dogfood-pass-8 architectural fix for
/// the ~5 s `.pip → .behind` swap: we keep ONE `AVCaptureVideoPreviewLayer`
/// alive for the whole prompter session and just resize/reposition it
/// when the user cycles modes — instead of building a fresh layer in
/// each `if cameraStyle == ...` branch, paying the AVFoundation cold-
/// start cost (which on iPhone 17 + iOS 26 was the 5 s symptom).
struct PipFramePreferenceKey: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        value = nextValue()
    }
}

/// Whether the PiP tile is currently in its hidden-off-screen state.
/// Parent reads this to decide whether to render the shared
/// `CameraPreview` at all (when hidden, no preview shows; only the
/// chevron tab does).
struct PipHiddenPreferenceKey: PreferenceKey {
    static var defaultValue: Bool = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = nextValue()
    }
}

struct PipTile: View {
    @Bindable var store: CameraStore
    var horizontalMirror: Bool
    var verticalMirror: Bool
    /// True when the prompter chrome (top bar + bottom controls) is on
    /// screen. While the chrome is visible we reserve a strip at the bottom
    /// for the controls so the tile can't be dragged under them. When the
    /// chrome is hidden the safe area expands to the full viewport.
    var chromeVisible: Bool
    /// Promotion handler — called when the user single-taps the tile. The
    /// parent flips the prompter into a "preview is full frame, text is in
    /// a bottom band" mode. Feature 1 ships the gesture and persists the
    /// position; the promote/demote layout shift comes when the parent
    /// adopts it.
    var onPromote: (() -> Void)? = nil

    @State private var size: PipSize
    /// Normalized 0..1 absolute position of the tile center. Persisted to
    /// prefs on every release so the tile remembers where the user dropped
    /// it across launches.
    @State private var positionX: Double
    @State private var positionY: Double
    /// Live-drag offset applied during the drag gesture. Reset on drag end
    /// (we fold it into `positionX/Y` at that point).
    @State private var dragOffset: CGSize = .zero
    /// True while the tile is hidden off-screen waiting for a chevron tap.
    /// Strong-flick-down sets this; chevron tap or VoiceOver action clears
    /// it. Per-session by design — the chevron tab IS the within-session
    /// restore. To dismiss the tile permanently, the user picks `.off` in
    /// the chip or Settings; we don't persist `hidden` because re-entering
    /// the prompter from Library should give the user their tile back.
    @State private var hidden: Bool = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion: Bool

    /// Reserved bottom strip (in points) for the chrome controls when
    /// `chromeVisible` is true. The bottom-bar controls live within this
    /// region; clamping the tile out of it prevents a drag from parking
    /// the preview behind the play/pause/speed rows.
    private let bottomChromeReserve: CGFloat = 140
    /// Padding kept clear at the top for the dynamic island / status bar.
    private let topReserve: CGFloat = 8
    /// Side padding so the tile breathes against the screen edge.
    private let sidePadding: CGFloat = 12

    init(
        store: CameraStore,
        horizontalMirror: Bool,
        verticalMirror: Bool,
        chromeVisible: Bool,
        onPromote: (() -> Void)? = nil
    ) {
        self.store = store
        self.horizontalMirror = horizontalMirror
        self.verticalMirror = verticalMirror
        self.chromeVisible = chromeVisible
        self.onPromote = onPromote
        // Seed from prefs so re-entry into the prompter remembers the user's
        // last drop point and size. Position falls back to the registered
        // default (0.5, 0.22 — top-center, just under the front lens).
        _size = State(initialValue: PipSize(rawValue: Prefs.cameraPipSize) ?? .medium)
        _positionX = State(initialValue: Prefs.cameraPipPositionX)
        _positionY = State(initialValue: Prefs.cameraPipPositionY)
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if hidden {
                    chevronTab(in: geo.size)
                } else {
                    tileBody(in: geo.size, safeArea: geo.safeAreaInsets)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .allowsHitTesting(true)
            // Publish the hidden state so the parent's shared
            // CameraPreview can short-circuit rendering when the tile is
            // tucked away. The frame preference (published from inside
            // tileBody) is irrelevant in the hidden branch — the parent
            // checks hidden first.
            .preference(key: PipHiddenPreferenceKey.self, value: hidden)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("camera tile")
        .accessibilityValue(Text(size.displayName))
        .accessibilityHint("double tap to swap sizes; drag to move")
        .accessibilityAction(named: "cycle size") { cycleSize() }
        .accessibilityAction(named: hidden ? "show tile" : "hide tile") {
            if hidden { restoreTile() } else { hideTile() }
        }
    }

    // MARK: - Sub-views

    @ViewBuilder
    private func tileBody(in viewport: CGSize, safeArea: EdgeInsets) -> some View {
        let dims = size.dimensions
        // Resolve the persisted normalized position to a viewport-space
        // center, then clamp into the visible safe area before applying the
        // live drag translation. Clamping the _persisted_ position rather
        // than the post-translation position means the user can briefly
        // overshoot during a drag; it snaps back to in-bounds on release.
        let resolved = resolvedCenter(in: viewport, dims: dims, safeArea: safeArea)
        let tileCenter = CGPoint(
            x: resolved.x + dragOffset.width,
            y: resolved.y + dragOffset.height
        )
        let tileFrame = CGRect(
            x: tileCenter.x - dims.width / 2,
            y: tileCenter.y - dims.height / 2,
            width: dims.width,
            height: dims.height
        )

        // The PiP tile no longer contains its own `CameraPreview`. The
        // parent (`TeleprompterView`) hoists a single shared CameraPreview
        // to the ZStack root and positions it at this tile's frame, so
        // the same `AVCaptureVideoPreviewLayer` keeps running across
        // `.pip ↔ .behind` cycles instead of being torn down + rebuilt
        // (the dogfood-pass-8 architectural fix; see the audit reports
        // for the cold-start latency analysis).
        //
        // We publish the tile frame upward via `PipFramePreferenceKey`
        // so the parent knows where to draw the camera. The chrome
        // (rounded border, shadow) and gestures stay here; they sit on
        // a transparent hit-test rectangle that overlays the camera
        // preview. From the user's perspective the visual is identical;
        // architecturally, the camera lives one level up.
        Color.clear
            .frame(width: dims.width, height: dims.height)
            .contentShape(Rectangle())
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Theme.border, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.35), radius: 8, x: 0, y: 4)
            .position(tileCenter)
            .preference(key: PipFramePreferenceKey.self, value: tileFrame)
            // Gesture ordering matters: SwiftUI evaluates `onTapGesture`
            // modifiers from outside-in, and a `count: 1` recognized first
            // commits before SwiftUI ever waits for the second tap. Apply
            // the higher-count gesture first (closer to the view) so single
            // taps get the chance to be recognized as the start of a
            // double tap.
            // Double-tap → cycle preset sizes. Reduce-motion drops the
            // spring; the size still changes, just instantly.
            .onTapGesture(count: 2) { cycleSize() }
            // Single tap → promote (handled by parent). Currently
            // `onPromote` is unwired — Feature 2 adds the layout reorg
            // that listens here.
            .onTapGesture(count: 1) { onPromote?() }
            // Drag → live track + drop-and-stay on release. We do NOT
            // spring back to a corner; the tile stays where the user
            // lifted off.
            .gesture(
                DragGesture()
                    .onChanged { value in dragOffset = value.translation }
                    .onEnded { value in
                        onDragEnded(
                            value: value,
                            in: viewport,
                            dims: dims,
                            safeArea: safeArea
                        )
                    }
            )
    }

    private func chevronTab(in viewport: CGSize) -> some View {
        // Chevron tab anchored on the nearest screen edge to the tile's
        // last x-coordinate. If the tile was on the left half of the
        // viewport, surface the chevron on the leading edge; otherwise
        // trailing.
        let dims = CGSize(width: 24, height: 72)
        let onTrailing = positionX >= 0.5
        let x = onTrailing ? viewport.width - dims.width / 2 - 6 : dims.width / 2 + 6
        // Vertical position mirrors the tile's last y, clamped to keep the
        // chevron clear of the very top and bottom (where it would collide
        // with chrome / the home indicator).
        let rawY = CGFloat(positionY) * viewport.height
        let y = max(dims.height / 2 + 60, min(viewport.height - dims.height / 2 - 60, rawY))
        return Button(action: restoreTile) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Theme.surface)
                .overlay(
                    Image(systemName: onTrailing ? "chevron.left" : "chevron.right")
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

    // MARK: - Position math

    /// Resolve the persisted normalized `(positionX, positionY)` into a
    /// viewport-space center, clamped to keep the tile inside the bounds
    /// (top safe-area, bottom chrome strip, side padding). Pure and unit-
    /// testable via the `clampedCenter(...)` static helper below.
    private func resolvedCenter(
        in viewport: CGSize,
        dims: CGSize,
        safeArea: EdgeInsets
    ) -> CGPoint {
        let raw = CGPoint(
            x: CGFloat(positionX) * viewport.width,
            y: CGFloat(positionY) * viewport.height
        )
        return Self.clampedCenter(
            point: raw,
            viewport: viewport,
            tileSize: dims,
            safeArea: safeArea,
            chromeReserve: chromeVisible ? bottomChromeReserve : 0,
            topReserve: topReserve,
            sidePadding: sidePadding
        )
    }

    /// Clamp a tile-center point to a rectangle that keeps the entire tile
    /// inside the viewport, above the bottom-chrome reserve, and below the
    /// top safe-area inset. Pure — no `self`, no captures, easy to test.
    static func clampedCenter(
        point: CGPoint,
        viewport: CGSize,
        tileSize: CGSize,
        safeArea: EdgeInsets,
        chromeReserve: CGFloat,
        topReserve: CGFloat,
        sidePadding: CGFloat
    ) -> CGPoint {
        let halfW = tileSize.width / 2
        let halfH = tileSize.height / 2
        let minX = sidePadding + halfW
        let maxX = viewport.width - sidePadding - halfW
        let minY = safeArea.top + topReserve + halfH
        // The chrome reserve takes precedence over the bottom safe area
        // when chrome is visible — we don't double-count the home indicator.
        let bottomLimit = max(safeArea.bottom, chromeReserve)
        let maxY = viewport.height - bottomLimit - 8 - halfH
        // Guard against degenerate viewports (e.g. during a layout pass at
        // launch where safe area hasn't settled yet) by collapsing to the
        // center if minY > maxY.
        let clampedX = max(minX, min(maxX, point.x))
        let clampedY = minY <= maxY ? max(minY, min(maxY, point.y)) : viewport.height / 2
        return CGPoint(x: clampedX, y: clampedY)
    }

    // MARK: - Gesture handlers

    private func onDragEnded(
        value: DragGesture.Value,
        in viewport: CGSize,
        dims: CGSize,
        safeArea: EdgeInsets
    ) {
        // The release point is the resolved (clamped) center plus the drag
        // translation.
        let resolved = resolvedCenter(in: viewport, dims: dims, safeArea: safeArea)
        let releasePoint = CGPoint(
            x: resolved.x + value.translation.width,
            y: resolved.y + value.translation.height
        )

        // If the user flicked downward strongly, treat that as the
        // "swipe down to hide" gesture. Threshold is intentionally
        // aggressive to avoid stealing fast scroll attempts that happen to
        // start on the tile: predicted end ≥ 70% of viewport height, AND
        // actual translation ≥ 200pt (so the user clearly intended to
        // throw the tile and didn't just accidentally swipe), AND the
        // motion is more vertical than horizontal.
        let predicted = value.predictedEndTranslation
        let actual = value.translation
        if predicted.height > viewport.height * 0.7,
           actual.height > 200,
           predicted.height > abs(predicted.width) {
            dragOffset = .zero
            hideTile()
            return
        }

        // Drop and stay. Clamp the release point into the safe rectangle
        // and persist it as a normalized 0..1 coordinate so it survives
        // rotation and follows the user across paired devices.
        let landing = Self.clampedCenter(
            point: releasePoint,
            viewport: viewport,
            tileSize: dims,
            safeArea: safeArea,
            chromeReserve: chromeVisible ? bottomChromeReserve : 0,
            topReserve: topReserve,
            sidePadding: sidePadding
        )
        let nx = viewport.width > 0 ? Double(landing.x / viewport.width) : 0.5
        let ny = viewport.height > 0 ? Double(landing.y / viewport.height) : 0.22
        dragOffset = .zero
        positionX = nx
        positionY = ny
        Prefs.cameraPipPositionX = nx
        Prefs.cameraPipPositionY = ny
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
}
