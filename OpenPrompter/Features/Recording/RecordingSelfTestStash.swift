//
//  RecordingSelfTestStash.swift
//  OpenPrompter
//
//  DEBUG-only record-time snapshot for the recording self-test.
//
//  WHY THIS EXISTS
//
//  The self-test runs from Settings, minutes after a take, with the phone back
//  in the user's hand. Anything it samples LIVE therefore describes the pose at
//  button-tap, not during the recording. A landscape take came back labelled
//  `capturedHold: "portrait", captureDelta: 0°` for exactly that reason — the
//  user rotated upright to reach the button — which is precisely backwards for
//  the one diagnostic that exists to explain landscape recordings, and it very
//  nearly sent a rotation "fix" at a bug that the data could not actually
//  confirm.
//
//  So the values are captured AT REC TAP, on the main actor, where they are
//  true, and read back later by the self-test. `UserDefaults` is the transport
//  because it survives the recording teardown, the app going to the background,
//  and a relaunch between recording and testing.
//

#if DEBUG
import Foundation

enum RecordingSelfTestStash {
    /// Snapshot of the rotation inputs as they stood when REC was tapped.
    struct RecordTimeRotation {
        let hold: String
        let captureDelta: Double
        let previewDelta: Double
        let isCalibrated: Bool
        let hasPreviewLayer: Bool
    }

    private static let key = "debug.selftest.recordTimeRotation"

    /// Called on the main actor at REC tap (and again after a countdown, so a
    /// rotation during the count is reflected).
    static func captureRecordTimeRotation(
        hold: String,
        captureDelta: Double,
        previewDelta: Double,
        isCalibrated: Bool,
        hasPreviewLayer: Bool
    ) {
        UserDefaults.standard.set(
            [
                "hold": hold,
                "captureDelta": captureDelta,
                "previewDelta": previewDelta,
                "isCalibrated": isCalibrated,
                "hasPreviewLayer": hasPreviewLayer
            ] as [String: Any],
            forKey: key
        )
    }

    /// Read back by the self-test. `nil` when no take has been recorded since
    /// install — the self-test then falls back to a live read and says so.
    static func recordTimeRotation() -> RecordTimeRotation? {
        guard let d = UserDefaults.standard.dictionary(forKey: key),
              let hold = d["hold"] as? String else { return nil }
        return RecordTimeRotation(
            hold: hold,
            captureDelta: d["captureDelta"] as? Double ?? 0,
            previewDelta: d["previewDelta"] as? Double ?? 0,
            isCalibrated: d["isCalibrated"] as? Bool ?? false,
            hasPreviewLayer: d["hasPreviewLayer"] as? Bool ?? false
        )
    }
}
#endif
