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

    /// Apply the preview-layer connection's `videoRotationAngle` based on
    /// the user's current `RecordingAspect` AND the buffer shape iOS will
    /// produce after the dynamic-aspect reshape.
    ///
    /// Buffer shape sources, in order:
    ///   1. `requestedDynamicAspectRaw` — set synchronously by the camera
    ///      store at session-config time. Race-free.
    ///   2. `device.dynamicDimensions` — async-published by iOS 26+ via KVO.
    ///      Returns 0×0 for ~33-100 ms post-reshape, but is authoritative
    ///      once it lands (handles the no-aspect-applied legacy path too).
    ///
    /// QA REVIEWER FOCUS: do NOT re-introduce blanket "always rotate 90°"
    /// — that worked when the front sensor was always landscape, but iOS 26
    /// can produce portrait or square buffers depending on the requested
    /// aspect, and rotating those 90° lands the preview sideways.
    func applyOrientationDependentRotation() {
        guard let connection = previewLayer.connection,
              connection.isVideoRotationAngleSupported(0),
              connection.isVideoRotationAngleSupported(90) else { return }

        let aspect = OrientationPolicy.current

        // 1. Try the synchronous race-free path: the requested aspect raw.
        var bufferShape: OrientationPolicy.BufferShape? =
            OrientationPolicy.BufferShape.from(dynamicAspectRaw: requestedDynamicAspectRaw)

        // 2. Fall back to dynamicDimensions (iOS 26+) or activeFormat dims.
        if bufferShape == nil,
           let device = (previewLayer.session?.inputs
            .compactMap { $0 as? AVCaptureDeviceInput }
            .first { $0.device.hasMediaType(.video) })?.device {
            if #available(iOS 26.0, *) {
                let dyn = device.dynamicDimensions
                if let s = OrientationPolicy.BufferShape.from(
                    width: Int(dyn.width),
                    height: Int(dyn.height)
                ) {
                    bufferShape = s
                }
            }
            if bufferShape == nil {
                let af = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
                bufferShape = OrientationPolicy.BufferShape.from(
                    width: Int(af.width),
                    height: Int(af.height)
                )
            }
        }

        // 3. Defensive default — front sensors are historically landscape.
        let shape = bufferShape ?? .landscape

        let targetAngle = OrientationPolicy.previewRotationAngle(
            for: aspect,
            bufferShape: shape
        )
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
    /// `setDynamicAspectRatio`. Drives synchronous race-free preview
    /// rotation — see `PreviewView.applyOrientationDependentRotation`.
    var requestedDynamicAspectRaw: String?

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = gravity
        view.requestedDynamicAspectRaw = requestedDynamicAspectRaw
        view.backgroundColor = .black
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
