import XCTest
@testable import OpenPrompter

/// Regression tests for the voice-follow catch-up floor introduced in PR #9.
///
/// The floor exists because a pure P-controller crawls asymptotically when the
/// acknowledged word falls far behind the READ line. It must ramp in only on
/// REAL positive lag — the original formulation went permanently active for
/// anyone who dragged the READ line below mid-screen.
final class VoiceCatchUpFloorTests: XCTestCase {

    private let vh: CGFloat = 800
    private let maxVel: CGFloat = 300

    private func floor(lag: CGFloat, readFraction: CGFloat) -> CGFloat {
        AutoScroller.catchUpFloor(
            lag: lag, readY: vh * readFraction,
            viewportHeight: vh, maxVelocity: maxVel
        )
    }

    func testNoFloorAtZeroLagAtDefaultReadPosition() {
        XCTAssertEqual(floor(lag: 0, readFraction: 0.05), 0)
    }

    /// The bug: READ dragged below mid-screen made `halfway` negative, so the
    /// floor engaged at zero lag. It must stay off.
    func testNoFloorAtZeroLagWhenReadLineIsBelowMidScreen() {
        for rf in [CGFloat(0.6), 0.7, 0.85, 0.95] {
            XCTAssertEqual(floor(lag: 0, readFraction: rf), 0, accuracy: 0.0001,
                           "READ at \(rf) must not arm the floor with no lag")
        }
    }

    func testNoFloorWhenScrollIsAheadOfTheWord() {
        XCTAssertEqual(floor(lag: -200, readFraction: 0.7), 0)
    }

    func testFloorRampsInOnRealLag() {
        let small = floor(lag: 380, readFraction: 0.05)   // just past halfway (360)
        let large = floor(lag: 600, readFraction: 0.05)
        XCTAssertGreaterThan(large, small, "more lag must mean more floor")
        XCTAssertGreaterThan(small, 0)
    }

    func testFloorIsCappedAtSixtyPercentOfMaxVelocity() {
        XCTAssertEqual(floor(lag: 10_000, readFraction: 0.05), maxVel * 0.6, accuracy: 0.0001)
    }

    func testDegenerateViewportIsSafe() {
        XCTAssertEqual(
            AutoScroller.catchUpFloor(lag: 500, readY: 0, viewportHeight: 0, maxVelocity: maxVel), 0
        )
    }
}
