//
//  CameraPreview.swift
//  OpenPrompter
//
//  SwiftUI wrapper around `AVCaptureVideoPreviewLayer`. Pure-SwiftUI sample-
//  buffer rendering ties latency to the main-thread runloop; the dedicated
//  CALayer path is near-zero-latency and is what every shipping AVCam-style
//  app uses.
//
//  Per V2 Design 01 §"Composition", we use a UIView subclass whose
//  `+layerClass` returns `AVCaptureVideoPreviewLayer`. SwiftUI hands it the
//  shared session from `CameraStore` and the layer takes care of the rest.
//
//  Mirror axes from Feature 6 are honored at the preview layer's transform —
//  not via SwiftUI `.scaleEffect` modifiers (those break hit testing post-
//  flip; see V2 Design 01 §"Risks and mitigations").
//
//  Rotation source-of-truth (dogfood-pass-11):
//  The preview layer's `connection.videoRotationAngle` is now derived from
//  the user's picker aspect via `OrientationPolicy.previewRotationAngle(for:)`.
//  Previously this view inferred rotation from `device.dynamicDimensions`
//  read at first-sample time, but on a cold launch that read returns (0,0)
//  for ~33-100 ms after `setDynamicAspectRatio` lands (the API is async with
//  no completion handler) — so we picked the wrong rotation. Reading the
//  picker pref is synchronous and matches the user's intent. The KVO on
//  `dynamicDimensions` is retained as a defensive backup in case the user
//  changes the picker mid-session via Settings.
//

import AVFoundation
import SwiftUI
import UIKit
import os

#if DEBUG
/// Debug logger tagged `[Behind-Mode-Debug]` for verifying preview-layer
/// mounts during chip transitions. Filter Console.app on the subsystem.
fileprivate let behindLog = Logger(
    subsystem: "app.openprompter.camera",
    category: "Behind-Mode-Debug"
)
#endif

/// UIView subclass whose backing layer is an `AVCaptureVideoPreviewLayer`.
/// The `+layerClass` override is the standard pattern documented by Apple;
/// it lets `view.layer` cast losslessly to the preview layer type.
final class PreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

    var previewLayer: AVCaptureVideoPreviewLayer {
        // Force-cast is safe here because of the layerClass override above.
        // swiftlint:disable:next force_cast
        return layer as! AVCaptureVideoPreviewLayer
    }

    /// KVO observation token for the active video device's `dynamicDimensions`
    /// (iOS 26+). Retained as a DEFENSIVE BACKUP only — the primary rotation
    /// source is now `OrientationPolicy.current` (read from `Prefs.recordingAspect`).
    /// The KVO callback re-applies the preview rotation if the user changes
    /// the picker mid-session via Settings (the picker write is synchronous
    /// to Prefs but doesn't trigger `updateUIView` here directly; the KVO
    /// fires on the subsequent buffer-shape change). Without the picker
    /// changing, the KVO is a no-op since the policy returns the same angle
    /// for the same aspect.
    private var dynamicDimensionsObserver: NSKeyValueObservation?
    private weak var observedDevice: AVCaptureDevice?

    /// Refresh the dynamic-dimensions observer against the current session.
    /// Called from `updateUIView` after the session pointer is verified.
    /// No-op below iOS 26 (the API isn't there).
    func refreshDynamicDimensionsObservation() {
        if #available(iOS 26.0, *) {
            let device = (previewLayer.session?.inputs
                .compactMap { $0 as? AVCaptureDeviceInput }
                .first { $0.device.hasMediaType(.video) })?.device
            // Same device → keep the existing observer.
            if device === observedDevice { return }

            // Tear down the old observer.
            dynamicDimensionsObserver?.invalidate()
            dynamicDimensionsObserver = nil
            observedDevice = device

            guard let device else { return }
            dynamicDimensionsObserver = device.observe(
                \.dynamicDimensions,
                options: [.new]
            ) { [weak self] _, _ in
                // QA REVIEWER FOCUS: KVO callback is now a defensive backup,
                // not the primary rotation source. The policy table is
                // keyed by aspect (read from Prefs synchronously); if the
                // user changes the picker mid-session, the next buffer-
                // shape change fires this callback and we re-read the new
                // policy value. KVO can fire on a background queue — hop
                // to main before touching UIKit / CoreAnimation.
                DispatchQueue.main.async {
                    self?.applyOrientationDependentRotation()
                    self?.setNeedsLayout()
                }
            }
        }
    }

    /// The raw aspect string the camera store told iOS to apply via
    /// `setDynamicAspectRatio` (e.g. "AVCaptureAspectRatio4x3"). When set,
    /// the preview rotation derives buffer shape from this raw value
    /// SYNCHRONOUSLY (no waiting for `dynamicDimensions` to publish). When
    /// nil, the rotation falls back to the `dynamicDimensions` KVO read.
    var requestedDynamicAspectRaw: String?

    /// The app's `AVCaptureDevice.RotationCoordinator` wrapper (3.1). Supplies
    /// the live preview-angle DELTA from the portrait reference — the fix for
    /// "the PiP preview doesn't rotate when the phone does". The view also
    /// registers its layer with the box: the coordinator returns 0° for
    /// preview unless the layer it was built with is actually in a view
    /// hierarchy, so attach/detach is load-bearing.
    private weak var rotationBox: RotationCoordinatorBox?

    /// Attach to the box and start following its angle updates. Called when
    /// the view enters a window; the symmetric detach happens on leaving.
    func bindRotationBox(_ box: RotationCoordinatorBox?) {
        guard box !== rotationBox else { return }
        rotationBox?.removeAngleObserver(self)
        rotationBox?.detachPreviewLayer(previewLayer)
        rotationBox = box
        if window != nil { attachToRotationBox() }
    }

    private func attachToRotationBox() {
        guard let rotationBox else { return }
        rotationBox.attachPreviewLayer(previewLayer)
        // Re-apply the connection angle on every coordinator move. This is a
        // direct CoreAnimation write rather than a SwiftUI state hop: routing
        // it through a `body` re-evaluation would rebuild the representable
        // for every device wobble, and `updateUIView` churn on the preview is
        // exactly what caused the "PiP tile goes black" regressions.
        rotationBox.addAngleObserver(self) { [weak self] in
            self?.applyOrientationDependentRotation()
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            attachToRotationBox()
        } else {
            rotationBox?.removeAngleObserver(self)
            rotationBox?.detachPreviewLayer(previewLayer)
        }
        applyOrientationDependentRotation()
    }

    /// Apply the preview-layer connection's `videoRotationAngle` based on
    /// the user's current `RecordingAspect` AND the actual buffer shape
    /// iOS produces after the dynamic-aspect reshape.
    ///
    /// Buffer shape priority:
    ///   1. `device.dynamicDimensions` (iOS 26+) — authoritative once iOS
    ///      publishes the reshape result. Read every time so KVO callbacks
    ///      pick up the latest values.
    ///   2. `device.activeFormat.formatDescription` dims — fallback that
    ///      works pre-iOS-26 too.
    ///   3. Defensive `.landscape` default — used during the brief cold-
    ///      start race when both reads return 0×0. KVO will correct it
    ///      within ~100ms.
    ///
    /// We DON'T use a label-based mapping (e.g., "AVCaptureAspectRatio9x16"
    /// → portrait) anymore. iOS 26.3.1 doesn't necessarily reshape pixel
    /// dimensions to match the aspect's label — the label describes the
    /// PROPORTION, but the buffer's actual pixel orientation can differ.
    /// User-confirmed (post-pass-13b) PiP rotation bugs for ratio9x16 and
    /// ratio4x3 traced to the label inference being wrong on this OS.
    ///
    /// QA REVIEWER FOCUS: do NOT re-introduce label-based shape inference
    /// in the cold-start fallback. Trusting actual dims (with a defensive
    /// landscape default) is more conservative and self-corrects via KVO.
    func applyOrientationDependentRotation() {
        guard let connection = previewLayer.connection,
              connection.isVideoRotationAngleSupported(90) else { return }

        let aspect = OrientationPolicy.current

        var bufferShape: OrientationPolicy.BufferShape?
        var sourceTag: String = "default"

        if let device = (previewLayer.session?.inputs
            .compactMap { $0 as? AVCaptureDeviceInput }
            .first { $0.device.hasMediaType(.video) })?.device {
            if #available(iOS 26.0, *) {
                let dyn = device.dynamicDimensions
                if let s = OrientationPolicy.BufferShape.from(
                    width: Int(dyn.width),
                    height: Int(dyn.height)
                ) {
                    bufferShape = s
                    sourceTag = "dynamicDimensions(\(Int(dyn.width))x\(Int(dyn.height)))"
                }
            }
            if bufferShape == nil {
                let af = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
                if let s = OrientationPolicy.BufferShape.from(
                    width: Int(af.width),
                    height: Int(af.height)
                ) {
                    bufferShape = s
                    sourceTag = "activeFormat(\(Int(af.width))x\(Int(af.height)))"
                }
            }
        }

        let shape = bufferShape ?? .landscape
        // Derive the front-sensor generation hint from the live model id
        // (synchronous, race-free). GitHub #2: the iPhone-13-Pro-class
        // (`.wideFrontSensor`) preview needs a different angle than the
        // verified iPhone-17-class (`.squareFrontSensor`) baseline. See
        // OrientationPolicy.previewRotationAngle and V3 Design 06.
        let device = OrientationPolicy.DeviceGenerationHint.from(
            modelIdentifier: OrientationPolicy.currentDeviceModelIdentifier
        )
        // 3.1: the verified portrait row PLUS the coordinator's live delta.
        // The delta is 0 whenever the interface is portrait (or whenever the
        // coordinator is unavailable / uncalibrated / the layer is off-screen),
        // so every previously-verified portrait angle is preserved exactly.
        let previewDelta = rotationBox?.previewDeltaDegrees ?? 0
        let targetAngle = OrientationPolicy.previewRotationAngle(
            for: aspect,
            bufferShape: shape,
            device: device,
            previewDeltaDegrees: previewDelta
        )

        #if DEBUG
        behindLog.info(
            "preview rotation: aspect=\(aspect.rawValue, privacy: .public) shape=\(shape.rawValue, privacy: .public) device=\(device.rawValue, privacy: .public) source=\(sourceTag, privacy: .public) delta=\(previewDelta, privacy: .public) angle=\(targetAngle, privacy: .public)"
        )
        #endif

        // The connection only accepts 0/90/180/270 and refuses anything it
        // reports unsupported; `previewRotationAngle` already normalises into
        // that set, but the support probe is per-angle so we re-ask.
        guard connection.isVideoRotationAngleSupported(targetAngle) else { return }
        if connection.videoRotationAngle != targetAngle {
            connection.videoRotationAngle = targetAngle
        }
    }

    deinit {
        dynamicDimensionsObserver?.invalidate()
    }
}

/// SwiftUI representable for the camera preview. The owner constructs the
/// `CameraStore`, hands its `session` here, and decides via `gravity` whether
/// the preview should fill the frame (`.behind`) or letterbox into a tile
/// (`.pip`).
struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    var gravity: AVLayerVideoGravity = .resizeAspectFill
    /// True when the user has horizontal mirror enabled. Composes with the
    /// text mirror (Feature 6) so the rig optics line up against a single
    /// source of truth.
    var horizontalMirror: Bool = false
    /// True when the user has vertical mirror enabled. Mirroring on this
    /// axis is unusual but supported for periscope rigs.
    var verticalMirror: Bool = false
    /// Raw aspect string the camera store told iOS to apply via
    /// `setDynamicAspectRatio`. Diagnostic only — the preview rotation
    /// itself reads actual buffer dims (race-free once KVO publishes),
    /// not this label. Kept on the struct so the value flows through
    /// SwiftUI's diff and triggers `updateUIView` when the user changes
    /// aspect mid-session.
    var requestedDynamicAspectRaw: String?
    /// Tracking signal. Bumped by `CameraStore` when the session reconfigures.
    /// Reads here cause SwiftUI to track the property; when it changes,
    /// `updateUIView` fires, which re-runs `refreshDynamicDimensionsObservation`
    /// (re-attaches KVO if the device input wasn't attached before) and
    /// `applyOrientationDependentRotation` (re-reads `dynamicDimensions`).
    var sessionConfigurationVersion: Int = 0
    /// The camera store's `AVCaptureDevice.RotationCoordinator` wrapper.
    /// Optional so previews/tests can mount without one (they then get the
    /// zero-delta portrait behaviour).
    var rotationBox: RotationCoordinatorBox?

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = gravity
        view.requestedDynamicAspectRaw = requestedDynamicAspectRaw
        view.backgroundColor = .black
        view.bindRotationBox(rotationBox)
        applyPreviewRotation(to: view)
        applyMirrorTransform(to: view)
        view.refreshDynamicDimensionsObservation()
        #if DEBUG
        behindLog.info("CameraPreview.makeUIView gravity=\(String(describing: gravity), privacy: .public)")
        #endif
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        // Re-apply gravity in case mode changed (e.g. user-driven pip →
        // behind-with-different-fill swap; the SwiftUI struct is rebuilt
        // but the same UIView is reused if SwiftUI deems identity stable).
        uiView.previewLayer.videoGravity = gravity
        uiView.requestedDynamicAspectRaw = requestedDynamicAspectRaw
        uiView.bindRotationBox(rotationBox)
        applyPreviewRotation(to: uiView)
        applyMirrorTransform(to: uiView)
        // Re-bind the iOS 26 dynamic-dimensions observer in case the input
        // device changed underneath us (camera-store reconfigure).
        uiView.refreshDynamicDimensionsObservation()
        // We deliberately do NOT re-assign `previewLayer.session` here. The
        // session pointer is set in makeUIView and is stable for the
        // lifetime of CameraStore. The previous fixup did re-assign it
        // defensively on every update, which on iOS 26 caused a frame-
        // delivery hiccup whenever SwiftUI re-evaluated the body — the
        // exact symptom the dogfood reproduced ("PiP tile goes black").
        #if DEBUG
        behindLog.debug("CameraPreview.updateUIView gravity=\(String(describing: gravity), privacy: .public)")
        #endif
    }

    /// The mirror transform composes against the preview layer (or its
    /// connection) rather than applying a `.scaleEffect` outside, because
    /// a SwiftUI scale modifier would invert hit-testing for any future
    /// taps on the preview — which the "tap to promote" gesture in
    /// `PipTile` relies on. Touching the layer transform keeps the
    /// gesture region geometrically correct.
    private func applyMirrorTransform(to view: PreviewView) {
        let sx: CGFloat = horizontalMirror ? -1 : 1
        let sy: CGFloat = verticalMirror ? -1 : 1
        view.previewLayer.setAffineTransform(CGAffineTransform(scaleX: sx, y: sy))
    }

    /// Apply the preview-layer connection's rotation derived from the user's
    /// current `RecordingAspect`. Delegates to `PreviewView` so the same
    /// path runs from the KVO defensive-backup callback.
    ///
    /// Pre-iOS-26 and pre-cd49cf7 the front sensor was always landscape, so
    /// a hardcoded 90° was correct. iOS 26 + the new aspect picker can hand
    /// us a portrait buffer (`.ratio9x16` → 2160×3840), and rotating that
    /// 90° again sideways-lands the preview (the dogfood-pass-10 "behind
    /// rotated to the left" symptom). The current-aspect policy returns
    /// 0° for `.ratio9x16` and 90° for the landscape aspects, so both
    /// shapes display upright in `.behind` and `.pip` modes.
    private func applyPreviewRotation(to view: PreviewView) {
        view.applyOrientationDependentRotation()
    }
}
