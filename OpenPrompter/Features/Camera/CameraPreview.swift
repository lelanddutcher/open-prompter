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
    /// transition under setDynamicAspectRatio), we trigger a layout pass so
    /// the layer re-runs `.resizeAspect` against its bounds. With
    /// `videoGravity = .resizeAspect` on the layer, the layer itself handles
    /// the actual fit; our job is just to invalidate layout on every aspect
    /// flip so any parent containers reflow if they bind to bounds.
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
                    self?.setNeedsLayout()
                }
            }
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

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = gravity
        view.backgroundColor = .black
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
}
