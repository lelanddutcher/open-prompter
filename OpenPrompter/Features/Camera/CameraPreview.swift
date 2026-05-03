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
    /// (iOS 26+). When the buffer aspect changes (e.g. iPhone 17 1×1 → 4:3
    /// transition under setDynamicAspectRatio, or .ratio4x3 → .ratio9x16 from
    /// the user picker), we re-apply the orientation-dependent preview
    /// rotation AND trigger a layout pass so the layer re-runs
    /// `.resizeAspect` against its bounds.
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
                // KVO can fire on a background queue. Hop to main before
                // touching UIKit / CoreAnimation.
                DispatchQueue.main.async {
                    // Re-apply rotation FIRST — when the buffer flips from
                    // landscape to portrait (e.g. picker from .ratio4x3 to
                    // .ratio9x16), the preview-layer connection needs to
                    // drop from 90° to 0° or it over-rotates already-
                    // portrait content into sideways landscape (the
                    // dogfood-pass-10 symptom on the preview side).
                    self?.applyOrientationDependentRotation()
                    self?.setNeedsLayout()
                }
            }
        }
    }

    /// Apply the preview-layer connection's `videoRotationAngle` based on
    /// the buffer's actual orientation (read from `device.dynamicDimensions`
    /// on iOS 26, falling back to `activeFormat` dims). Mirrors the
    /// writer-side helper in RecordingSession.writerTransform — both are
    /// driven by the same buffer-shape signal.
    ///
    /// - Landscape buffer (W > H) → 90° rotation for portrait display.
    /// - Portrait buffer (H > W) → 0° (already correctly oriented).
    /// - Square buffer (W == H) → 0° (rotation is a no-op for square content).
    /// - Device unavailable → 90° (sensible default; matches legacy behavior
    ///   when the iPhone front sensor was always landscape pre-iOS 26).
    func applyOrientationDependentRotation() {
        guard let connection = previewLayer.connection,
              connection.isVideoRotationAngleSupported(90) else { return }
        let dims = currentBufferDimensions()
        let targetAngle = Self.previewRotationAngle(
            forBufferWidth: dims.width,
            height: dims.height
        )
        if connection.videoRotationAngle != targetAngle {
            connection.videoRotationAngle = targetAngle
        }
    }

    /// Pure helper — picks the preview-layer's `videoRotationAngle` based on
    /// buffer orientation. Same orientation policy as
    /// RecordingSession.writerTransform:
    /// - Landscape (W > H) → 90°
    /// - Portrait (H > W) → 0°
    /// - Square or zero/unknown → 90° (default, matches legacy behavior)
    static func previewRotationAngle(
        forBufferWidth width: Int32,
        height: Int32
    ) -> CGFloat {
        // h > w means portrait — don't rotate, the buffer is already correct.
        // Square or unknown defaults to 90° (legacy landscape sensor).
        if width > 0 && height > 0 && height > width {
            return 0
        }
        return 90
    }

    /// Read the active video device's buffer dimensions, preferring iOS 26
    /// `dynamicDimensions` (truth source after `setDynamicAspectRatio`)
    /// and falling back to `activeFormat` dims pre-iOS-26 or when KVO has
    /// not yet fired. Returns (0, 0) when no device is attached.
    private func currentBufferDimensions() -> (width: Int32, height: Int32) {
        guard let device = (previewLayer.session?.inputs
            .compactMap { $0 as? AVCaptureDeviceInput }
            .first { $0.device.hasMediaType(.video) })?.device
        else {
            return (0, 0)
        }
        if #available(iOS 26.0, *) {
            let dyn = device.dynamicDimensions
            if dyn.width > 0 && dyn.height > 0 {
                return (dyn.width, dyn.height)
            }
        }
        let af = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        return (af.width, af.height)
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

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = gravity
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

    /// Apply the preview-layer connection's rotation conditional on the
    /// buffer's actual orientation. Delegates to `PreviewView` so the same
    /// logic runs from KVO callbacks (when `dynamicDimensions` flips under
    /// `setDynamicAspectRatio`) and from SwiftUI's `updateUIView` reapply.
    ///
    /// Pre-iOS-26 and pre-cd49cf7 the front sensor was always landscape, so
    /// a hardcoded 90° was correct. iOS 26 + the new aspect picker can hand
    /// us a portrait buffer (`.ratio9x16` → 2160×3840), and rotating that
    /// 90° again sideways-lands the preview (the dogfood-pass-10 "behind
    /// rotated to the left" symptom). The view-side helper picks 0° for
    /// portrait buffers and 90° for landscape, so both shapes display
    /// upright in `.behind` and `.pip` modes.
    private func applyPreviewRotation(to view: PreviewView) {
        view.applyOrientationDependentRotation()
    }
}
