//
//  HardwareCaptureBridge.swift
//  OpenPrompter
//
//  Wraps `AVCaptureEventInteraction` (iOS 17.2+) so the volume buttons,
//  the iPhone 16/17 Pro Camera Control, and a Camera-mode Action Button
//  start and stop recording. Per V2 Design 02 §"Hardware capture buttons":
//
//  - Idle → first hardware press starts countdown
//  - Countdown → press cancels
//  - Recording → press stops
//
//  Active only while the prompter chrome is foreground AND the recording
//  chip is visible (i.e. cameraStyle != .off AND labs.recording on).
//
//  Conflict avoidance with the Bluetooth-remote `volume` opt-in (Feature 7):
//  the two systems are independent. `AVCaptureEventInteraction` is
//  Apple-sanctioned for camera apps and fires on physical-device buttons;
//  the Bluetooth-remote KVO on `outputVolume` is for paired remotes (AB
//  Shutter 3) and is opt-in. Both can be on simultaneously without conflict
//  because they listen to different signal sources.
//

import SwiftUI
import UIKit

#if canImport(AVKit)
import AVKit
#endif

/// SwiftUI representable that hosts an `AVCaptureEventInteraction` on a
/// hidden UIView. The view stays installed under the prompter chrome and
/// the interaction runs whenever its `isEnabled` flag is true.
struct HardwareCaptureBridge: UIViewRepresentable {
    /// True while the recording chip is on-screen. The bridge consults
    /// this every frame; flipping it false disables the interaction so
    /// the volume buttons go back to controlling system volume.
    var isEnabled: Bool
    /// Primary press handler — volume / Camera Control / Action button.
    var onPrimary: () -> Void
    /// Secondary press handler — long-press on the Camera Control button
    /// (iPhone 16/17 Pro). Currently unused — same semantic as primary —
    /// but threaded through so a future extension can split start vs stop.
    var onSecondary: () -> Void

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.isUserInteractionEnabled = true
        view.backgroundColor = .clear
        attachInteractionIfAvailable(to: view, context: context)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.onPrimary = onPrimary
        context.coordinator.onSecondary = onSecondary
        if #available(iOS 17.2, *) {
            if let interaction = context.coordinator.interaction {
                interaction.isEnabled = isEnabled
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onPrimary: onPrimary, onSecondary: onSecondary)
    }

    private func attachInteractionIfAvailable(to view: UIView, context: Context) {
        if #available(iOS 17.2, *) {
            let interaction = AVCaptureEventInteraction { event in
                guard event.phase == .began else { return }
                context.coordinator.onPrimary()
            } secondary: { event in
                guard event.phase == .began else { return }
                context.coordinator.onSecondary()
            }
            interaction.isEnabled = isEnabled
            view.addInteraction(interaction)
            context.coordinator.interaction = interaction
        }
    }

    final class Coordinator {
        var onPrimary: () -> Void
        var onSecondary: () -> Void
        @available(iOS 17.2, *)
        var interaction: AVCaptureEventInteraction? {
            get { _interaction as? AVCaptureEventInteraction }
            set { _interaction = newValue }
        }
        private var _interaction: Any?

        init(onPrimary: @escaping () -> Void, onSecondary: @escaping () -> Void) {
            self.onPrimary = onPrimary
            self.onSecondary = onSecondary
        }
    }
}
