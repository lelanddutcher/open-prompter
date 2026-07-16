//
//  PrompterFontTests.swift
//  OpenPrompterTests
//
//  Guards the synthetic-italic (oblique) path used for the bundled faces
//  (Atkinson, Lexend) that ship Regular + Bold only. The first cut baked the
//  point size into the shear matrix AND passed it through a sized descriptor,
//  scaling glyphs by size² — a 32pt italic rendered ~1024pt and one letter
//  filled the screen. These tests pin that the shear preserves the size.
//

import XCTest
#if canImport(UIKit)
import UIKit
#endif
@testable import OpenPrompter

final class PrompterFontTests: XCTestCase {

    #if canImport(UIKit)
    /// The oblique shear must NOT rescale the glyphs — vertical metrics must
    /// match the upright base. Uses Helvetica (always present on the test host)
    /// so the test is independent of whether the bundled TTFs registered.
    func testObliquePreservesSize() {
        guard let base = UIFont(name: "Helvetica", size: 40) else {
            XCTFail("Helvetica unavailable on test host")
            return
        }
        let oblique = PrompterFont.oblique(base)
        XCTAssertEqual(oblique.pointSize, base.pointSize, accuracy: 0.5,
                       "oblique point size drifted from the requested size")
        XCTAssertEqual(oblique.capHeight, base.capHeight, accuracy: 1.5,
                       "oblique changed the vertical scale — the size² regression")
        XCTAssertEqual(oblique.lineHeight, base.lineHeight, accuracy: 2.0,
                       "oblique line height drifted — vertical scale changed")
    }

    // Note: we deliberately do NOT assert the shear via
    // `UIFont.fontDescriptor.matrix` — that property reports identity after the
    // font is realized (the matrix is applied at render time but doesn't
    // round-trip back through the descriptor). The slant is verified visually
    // on device; these tests guard the size, which is what regressed.

    /// Scale-independence across sizes: at any size the oblique cap height
    /// should track the upright cap height at that same size (never size²).
    func testObliqueSizeIndependence() {
        for size: CGFloat in [16, 48, 120, 160] {
            guard let base = UIFont(name: "Helvetica", size: size) else { continue }
            let oblique = PrompterFont.oblique(base)
            XCTAssertEqual(oblique.capHeight, base.capHeight, accuracy: max(1.5, size * 0.05),
                           "oblique cap height diverged at \(size)pt")
        }
    }
    #endif
}
