//
//  PrompterViewModelLineNavTests.swift
//  OpenPrompterTests
//
//  Covers the line-step navigation added for the remote-nav robustness pass
//  (audit fix 4 / R3): lineUp/lineDown seek by ~fontSize*1.6, scrollUp/Down
//  route to those line steps, and nextSection falls back to a half-viewport
//  jump on heading-less scripts so a media Next never silently no-ops.
//

import XCTest
@testable import OpenPrompter

@MainActor
final class PrompterViewModelLineNavTests: XCTestCase {

    private func makeViewModel(fontSize: Double = 50) -> PrompterViewModel {
        let url = URL(fileURLWithPath: "/tmp/open-prompter-linenav-\(UUID().uuidString).md")
        let file = ScriptFile(id: url, name: url.lastPathComponent, mtime: .now, downloadState: .current)
        let vm = PrompterViewModel(file: file)
        vm.contentHeight = 4000
        vm.viewportHeight = 500
        vm.fontSize = fontSize
        return vm
    }

    // MARK: - lineStep math

    func testLineStepIsFontSizeTimesOnePointSix() {
        let vm = makeViewModel(fontSize: 50)
        XCTAssertEqual(vm.lineStep, 80, accuracy: 0.001) // 50 * 1.6
    }

    func testLineDownAdvancesByOneLine() {
        let vm = makeViewModel(fontSize: 50)
        vm.scroller.seek(to: 1000, maxOffset: vm.maxScrollOffset)
        vm.lineDown()
        XCTAssertEqual(vm.scroller.offset, 1080, accuracy: 0.001) // +80
    }

    func testLineUpRetreatsByOneLine() {
        let vm = makeViewModel(fontSize: 50)
        vm.scroller.seek(to: 1000, maxOffset: vm.maxScrollOffset)
        vm.lineUp()
        XCTAssertEqual(vm.scroller.offset, 920, accuracy: 0.001) // -80
    }

    func testLineStepIsMuchSmallerThanHalfViewportJump() {
        // The whole point of the feature: a line step is fine, a jump is coarse.
        let vm = makeViewModel(fontSize: 50)
        XCTAssertLessThan(vm.lineStep, vm.viewportHeight * 0.5)
    }

    // MARK: - scroll* routes to line steps (not jumps)

    func testScrollDownEventTakesOneLineStep() {
        let vm = makeViewModel(fontSize: 50)
        vm.scroller.seek(to: 1000, maxOffset: vm.maxScrollOffset)
        vm.handleRemoteEvent(.scrollDown)
        XCTAssertEqual(vm.scroller.offset, 1080, accuracy: 0.001)
    }

    func testScrollUpEventTakesOneLineStep() {
        let vm = makeViewModel(fontSize: 50)
        vm.scroller.seek(to: 1000, maxOffset: vm.maxScrollOffset)
        vm.handleRemoteEvent(.scrollUp)
        XCTAssertEqual(vm.scroller.offset, 920, accuracy: 0.001)
    }

    func testLineDownEventMatchesLineDownCall() {
        let vm = makeViewModel(fontSize: 40)
        vm.scroller.seek(to: 500, maxOffset: vm.maxScrollOffset)
        vm.handleRemoteEvent(.lineDown)
        XCTAssertEqual(vm.scroller.offset, 564, accuracy: 0.001) // +40*1.6
    }

    // MARK: - nextSection heading-less fallback

    func testNextSectionFallsBackToJumpWhenNoHeadings() {
        let vm = makeViewModel()
        // Body-only script — no headings at all.
        vm.parsed = ParsedScript(blocks: [
            .paragraph(StyledText(plain: "one")),
            .paragraph(StyledText(plain: "two")),
            .paragraph(StyledText(plain: "three"))
        ])
        vm.scroller.seek(to: 1000, maxOffset: vm.maxScrollOffset)
        vm.nextSection()
        // Fallback is a half-viewport jump (+250), NOT a silent no-op.
        XCTAssertEqual(vm.scroller.offset, 1250, accuracy: 0.001)
    }

    func testNextSectionSeeksHeadingWhenPresent() {
        let vm = makeViewModel()
        vm.parsed = ParsedScript(blocks: [
            .paragraph(StyledText(plain: "intro")),
            .heading(level: 1, text: "Section Two"),
            .paragraph(StyledText(plain: "body"))
        ])
        // At the top, currentBlockIndex is 0; nextSection should move to the
        // heading at index 1 (a positive seek), not the jump fallback.
        vm.scroller.seek(to: 0, maxOffset: vm.maxScrollOffset)
        vm.nextSection()
        XCTAssertGreaterThan(vm.scroller.offset, 0)
    }
}
