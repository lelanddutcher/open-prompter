//
//  ScriptFormatterErrorMappingTests.swift
//  OpenPrompterTests
//
//  A mock that throws a "context exceeded"-shaped error surfaces the
//  "format a section at a time" guidance (mapped to .outputTooLong); a
//  generic error surfaces its message (.underlying). Verified end-to-end
//  through FormatRunController so the mapping proves out on the real
//  error-handling path, not just the pure mapper.
//

import XCTest
@testable import OpenPrompter

@MainActor
final class ScriptFormatterErrorMappingTests: XCTestCase {

    private let scriptURL = URL(fileURLWithPath: "/tmp/format-error-mapping/script.md")

    private var stashDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        stashDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("format-error-mapping-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        if let stashDir { try? FileManager.default.removeItem(at: stashDir) }
        try super.tearDownWithError()
    }

    private func makeController(throwing error: Error) -> FormatRunController {
        let mock = MockScriptFormatter(snapshots: [], errorToThrow: error)
        return FormatRunController(
            formatter: mock,
            scriptURL: scriptURL,
            stash: FormatUndoStash(directory: stashDir)
        )
    }

    private func waitUntil(
        timeout: TimeInterval = 2,
        _ condition: @escaping () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    private let preset = FormatPreset(
        id: "format", kind: .format, name: "Format", prompt: "rules", isEdited: false
    )

    // MARK: - Pure mapper

    func testMapperContextExceeded() {
        XCTAssertEqual(FormatErrorMapper.map(description: "Exceeded the model context window"), .outputTooLong)
    }

    func testMapperGeneric() {
        XCTAssertEqual(FormatErrorMapper.map(description: "some other failure"),
                       .underlying("some other failure"))
    }

    // MARK: - Through the controller

    func testControllerSurfacesOutputTooLongGuidance() async {
        struct ContextError: LocalizedError {
            var errorDescription: String? { "The prompt exceeds the context window." }
        }
        let controller = makeController(throwing: ContextError())

        controller.run(source: "short source", preset: preset)
        await waitUntil { controller.phase == .idle && controller.errorMessage != nil }

        XCTAssertEqual(controller.errorMessage, FormatError.outputTooLong.userMessage)
    }

    func testControllerSurfacesUnderlyingMessage() async {
        struct GenericError: LocalizedError {
            var errorDescription: String? { "disk full" }
        }
        let controller = makeController(throwing: GenericError())

        controller.run(source: "short source", preset: preset)
        await waitUntil { controller.phase == .idle && controller.errorMessage != nil }

        XCTAssertEqual(controller.errorMessage, FormatError.underlying("disk full").userMessage)
    }

    func testControllerPassesThroughTypedFormatError() async {
        // If the formatter throws a FormatError directly (e.g. .emptyOutput
        // from a partial stream), the controller preserves it rather than
        // re-mapping its description.
        let controller = makeController(throwing: FormatError.outputTooLong)

        controller.run(source: "short source", preset: preset)
        await waitUntil { controller.phase == .idle && controller.errorMessage != nil }

        XCTAssertEqual(controller.errorMessage, FormatError.outputTooLong.userMessage)
    }
}
