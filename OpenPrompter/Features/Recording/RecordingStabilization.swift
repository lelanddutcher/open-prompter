//
//  RecordingStabilization.swift
//  OpenPrompter
//
//  Optical stabilization preference. Off by default — the user explicitly
//  said to assume the rig is mounted. Hand-held creators can switch to
//  Standard. Cinematic is available on devices that support it.
//

import AVFoundation
import Foundation

enum RecordingStabilization: String, CaseIterable, Codable, Hashable, Sendable {
    case off
    case standard
    case cinematic

    static var `default`: RecordingStabilization { .off }

    /// User-facing picker label.
    var displayName: String {
        switch self {
        case .off:       return "off"
        case .standard:  return "standard"
        case .cinematic: return "cinematic"
        }
    }

    /// AVFoundation stabilization mode for the recording connection. The
    /// connection is asked to use `preferredVideoStabilizationMode`, and
    /// AVFoundation falls back to a less-intensive mode if the device
    /// cannot support the requested level.
    var avMode: AVCaptureVideoStabilizationMode {
        switch self {
        case .off:       return .off
        case .standard:  return .standard
        case .cinematic:
            // Pick the strongest cinematic mode the OS exposes. Older OS
            // versions stop at `.cinematic`; iOS 18 introduced the
            // "enhanced" variant. The capture connection silently degrades
            // to a weaker mode if the device class doesn't support the
            // request.
            if #available(iOS 18, *) {
                return .cinematicExtendedEnhanced
            }
            if #available(iOS 17, *) {
                return .cinematicExtended
            }
            return .cinematic
        }
    }
}
