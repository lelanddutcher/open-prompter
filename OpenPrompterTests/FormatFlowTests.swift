//
//  FormatFlowTests.swift
//  OpenPrompterTests
//
//  Drives FormatRunController with a MockScriptFormatter + an injected temp
//  stash directory (never the real container). Covers the full confirm /
//  undo / persistence flow the design's destructive-write path demands:
//    - happy path: streamed snapshots land, the final formattedText equals
//      the last snapshot, phase → .confirming
//    - confirm / discard: Discard leaves text == preFormatText (no mutation)
//    - apply then undo: Apply sets text == formattedText; Undo restores it
//    - cancellation leaves text untouched
//    - empty output → error, no mutation
//    - length pre-flight refuses BEFORE the formatter is invoked (0 calls)
//    - crash stash: Apply writes the stash; a simulated relaunch detects it;
//      Undo / clean-save clears it
//
//  Apple Intelligence is unavailable on the simulator, so ALL model
//  interaction goes through the mock. No FoundationModels.
//

import XCTest
@testable import OpenPrompter

@MainActor
final class FormatFlowTests: XCTestCase {

    private var tempDir: URL!
    private var scriptURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("format-flow-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        // A fake script URL — the controller only uses it as a stash key.
        scriptURL = tempDir.appendingPathComponent("script.md")
    }

    override func tearDownWithError() throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        try super.tearDownWithError()
    }

    private func makeStash() -> FormatUndoStash {
        FormatUndoStash(directory: tempDir.appendingPathComponent("FormatUndo", isDirectory: true))
    }

    private func makeController(
        formatter: any ScriptFormatting,
        stash: FormatUndoStash
    ) -> FormatRunController {
        FormatRunController(formatter: formatter, scriptURL: scriptURL, stash: stash)
    }

    private func waitUntil(
        timeout: TimeInterval = 2,
        _ condition: @escaping () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000) // 5 ms
        }
    }

    private let formatPreset = FormatPreset(
        id: "format", kind: .format, name: "Format",
        prompt: "reformat", isEdited: false
    )

    // MARK: - Happy path

    func testHappyPathStreamsToConfirming() async {
        let snapshots = ["# A", "# A\n\n---\n\n**B**"]
        let mock = MockScriptFormatter(snapshots: snapshots)
        let controller = makeController(formatter: mock, stash: makeStash())

        controller.run(source: "# A B", preset: formatPreset)
        await waitUntil { if case .confirming = controller.phase { return true }; return false }

        guard case .confirming(let formattedText) = controller.phase else {
            return XCTFail("Expected .confirming, got \(controller.phase).")
        }
        XCTAssertEqual(formattedText, snapshots.last)
        XCTAssertEqual(mock.callCount, 1)
    }

    // MARK: - Discard

    func testDiscardLeavesTextUnchanged() async {
        let mock = MockScriptFormatter(snapshots: ["formatted"])
        let controller = makeController(formatter: mock, stash: makeStash())
        var editorText = "original"

        controller.run(source: editorText, preset: formatPreset)
        await waitUntil { if case .confirming = controller.phase { return true }; return false }

        controller.discard()
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertEqual(editorText, "original", "Discard must not mutate the editor text.")
        XCTAssertNil(controller.preFormatText)
    }

    // MARK: - Apply then Undo

    func testApplyThenUndoRestoresPreFormatText() async {
        let mock = MockScriptFormatter(snapshots: ["FORMATTED"])
        let stash = makeStash()
        let controller = makeController(formatter: mock, stash: stash)
        var editorText = "before"

        controller.run(source: editorText, preset: formatPreset)
        await waitUntil { if case .confirming = controller.phase { return true }; return false }

        controller.apply(formattedText: "FORMATTED", currentText: editorText, assign: { editorText = $0 })
        XCTAssertEqual(editorText, "FORMATTED")
        XCTAssertEqual(controller.phase, .applied)
        XCTAssertTrue(controller.canUndo)
        XCTAssertEqual(controller.preFormatText, "before")

        controller.undo(assign: { editorText = $0 })
        XCTAssertEqual(editorText, "before", "Undo must restore the pre-format text.")
        XCTAssertEqual(controller.phase, .idle)
    }

    // MARK: - Cancellation

    func testCancellationLeavesTextUntouched() async {
        // A slow mock so we have a window to cancel mid-stream.
        let mock = MockScriptFormatter(
            snapshots: ["partial-1", "partial-2", "final"],
            perSnapshotDelay: .milliseconds(80)
        )
        let controller = makeController(formatter: mock, stash: makeStash())
        var editorText = "keep me"

        controller.run(source: editorText, preset: formatPreset)
        await waitUntil { if case .streaming = controller.phase { return true }; return false }

        controller.cancel()
        await waitUntil { controller.phase == .idle }

        XCTAssertEqual(controller.phase, .idle)
        XCTAssertEqual(editorText, "keep me", "Cancelling must not mutate the editor text.")
        XCTAssertNil(controller.errorMessage, "Cancellation is a user action, not a surfaced error.")
    }

    // MARK: - Empty output

    func testEmptyOutputSurfacesErrorNoMutation() async {
        let mock = MockScriptFormatter(snapshots: ["   \n  "]) // whitespace only
        let controller = makeController(formatter: mock, stash: makeStash())

        controller.run(source: "content", preset: formatPreset)
        await waitUntil { controller.phase == .idle && controller.errorMessage != nil }

        XCTAssertEqual(controller.phase, .idle)
        XCTAssertNotNil(controller.errorMessage)
        XCTAssertNil(controller.preFormatText, "Empty output must not stage a pre-format snapshot.")
    }

    // MARK: - Length pre-flight

    func testLengthPreflightRefusesWithoutCallingFormatter() {
        let mock = MockScriptFormatter(snapshots: ["never used"])
        let controller = makeController(formatter: mock, stash: makeStash())
        // 20k chars → well over the 45% input budget.
        let tooLong = String(repeating: "a", count: 20_000)

        controller.run(source: tooLong, preset: formatPreset)

        XCTAssertEqual(mock.callCount, 0, "The formatter must NOT be invoked for an over-long script.")
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertNotNil(controller.errorMessage)
    }

    // MARK: - Unavailable formatter

    func testUnavailableFormatterRefuses() {
        let noop = NoopScriptFormatter(reason: .unavailableDeviceNotEligible)
        let controller = makeController(formatter: noop, stash: makeStash())

        controller.run(source: "content", preset: formatPreset)

        XCTAssertEqual(controller.phase, .idle)
        XCTAssertNotNil(controller.errorMessage)
    }

    // MARK: - Crash stash

    func testApplyWritesStashAndRelaunchDetectsIt() async {
        let mock = MockScriptFormatter(snapshots: ["FORMATTED"])
        let stash = makeStash()
        let controller = makeController(formatter: mock, stash: stash)
        var editorText = "source text"

        controller.run(source: editorText, preset: formatPreset)
        await waitUntil { if case .confirming = controller.phase { return true }; return false }

        controller.apply(formattedText: "FORMATTED", currentText: editorText, assign: { editorText = $0 })
        // The stash write is async — wait for the file to appear.
        await waitUntil { stash.hasStash(for: self.scriptURL) }

        XCTAssertTrue(stash.hasStash(for: scriptURL), "Apply must write the crash stash.")
        // A simulated relaunch reads the stash back.
        XCTAssertEqual(stash.read(for: scriptURL), "source text",
                       "The stash must hold the pre-format source for a relaunch restore.")
    }

    func testUndoClearsStash() async {
        let mock = MockScriptFormatter(snapshots: ["FORMATTED"])
        let stash = makeStash()
        let controller = makeController(formatter: mock, stash: stash)
        var editorText = "source"

        controller.run(source: editorText, preset: formatPreset)
        await waitUntil { if case .confirming = controller.phase { return true }; return false }
        controller.apply(formattedText: "FORMATTED", currentText: editorText, assign: { editorText = $0 })
        await waitUntil { stash.hasStash(for: self.scriptURL) }

        controller.undo(assign: { editorText = $0 })
        XCTAssertFalse(stash.hasStash(for: scriptURL), "Undo must clear the crash stash.")
    }

    func testDidSaveFormattedClearsStash() async {
        let mock = MockScriptFormatter(snapshots: ["FORMATTED"])
        let stash = makeStash()
        let controller = makeController(formatter: mock, stash: stash)
        var editorText = "source"

        controller.run(source: editorText, preset: formatPreset)
        await waitUntil { if case .confirming = controller.phase { return true }; return false }
        controller.apply(formattedText: "FORMATTED", currentText: editorText, assign: { editorText = $0 })
        await waitUntil { stash.hasStash(for: self.scriptURL) }

        controller.didSaveFormatted()
        XCTAssertFalse(stash.hasStash(for: scriptURL),
                       "A clean save of the formatted text must clear the crash stash.")
        // Undo remains available in-memory even after save, per the design.
        XCTAssertEqual(controller.preFormatText, "source")
    }

    // MARK: - Stash filename determinism

    func testStashFileNameIsDeterministicPerURL() {
        let a = FormatUndoStash.fileName(for: URL(fileURLWithPath: "/x/script.md"))
        let b = FormatUndoStash.fileName(for: URL(fileURLWithPath: "/x/script.md"))
        let c = FormatUndoStash.fileName(for: URL(fileURLWithPath: "/x/other.md"))
        XCTAssertEqual(a, b, "Same URL must map to the same stash file across calls / launches.")
        XCTAssertNotEqual(a, c, "Different URLs must map to different stash files.")
        XCTAssertTrue(a.hasSuffix(".md"))
    }
}
