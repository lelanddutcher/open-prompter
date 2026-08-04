//
//  RotationCoordinatorBox.swift
//  OpenPrompter
//
//  Thin, observable wrapper around `AVCaptureDevice.RotationCoordinator`
//  (iOS 17+ — our deployment floor, so no availability gate is needed; the
//  SDK header reads `API_AVAILABLE(macos(14.0), ios(17.0), ...)`).
//
//  WHY THIS EXISTS (3.1 item 4). The landscape half of the orientation system
//  used to be two hand-pinned constants (`HOLD_LANDSCAPE_*_UNVERIFIED`) that
//  were composed on top of the verified portrait transform. They were never
//  hardware-tested, and on device they double-rotated the recording ("rotated
//  an extra degree in the wrong direction, like it's multiplied") while the
//  PiP preview didn't rotate at all. Apple's coordinator observes the physical
//  device orientation and vends the two angles that fix both halves:
//
//    • `videoRotationAngleForHorizonLevelPreview`  → the preview connection
//    • `videoRotationAngleForHorizonLevelCapture`  → the writer transform
//
//  WHAT THIS BOX ADDS ON TOP: a PORTRAIT REFERENCE, and therefore a DELTA.
//
//  We cannot simply assign the coordinator's absolute angles, because our
//  pipeline's zero point is not Apple's. Our writer transform table and our
//  preview angle (0° on the square-front-sensor class) were pinned empirically
//  against real recorded pixels across thirteen dogfood passes; Apple's angles
//  are expressed against the camera's unrotated native sensor orientation. The
//  two differ by a device/camera/sensor-specific constant.
//
//  So the box latches the coordinator's angles WHILE THE INTERFACE IS
//  PORTRAIT and publishes only the difference:
//
//      delta = liveAngle − portraitReferenceAngle
//
//  The unknown constant cancels. What survives is exactly "how much extra
//  rotation does the current hold need relative to upright" — magnitude AND
//  sign, both from the OS, on every device class including iPad.
//
//  THREE PROPERTIES THAT MATTER:
//
//  1. ANTI-REGRESSION. Whenever the interface is portrait, the reference is
//     re-latched to the live value, so the delta is exactly 0 and every
//     downstream consumer receives the previously-verified portrait answer
//     unchanged. Portrait cannot regress.
//
//  2. ROTATION LOCK DOES THE RIGHT THING. Latching on the INTERFACE (not the
//     device) means a user with rotation locked keeps a portrait interface,
//     keeps a zero delta, and keeps portrait recordings — today's behaviour,
//     which is what locking rotation asks for. Unlocked, the interface follows
//     the device and the delta follows with it.
//
//  3. DEGRADED IS SAFE, NEVER WRONG. No bound device, no preview layer in the
//     hierarchy, or no portrait reference observed yet (app launched sideways
//     and never came upright) all yield delta 0 — i.e. today's behaviour. The
//     failure mode is "landscape isn't corrected yet", never "landscape is
//     double-rotated".
//
//  OWNERSHIP. `CameraStore` owns exactly one box for the app session and
//  registers it as `OrientationPolicy.rotationSource` so the policy stays the
//  single decision point. `PreviewView` attaches / detaches its
//  `AVCaptureVideoPreviewLayer` as it enters and leaves the window (the
//  coordinator returns 0° for preview when the layer is not in a view
//  hierarchy, so attachment state is load-bearing, not cosmetic).
//
//  THREADING. The coordinator "delivers key-value updates on the main queue"
//  per its header, and this class is `@MainActor`. The recording pipeline runs
//  `lazilyStartWriterOnFirstSample` on a background queue and therefore must
//  NOT read this box: `RecordingSession` latches `captureDeltaDegrees` on the
//  main actor at REC tap and carries the value in lock-guarded `WriterState`.
//

import AVFoundation
import CoreGraphics
import Foundation
import Observation
import QuartzCore
import UIKit
import os

#if DEBUG
/// `[Rotation-Debug]` channel. Landscape orientation is only reproducible on
/// real hardware, so every reference latch and delta change is traced for the
/// Console.app loop. Filter on the subsystem to follow a rotation.
fileprivate let rotationLog = Logger(
    subsystem: "app.openprompter.camera",
    category: "Rotation-Debug"
)
#endif

@Observable
@MainActor
final class RotationCoordinatorBox {

    // MARK: - Published live state

    /// Latest `videoRotationAngleForHorizonLevelPreview`, in degrees.
    /// Meaningless unless `hasPreviewLayer` — the coordinator documents that
    /// it returns 0° for preview when no layer was supplied, the layer is not
    /// in a view hierarchy, or the layer has been deallocated.
    private(set) var livePreviewDegrees: CGFloat = 0

    /// Latest `videoRotationAngleForHorizonLevelCapture`, in degrees. Valid
    /// whenever a device is bound; does NOT depend on the preview layer.
    private(set) var liveCaptureDegrees: CGFloat = 0

    /// The preview angle observed while the interface was last portrait.
    /// `nil` until the app has been seen upright at least once with a layer
    /// attached.
    private(set) var referencePreviewDegrees: CGFloat?

    /// The capture angle observed while the interface was last portrait.
    /// `nil` until the app has been seen upright at least once.
    private(set) var referenceCaptureDegrees: CGFloat?

    /// True while a preview layer is attached AND in a view hierarchy.
    private(set) var hasPreviewLayer: Bool = false

    /// True once a portrait capture reference exists — i.e. once the delta is
    /// trustworthy for a sideways hold. Surfaced in the self-test JSON so a
    /// device report can distinguish "landscape wasn't corrected" from
    /// "landscape was corrected wrongly".
    var isCalibrated: Bool { referenceCaptureDegrees != nil }

    // MARK: - Derived deltas (what the rest of the app consumes)

    /// Extra rotation the RECORDED FILE needs relative to a portrait hold, in
    /// degrees, folded into `(-180, 180]`. `0` in portrait, when uncalibrated,
    /// or when no device is bound.
    var captureDeltaDegrees: CGFloat {
        guard isBound, let reference = referenceCaptureDegrees else { return 0 }
        let own = OrientationPolicy.normalizedDeltaDegrees(liveCaptureDegrees - reference)
        if own != 0 { return own }

        // FALL BACK TO THE PREVIEW DELTA — measured, not assumed.
        //
        // On iPhone 17 Pro Max / iOS 27, a landscape take reported (record-time
        // self-test, 2026-08-04):
        //
        //     capturedHold=landscapeRight  calibrated=true  previewLayer=true
        //     previewDeltaDegrees=90       captureDeltaDegrees=0
        //
        // i.e. `videoRotationAngleForHorizonLevelPreview` tracks the device,
        // while `videoRotationAngleForHorizonLevelCapture` stays pinned at its
        // portrait value. The writer therefore applied a zero correction and
        // the file came out 90° off — the reported bug — even though every
        // other part of the chain (hold detection, calibration, latch) was
        // working.
        //
        // Both properties are expressed against the same reference and both are
        // differenced against a portrait latch, so the preview delta answers the
        // identical question — "how much extra rotation does this hold need
        // versus upright" — and is the one of the pair that actually moves here.
        //
        // Deliberately a FALLBACK, not a replacement: where the capture angle
        // does vary (other device classes, future OS versions) its own value
        // wins, unchanged. And the guard is `own != 0`, which is also exactly
        // the portrait case — where the preview delta is 0 too, so portrait
        // still resolves to 0 and cannot regress.
        return previewDeltaDegrees
    }

    /// Extra rotation the PREVIEW CONNECTION needs relative to a portrait
    /// hold, in degrees, folded into `(-180, 180]`. `0` in portrait, when
    /// uncalibrated, when no device is bound, or when no layer is in the
    /// hierarchy (in which case the coordinator's preview angle is a
    /// meaningless 0 and must not be differenced).
    var previewDeltaDegrees: CGFloat {
        guard isBound, hasPreviewLayer,
              let reference = referencePreviewDegrees else { return 0 }
        return OrientationPolicy.normalizedDeltaDegrees(livePreviewDegrees - reference)
    }

    /// True when a real coordinator exists (production) or a test has asked
    /// the box to behave as if one does. Every delta short-circuits on this so
    /// a camera-off app can never publish a stale rotation.
    private var isBound: Bool {
        #if DEBUG
        if suppressDeviceWork { return _testPretendBound }
        #endif
        return coordinator != nil
    }

    // MARK: - Internals

    private var coordinator: AVCaptureDevice.RotationCoordinator?
    private var previewObservation: NSKeyValueObservation?
    private var captureObservation: NSKeyValueObservation?

    /// The device the current coordinator was built for. The coordinator holds
    /// only a weak reference, so we keep our own to detect "same device, no
    /// need to rebuild".
    private weak var boundDevice: AVCaptureDevice?
    private weak var boundLayer: CALayer?

    /// Consumers that want to re-apply their connection angle when the
    /// coordinator moves. Keyed by `ObjectIdentifier` of the observer so a
    /// re-registering view replaces rather than duplicates its entry.
    /// Deliberately not `@Observable`-driven: the preview connection is
    /// CoreAnimation state, not SwiftUI state, and pushing it through a
    /// SwiftUI body would re-run `updateUIView` for every device wobble.
    private var angleObservers: [ObjectIdentifier: () -> Void] = [:]

    /// Test seam. When true the box never touches AVFoundation; tests drive
    /// the angles through `_testSetAngles` and exercise the same latch and
    /// delta math production uses.
    private let suppressDeviceWork: Bool

    // MARK: - Init

    init(suppressDeviceWork: Bool = false) {
        self.suppressDeviceWork = suppressDeviceWork
    }

    // No `deinit` teardown: `NSKeyValueObservation` invalidates itself when it
    // deallocates, and reaching into main-actor-isolated storage from `deinit`
    // is exactly the pattern Swift 6 rejects. The box lives for the app
    // session anyway (owned by `CameraStore`).

    // MARK: - Binding

    /// Point the box at the session's current video device. Idempotent: a
    /// repeat call with the same device is a no-op, so this is safe to call
    /// from every session reconfigure. Passing `nil` tears the coordinator
    /// down (camera off) and, with it, drops the deltas to 0.
    ///
    /// The portrait REFERENCES are deliberately preserved across a device
    /// rebind rather than cleared: they are a property of "this app's portrait
    /// zero point on this hardware", and clearing them on every PiP toggle
    /// would keep re-opening the uncalibrated window for no reason. They are
    /// refreshed on the next portrait observation anyway.
    func bind(device: AVCaptureDevice?) {
        guard !suppressDeviceWork else { return }
        guard device !== boundDevice else { return }
        boundDevice = device
        rebuildCoordinator()
    }

    /// Attach the on-screen preview layer. Call when the layer enters a
    /// window; the coordinator needs a layer that is actually in a view
    /// hierarchy or its preview angle is a meaningless 0.
    func attachPreviewLayer(_ layer: CALayer) {
        guard !suppressDeviceWork else { return }
        guard layer !== boundLayer else {
            hasPreviewLayer = true
            return
        }
        boundLayer = layer
        hasPreviewLayer = true
        // A fresh layer means a fresh portrait zero point for the preview
        // half — the previous reference was measured against a layer that no
        // longer exists. The capture reference is layer-independent and stays.
        referencePreviewDegrees = nil
        rebuildCoordinator()
    }

    /// Detach the preview layer (it left the window or is being torn down).
    /// Drops `previewDeltaDegrees` to 0, which returns the preview to its
    /// verified portrait angle rather than leaving a stale rotation applied.
    func detachPreviewLayer(_ layer: CALayer) {
        guard !suppressDeviceWork else { return }
        guard layer === boundLayer else { return }
        boundLayer = nil
        hasPreviewLayer = false
        referencePreviewDegrees = nil
        rebuildCoordinator()
    }

    /// Register a callback fired whenever either angle changes, so a preview
    /// connection can re-apply its rotation without a SwiftUI round trip.
    /// Fires immediately once so a late registrant catches up.
    func addAngleObserver(_ owner: AnyObject, _ block: @escaping () -> Void) {
        angleObservers[ObjectIdentifier(owner)] = block
        block()
    }

    func removeAngleObserver(_ owner: AnyObject) {
        angleObservers.removeValue(forKey: ObjectIdentifier(owner))
    }

    /// Re-read the angles and re-evaluate the portrait latch. Call on any
    /// event that can change the interface orientation without moving the
    /// device far enough for the coordinator to fire (rotation-lock toggle,
    /// returning to foreground, prompter appearing).
    func refresh() {
        guard !suppressDeviceWork else { return }
        guard let coordinator else { return }
        ingest(
            preview: coordinator.videoRotationAngleForHorizonLevelPreview,
            capture: coordinator.videoRotationAngleForHorizonLevelCapture
        )
    }

    // MARK: - Coordinator lifecycle

    private func rebuildCoordinator() {
        previewObservation?.invalidate()
        captureObservation?.invalidate()
        previewObservation = nil
        captureObservation = nil

        guard let device = boundDevice else {
            coordinator = nil
            livePreviewDegrees = 0
            liveCaptureDegrees = 0
            notifyAngleObservers()
            return
        }

        let made = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: boundLayer)
        coordinator = made

        // `.initial` seeds the current values; the coordinator documents that
        // updates are delivered on the main queue, which is where this class
        // already lives.
        previewObservation = made.observe(
            \.videoRotationAngleForHorizonLevelPreview, options: [.initial, .new]
        ) { [weak self] coordinator, _ in
            MainActor.assumeIsolated {
                self?.ingest(
                    preview: coordinator.videoRotationAngleForHorizonLevelPreview,
                    capture: coordinator.videoRotationAngleForHorizonLevelCapture
                )
            }
        }
        captureObservation = made.observe(
            \.videoRotationAngleForHorizonLevelCapture, options: [.initial, .new]
        ) { [weak self] coordinator, _ in
            MainActor.assumeIsolated {
                self?.ingest(
                    preview: coordinator.videoRotationAngleForHorizonLevelPreview,
                    capture: coordinator.videoRotationAngleForHorizonLevelCapture
                )
            }
        }
    }

    // MARK: - The latch

    /// Absorb a fresh pair of angles, re-latch the portrait reference if the
    /// interface is currently upright, and fan the change out.
    ///
    /// THE LATCH RULE, in one line: *the portrait reference is whatever the
    /// coordinator reports while the interface orientation is portrait.*
    /// Everything the design guarantees follows from that — see the file
    /// header.
    private func ingest(preview: CGFloat, capture: CGFloat) {
        let previousCaptureDelta = captureDeltaDegrees
        let previousPreviewDelta = previewDeltaDegrees

        livePreviewDegrees = preview
        liveCaptureDegrees = capture

        if Self.interfaceIsPortrait() {
            referenceCaptureDegrees = capture
            // Only trust a preview reference measured against a layer that is
            // actually on screen; otherwise the coordinator's documented 0°
            // would be latched as a real zero point.
            if hasPreviewLayer {
                referencePreviewDegrees = preview
            }
        }

        #if DEBUG
        if captureDeltaDegrees != previousCaptureDelta || previewDeltaDegrees != previousPreviewDelta {
            let refPreview = referencePreviewDegrees.map { "\($0)" } ?? "nil"
            let refCapture = referenceCaptureDegrees.map { "\($0)" } ?? "nil"
            rotationLog.info(
                "rotation update: preview=\(preview, privacy: .public) capture=\(capture, privacy: .public) refPreview=\(refPreview, privacy: .public) refCapture=\(refCapture, privacy: .public) previewDelta=\(self.previewDeltaDegrees, privacy: .public) captureDelta=\(self.captureDeltaDegrees, privacy: .public) layer=\(self.hasPreviewLayer, privacy: .public)"
            )
        }
        #endif

        notifyAngleObservers()
    }

    private func notifyAngleObservers() {
        for block in angleObservers.values { block() }
    }

    /// The foreground scene's interface orientation, portrait-or-not. Reads
    /// the same signal `OrientationPolicy.currentPhysicalHold()` does, so the
    /// latch and the self-test's hold label can never disagree.
    private static func interfaceIsPortrait() -> Bool {
        return OrientationPolicy.currentPhysicalHold() == .portrait
    }

    // MARK: - Test seam

    #if DEBUG
    /// Drive the box exactly as a coordinator callback would, without
    /// AVFoundation. `interfacePortrait` stands in for the live interface
    /// orientation so a unit test can walk portrait → landscape → portrait
    /// deterministically on a simulator that cannot rotate a camera.
    func _testSetAngles(preview: CGFloat, capture: CGFloat, interfacePortrait: Bool) {
        livePreviewDegrees = preview
        liveCaptureDegrees = capture
        if interfacePortrait {
            referenceCaptureDegrees = capture
            if hasPreviewLayer { referencePreviewDegrees = preview }
        }
        notifyAngleObservers()
    }

    /// Pretend a preview layer is (or isn't) in the hierarchy.
    func _testSetHasPreviewLayer(_ attached: Bool) {
        hasPreviewLayer = attached
        if !attached { referencePreviewDegrees = nil }
    }

    /// Pretend a capture device is bound, so the delta accessors don't
    /// short-circuit on `coordinator == nil` in `suppressDeviceWork` mode.
    private(set) var _testPretendBound: Bool = false
    func _testSetPretendBound(_ bound: Bool) { _testPretendBound = bound }
    #endif
}
