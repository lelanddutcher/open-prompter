//
//  RecordingState.swift
//  OpenPrompter
//
//  Tiny @Observable model that exposes a single `isRecording: Bool` flag.
//  Drives the on-screen tally light overlay (Feature 1, V2 Design 01
//  §"Tally-light border indicator").
//
//  Recording itself doesn't ship until Feature 2; this type lets us wire the
//  tally light NOW so design / accessibility / reduce-motion paths are
//  validated against a real flag rather than a stub. Feature 2 will replace
//  the Labs debug toggle with the real recording controller.
//

import Foundation
import Observation

@Observable
@MainActor
final class RecordingState {
    /// True while the prompter is recording. Currently flipped only via the
    /// debug toggle in `RecordingState.toggleForDebug()` until Feature 2
    /// lands the real recording controller.
    var isRecording: Bool = false

    /// Debug-only flip used by the tally-light Labs toggle in Settings.
    /// Production callers shouldn't use this — Feature 2 will wire the real
    /// session lifecycle to `isRecording` directly.
    func toggleForDebug() {
        isRecording.toggle()
    }
}
