//
//  ScriptFormatterFactory.swift
//  OpenPrompter
//
//  Chooses the concrete `ScriptFormatting` at runtime: the real
//  FoundationModels-backed formatter on iOS 26+, the always-unavailable noop
//  everywhere else. The `#available` check is the FIRST of the three gating
//  axes in the design doc (OS → model availability → device class); the
//  latter two live inside `SystemModelScriptFormatter.availability`.
//
//  No FoundationModels import here — the type reference to
//  `SystemModelScriptFormatter` is only reachable under the `#available`
//  branch, and that type is itself `@available(iOS 26, *)`, so this file
//  compiles down to iOS 17.
//

import Foundation

enum ScriptFormatterFactory {
    /// Build the formatter appropriate for the running OS. The editor calls
    /// this once and holds the result; tests inject a `MockScriptFormatter`
    /// directly instead of going through the factory.
    static func make() -> any ScriptFormatting {
        if #available(iOS 26, *) {
            return SystemModelScriptFormatter()
        }
        return NoopScriptFormatter(reason: .unavailableOSTooOld)
    }
}
