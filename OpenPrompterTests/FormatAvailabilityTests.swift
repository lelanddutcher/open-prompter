//
//  FormatAvailabilityTests.swift
//  OpenPrompterTests
//
//  Covers the OS-agnostic availability seam for on-device Format:
//    - NoopScriptFormatter reports the passed reason; isAvailable == false;
//      formatStream finishes throwing .unavailable(reason)
//    - FormatAvailability.isUserFixable is true ONLY for
//      .unavailableAppleIntelligenceOff
//    - the error mapper routes "context exceeded"-shaped errors to
//      .outputTooLong and everything else to .underlying
//    - the token pre-flight budget refuses over-long input
//
//  Everything here compiles + runs on any OS / CI — no FoundationModels,
//  no Apple Intelligence.
//

import XCTest
@testable import OpenPrompter

final class FormatAvailabilityTests: XCTestCase {

    // MARK: - Noop formatter

    func testNoopReportsPassedReasonAndIsUnavailable() {
        let noop = NoopScriptFormatter(reason: .unavailableDeviceNotEligible)
        XCTAssertEqual(noop.availability, .unavailableDeviceNotEligible)
        XCTAssertFalse(noop.availability.isAvailable)
    }

    func testNoopDefaultReasonIsOSTooOld() {
        XCTAssertEqual(NoopScriptFormatter().availability, .unavailableOSTooOld)
    }

    func testNoopStreamThrowsUnavailable() async {
        let noop = NoopScriptFormatter(reason: .unavailableModelNotReady)
        do {
            for try await _ in noop.formatStream(source: "hi", prompt: "rules") {
                XCTFail("Noop formatter must not yield any snapshot.")
            }
            XCTFail("Noop formatter must finish by throwing.")
        } catch let error as FormatError {
            XCTAssertEqual(error, .unavailable(.unavailableModelNotReady))
        } catch {
            XCTFail("Expected FormatError.unavailable, got \(error).")
        }
    }

    // MARK: - isUserFixable

    func testIsUserFixableOnlyForAppleIntelligenceOff() {
        XCTAssertTrue(FormatAvailability.unavailableAppleIntelligenceOff.isUserFixable)

        let others: [FormatAvailability] = [
            .available,
            .unavailableOSTooOld,
            .unavailableDeviceNotEligible,
            .unavailableModelNotReady,
            .unavailableOther("x"),
            .unavailableDisabledInLabs
        ]
        for availability in others {
            XCTAssertFalse(availability.isUserFixable,
                           "\(availability) must not be user-fixable.")
        }
    }

    func testOnlyAvailableIsAvailable() {
        XCTAssertTrue(FormatAvailability.available.isAvailable)
        XCTAssertFalse(FormatAvailability.unavailableOSTooOld.isAvailable)
        XCTAssertFalse(FormatAvailability.unavailableDisabledInLabs.isAvailable)
    }

    func testDiagnosticSummariesAreNonEmpty() {
        let all: [FormatAvailability] = [
            .available, .unavailableOSTooOld, .unavailableDeviceNotEligible,
            .unavailableAppleIntelligenceOff, .unavailableModelNotReady,
            .unavailableOther("detail"), .unavailableDisabledInLabs
        ]
        for availability in all {
            XCTAssertFalse(availability.diagnosticSummary.isEmpty)
        }
    }

    // MARK: - Error mapping

    func testContextExceededMapsToOutputTooLong() {
        XCTAssertEqual(FormatErrorMapper.map(description: "The context window was exceeded"), .outputTooLong)
        XCTAssertEqual(FormatErrorMapper.map(description: "prompt is too long"), .outputTooLong)
        XCTAssertEqual(FormatErrorMapper.map(description: "Token limit reached"), .outputTooLong)
    }

    func testGenericErrorMapsToUnderlying() {
        XCTAssertEqual(FormatErrorMapper.map(description: "network glitch"),
                       .underlying("network glitch"))
    }

    // MARK: - Token pre-flight

    func testShortSourceFitsBudget() {
        let short = String(repeating: "word ", count: 50) // ~250 chars
        XCTAssertTrue(FormatTokenBudget.fitsBudget(source: short, instructions: "rules"))
        XCTAssertEqual(FormatTokenBudget.wordsOverLimit(source: short, instructions: "rules"), 0)
    }

    func testLongSourceExceedsBudget() {
        // Well past 45% of the 4096-token window at ~4 chars/token.
        let long = String(repeating: "a", count: 20_000)
        XCTAssertFalse(FormatTokenBudget.fitsBudget(source: long, instructions: "rules"))
        XCTAssertGreaterThan(FormatTokenBudget.wordsOverLimit(source: long, instructions: "rules"), 0)
    }

    func testEstimatedTokensNeverZeroForNonEmpty() {
        XCTAssertEqual(FormatTokenBudget.estimatedTokens(for: ""), 0)
        XCTAssertGreaterThanOrEqual(FormatTokenBudget.estimatedTokens(for: "a"), 1)
    }
}
