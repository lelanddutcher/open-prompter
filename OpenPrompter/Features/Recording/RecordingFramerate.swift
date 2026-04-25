//
//  RecordingFramerate.swift
//  OpenPrompter
//
//  24/30/60 fps options. 30 is the social-media default; 24 gives a more
//  cinematic look; 60 supports post-production slow-mo. Combined with the
//  RecordingQuality bitrate tier these drive `AVVideoCompressionProperties`
//  on the writer's video input.
//

import AVFoundation
import CoreMedia
import Foundation

enum RecordingFramerate: String, CaseIterable, Codable, Hashable, Sendable {
    case fps24
    case fps30
    case fps60

    static var `default`: RecordingFramerate { .fps30 }

    /// Numeric frames-per-second. Used to set the capture device's
    /// `activeVideoMinFrameDuration` / `activeVideoMaxFrameDuration` and to
    /// label the picker.
    var fps: Int {
        switch self {
        case .fps24: return 24
        case .fps30: return 30
        case .fps60: return 60
        }
    }

    /// Picker label.
    var displayName: String { "\(fps) fps" }

    /// Frame-duration `CMTime` for the capture device's locked frame rate.
    /// Locking both min and max to this value gives the writer a stable
    /// stream — variable framerates throw off the writer's session timing.
    var frameDuration: CMTime {
        CMTime(value: 1, timescale: CMTimeScale(fps))
    }
}
