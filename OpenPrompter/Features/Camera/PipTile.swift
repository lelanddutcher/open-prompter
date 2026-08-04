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
//  Architecture (dogfood-pass-11 rewrite):
//  - The tile owns its own `CameraPreview` mounted INSIDE `tileBody`. This
//    is a deliberate reversion of the dogfood-pass-8 hoist that lived a
//    shared CameraPreview at TeleprompterView's ZStack root and positioned
//    it via a frame preference. That hoist caused two distinct bugs:
//      (a) Two GeometryReaders with different safe-area treatment yielded
//          a coordinate-space mismatch between the published `pipFrame` and
//          the parent's `.position(x:y:)` — the preview rendered offset
//          from the tile chrome.
//      (b) `pipFrame == .zero` on first render meant the AVCaptureVideo­
//          PreviewLayer hit zero bounds and showed empty.
//  - The cold-start cost the dogfood-pass-8 hoist was solving (`.pip ↔
//    .behind` ~5 s swap) is now mitigated differently: TeleprompterView
//    keeps a separate behind-mode CameraPreview live, so each style has its
//    own layer with stable identity. The session is shared (single
//    `CameraStore.session`), so neither layer pays AVFoundation cold-start
//    cost on style switches — only on first activation.
//

import SwiftUI

/// Whether the PiP tile is currently in its hidden-off-screen state.
/// Parent reads this to dim/hide its chrome where appropriate (the tile
/// itself renders the chevron tab — the parent doesn't need to short-
/// circuit any camera mount, since the camera now lives inside the tile).
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
    /// When true, the tile expands to fill the full screen — a "how do I
    /// look?" preview showing the complete recording frame. The SAME
    /// CameraPreview layer is reused (no cold-start delay). The parent
    /// manages this binding; PipTile renders the full-screen layout
    /// (camera + minimize button) in place of the draggable tile.
    @Binding var promoted: Bool
    /// Promotion handler — called when the user single-taps the tile. The
    /// parent flips `promoted` to true. Kept for API compatibility; the
    /// parent can also set `promoted` directly.
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

    /// 2.0.8: opacity multiplier applied during drag when the tile is
    /// approaching the bottom-chrome "drop to hide" zone. Goes from
    /// 1.0 (outside zone) → 0.25 (centered on chrome) so the user gets
    /// continuous visual feedback that releasing here will hide the
    /// tile. Reset to 1.0 on release. Founder report: previously the
    /// drag-to-hide was a brittle flick gesture (predictedEnd > 70%
    /// viewport), and dragging slowly into the bottom chrome wouldn't
    /// reliably trigger — workaround was a double-tap to resize.
    @State private var dragHideOpacity: CGFloat = 1.0

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
        promoted: Binding<Bool> = .constant(false),
        onPromote: (() -> Void)? = nil
    ) {
        self.store = store
        self.horizontalMirror = horizontalMirror
        self.verticalMirror = verticalMirror
        self.chromeVisible = chromeVisible
        self._promoted = promoted
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
                if hidden && !promoted {
                    chevronTab(in: geo.size)
                } else {
                    // Single structural path for the CameraPreview — frame
                    // and position change based on `promoted`, but the view
                    // stays at the same spot in the tree. SwiftUI reuses the
                    // UIView (no teardown/rebuild, no cold-start delay).
                    unifiedCameraBody(
                        in: geo.size,
                        safeArea: geo.safeAreaInsets
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .allowsHitTesting(true)
            .preference(key: PipHiddenPreferenceKey.self, value: hidden)
        }
        .ignoresSafeArea(promoted ? .all : [])
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(promoted ? "full-screen camera preview" : "camera tile")
        .accessibilityValue(Text(promoted ? "full screen" : size.displayName))
        .accessibilityHint(promoted ? "tap minimize to return to tile" : "double tap to swap sizes; drag to move")
        .accessibilityAction(named: "cycle size") { cycleSize() }
        .accessibilityAction(named: hidden ? "show tile" : "hide tile") {
            if hidden { restoreTile() } else { hideTile() }
        }
    }

    // MARK: - Sub-views

    /// Unified camera body — ONE structural CameraPreview that stays in
    /// the view tree regardless of `promoted`. When `promoted == false`,
    /// it renders as the draggable PiP tile. When `promoted == true`, the
    /// same view expands to fill the viewport. SwiftUI reuses the backing
    /// UIView (same AVCaptureVideoPreviewLayer), so the transition is
    /// instant — no teardown, no cold-start, no black frames.
    @ViewBuilder
    private func unifiedCameraBody(
        in viewport: CGSize,
        safeArea: EdgeInsets
    ) -> some View {
        let dims = promoted
            ? CGSize(width: viewport.width, height: viewport.height)
            : size.dimensions
        let center: CGPoint = {
            if promoted {
                return CGPoint(x: viewport.width / 2, y: viewport.height / 2)
            }
            let resolved = resolvedCenter(
                in: viewport, dims: size.dimensions, safeArea: safeArea
            )
            return CGPoint(
                x: resolved.x + dragOffset.width,
                y: resolved.y + dragOffset.height
            )
        }()
        let cornerRadius: CGFloat = promoted ? 0 : 14

        ZStack {
            // Black background — only visible in promoted mode (fills
            // the full screen behind letterboxed content).
            if promoted {
                Color.black
            }

            // THE camera preview — structurally stable across promote/
            // demote. Same session, same layer, same id.
            //
            // Gated on `store.isSessionRunning`: until the session is up and
            // the first buffer flows, an unpopulated AVCaptureVideoPreviewLayer
            // paints solid `.black`. Showing it before then is the "black box"
            // first-run bug. We render a neutral "starting camera…" placeholder
            // in the interim, then reveal the live preview once frames arrive.
            // `CameraStore` is `@Observable`, so this re-renders when the flag
            // flips on the main actor after `startRunning()`.
            ZStack {
                if store.isSessionRunning {
                    CameraPreview(
                        session: store.session,
                        gravity: .resizeAspect,
                        horizontalMirror: horizontalMirror,
                        verticalMirror: verticalMirror,
                        requestedDynamicAspectRaw: store.requestedDynamicAspectRaw,
                        sessionConfigurationVersion: store.sessionConfigurationVersion,
                        rotationBox: store.rotationBox
                    )
                    .id("camera-preview-pip")
                } else {
                    startingCameraPlaceholder
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))

            // Tile border — hidden when promoted.
            if !promoted {
                if #available(iOS 26.0, *) {
                    // Liquid Glass rim — a light-to-dark edge highlight reads as
                    // a glass bezel around the (opaque) camera preview.
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [.white.opacity(0.55), .white.opacity(0.12)],
                                startPoint: .topLeading, endPoint: .bottomTrailing
                            ),
                            lineWidth: 1
                        )
                } else {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Theme.border, lineWidth: 1)
                }
            }

            // Minimize button — only in promoted mode, bottom-right.
            if promoted {
                Button { promoted = false } label: {
                    Image(systemName: "pip.enter")
                        .font(.system(size: 22, weight: .semibold))
                        .frame(width: 56, height: 56)
                        .foregroundStyle(.white)
                        .background(.ultraThinMaterial, in: Circle())
                        .overlay(Circle().stroke(.white.opacity(0.25), lineWidth: 1))
                        .shadow(color: .black.opacity(0.5), radius: 10, y: 4)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .padding(.trailing, 24)
                .padding(.bottom, 44)
            }
        }
        .frame(width: dims.width, height: dims.height)
        .contentShape(Rectangle())
        .shadow(color: promoted ? .clear : .black.opacity(0.35), radius: 8, x: 0, y: 4)
        // 2.0.8: drag-into-hide zone fades the tile — see `dragHideOpacity`
        // state + `Self.dragHideOpacity(...)` for the threshold math.
        // 1.0 outside the zone, ramps down to 0.25 as the tile center
        // approaches chrome top; gives the user "this will hide" feedback.
        .opacity(promoted ? 1.0 : Double(dragHideOpacity))
        .animation(.easeOut(duration: 0.08), value: dragHideOpacity)
        .position(center)
        // Gestures — disabled when promoted (only the minimize button
        // is interactive in full-screen mode).
        .onTapGesture(count: 2) { if !promoted { cycleSize() } }
        .onTapGesture(count: 1) {
            if !promoted { onPromote?() }
        }
        .gesture(
            DragGesture()
                .onChanged { value in
                    if !promoted {
                        dragOffset = value.translation
                        // 2.0.8: live opacity feedback as the tile
                        // enters the "drop here to hide" zone at the
                        // bottom of the viewport. Computed from the
                        // tile's current center against the chrome
                        // reserve threshold.
                        dragHideOpacity = Self.dragHideOpacity(
                            translation: value.translation,
                            resolved: resolvedCenter(in: viewport, dims: size.dimensions, safeArea: safeArea),
                            tileSize: size.dimensions,
                            viewportHeight: viewport.height,
                            chromeReserve: chromeVisible ? bottomChromeReserve : 0
                        )
                    }
                }
                .onEnded { value in
                    if !promoted {
                        onDragEnded(
                            value: value,
                            in: viewport,
                            dims: size.dimensions,
                            safeArea: safeArea
                        )
                        dragHideOpacity = 1.0
                    }
                }
        )
    }

    /// Neutral placeholder shown in place of the live camera preview until
    /// `store.isSessionRunning` is true (the session is up and the first
    /// buffer has flowed). Replaces the raw `.black` an empty
    /// AVCaptureVideoPreviewLayer would otherwise paint — the first-run
    /// "black box" symptom. A dim surface fill + spinner reads as "loading"
    /// rather than "broken".
    private var startingCameraPlaceholder: some View {
        ZStack {
            Theme.surface2
            VStack(spacing: 8) {
                ProgressView()
                    .tint(Theme.muted)
                Text("starting camera…")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .tracking(0.5)
                    .foregroundStyle(Theme.muted)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

    /// 2.0.8: opacity for drag-into-hide visual feedback. Returns
    /// 1.0 when the tile is well clear of the bottom-chrome hide zone
    /// and ramps down to ~0.25 when the tile center has crossed into
    /// the chrome reserve (where releasing the drag will hide). Pure
    /// helper, easy to unit test.
    static func dragHideOpacity(
        translation: CGSize,
        resolved: CGPoint,
        tileSize: CGSize,
        viewportHeight: CGFloat,
        chromeReserve: CGFloat
    ) -> CGFloat {
        let halfH = tileSize.height / 2
        let currentY = resolved.y + translation.height
        // Hide-zone top: where the chrome reserve begins, accounting
        // for tile half-height so we start fading as the tile's
        // bottom edge enters the chrome rather than waiting for its
        // center to cross.
        let hideZoneTopY = viewportHeight - chromeReserve - halfH
        // Begin fading 80pt above the hide zone for a smooth ramp;
        // founder feedback: "show it starting to fade out" — needs
        // visible warning, not a binary jump at the threshold.
        let fadeStartY = hideZoneTopY - 80
        if currentY <= fadeStartY { return 1.0 }
        if currentY >= hideZoneTopY { return 0.25 }
        // Linear ramp 1.0 → 0.25 across the 80pt fade-in band.
        let progress = (currentY - fadeStartY) / max(1, hideZoneTopY - fadeStartY)
        return 1.0 - progress * 0.75
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

        // 2.0.8 hide-zone drop: if the user releases the tile inside
        // the bottom-chrome reserve area, hide it. This was previously
        // ONLY a flick gesture (predictedEnd > 70% viewport), which
        // missed the common "drag slowly down into the bottom UI"
        // intent. Now: dragging into the chrome zone fades the tile
        // (see `dragHideOpacity` in onChanged), and releasing while
        // any part of the tile overlaps the chrome reserve hides it.
        let chromeReserve = chromeVisible ? bottomChromeReserve : 0
        let halfH = dims.height / 2
        let hideZoneTopY = viewport.height - chromeReserve - halfH
        if releasePoint.y > hideZoneTopY {
            dragOffset = .zero
            hideTile()
            return
        }

        // Velocity flick fallback — kept so a fast swipe down still
        // hides even from above the chrome zone (the "throw it away"
        // gesture). Tightened to also require the release point be in
        // the lower 60% of viewport so a fast scroll on a tile parked
        // near the top doesn't accidentally hide.
        let predicted = value.predictedEndTranslation
        let actual = value.translation
        if predicted.height > viewport.height * 0.7,
           actual.height > 200,
           predicted.height > abs(predicted.width),
           releasePoint.y > viewport.height * 0.4 {
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
