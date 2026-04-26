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
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        // Re-apply gravity in case mode changed.
        uiView.previewLayer.videoGravity = gravity
        // The session reference is stable across the camera store's lifetime,
        // but during a `.pip → .behind` transition the layer can occasionally
        // lose its session pointer (dogfood report — black screen on swap).
        // Defensively re-attach if the layer's session ever drifts from the
        // store's. Cheap when they match (identity check); fixes the stuck
        // state when they don't.
        if uiView.previewLayer.session !== session {
            uiView.previewLayer.session = session
        }
        applyMirrorTransform(to: uiView)
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
