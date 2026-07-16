//
//  RemoteWizardModelTests.swift
//  OpenPrompterTests
//
//  Tests the "Learn your remote" wizard's capture→bind engine (v3). The model
//  is deliberately SwiftUI-free so the whole flow — capture a key, commit,
//  advance, skip, redo, finish, and the scroll→line-step binding mapping — is
//  exercised without standing up a view.
//

import XCTest
@testable import OpenPrompter

@MainActor
final class RemoteWizardModelTests: XCTestCase {

    private func makeStore() -> RemoteBindingStore {
        let suite = "RemoteWizardModelTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return RemoteBindingStore(defaults: defaults)
    }

    // MARK: - boundEvent mapping

    func testScrollStepsBindToLineStepEvents() {
        // Scroll Up / Down steps bind the pressed KEY to the one-line-step
        // events (lineUp / lineDown), NOT the pointer-only scroll vocabulary.
        let up = RemoteWizardStep.coreSteps.first { $0.event == .scrollUp }!
        let down = RemoteWizardStep.coreSteps.first { $0.event == .scrollDown }!
        XCTAssertEqual(up.boundEvent, .lineUp)
        XCTAssertEqual(down.boundEvent, .lineDown)
    }

    func testNonScrollStepsBindToOwnEvent() {
        let play = RemoteWizardStep.coreSteps.first { $0.event == .playPause }!
        let record = RemoteWizardStep.coreSteps.first { $0.event == .recordToggle }!
        XCTAssertEqual(play.boundEvent, .playPause)
        XCTAssertEqual(record.boundEvent, .recordToggle)
    }

    func testCoreStepsAreInOrderPlayScrollRecord() {
        XCTAssertEqual(
            RemoteWizardModel(bindings: makeStore()).steps.map(\.event),
            [.playPause, .scrollUp, .scrollDown, .recordToggle]
        )
    }

    // MARK: - capture

    func testCaptureStoresLatestKeyAndSource() {
        let model = RemoteWizardModel(bindings: makeStore())
        model.capture(.arrowUp, source: "keyboard")
        XCTAssertEqual(model.capturedKey, .arrowUp)
        XCTAssertEqual(model.capturedSource, "keyboard")

        // Latest press wins — pressing a different button just fixes a mistake.
        model.capture(.space, source: "keyboard")
        XCTAssertEqual(model.capturedKey, .space)
    }

    func testPointerScrollNoteIsShadowedByARealKey() {
        let model = RemoteWizardModel(bindings: makeStore())
        model.capturePointerScroll()
        XCTAssertTrue(model.capturedPointerScroll)
        XCTAssertNil(model.capturedKey)

        // A real key press afterwards wins and clears the pointer note.
        model.capture(.space, source: "keyboard")
        XCTAssertFalse(model.capturedPointerScroll)
        XCTAssertEqual(model.capturedKey, .space)

        // And once a key is captured, a later pointer-scroll can't clobber it.
        model.capturePointerScroll()
        XCTAssertEqual(model.capturedKey, .space)
        XCTAssertFalse(model.capturedPointerScroll)
    }

    // MARK: - commit / advance / skip / redo

    func testCommitWritesBindingAndAdvances() {
        let store = makeStore()
        let model = RemoteWizardModel(bindings: store)
        // Step 0 is Play/Pause. Bind the Escape key to it.
        XCTAssertEqual(model.currentStep.event, .playPause)
        model.capture(.escape, source: "keyboard")
        model.commitAndAdvance()

        XCTAssertEqual(store.event(for: .escape), .playPause,
                       "committing must write the captured key → step event into the store")
        // Advanced to step 1 with a cleared capture.
        XCTAssertEqual(model.stepIndex, 1)
        XCTAssertEqual(model.currentStep.event, .scrollUp)
        XCTAssertNil(model.capturedKey)
    }

    func testCommitOnScrollStepBindsLineStep() {
        let store = makeStore()
        let model = RemoteWizardModel(bindings: store)
        model.skip()                       // past play/pause → scrollUp
        XCTAssertEqual(model.currentStep.event, .scrollUp)
        model.capture(.arrowUp, source: "keyboard")
        model.commitAndAdvance()
        // The KEY is bound to the LINE-step event, not .scrollUp.
        XCTAssertEqual(store.event(for: .arrowUp), .lineUp)
    }

    func testSkipDoesNotChangeBinding() {
        let store = makeStore()
        // Pre-seed a known binding for space (play/pause default).
        let before = store.event(for: .space)
        let model = RemoteWizardModel(bindings: store)
        model.capture(.space, source: "keyboard") // captured but NOT committed
        model.skip()
        XCTAssertEqual(store.event(for: .space), before,
                       "skip must leave existing bindings untouched")
        XCTAssertEqual(model.stepIndex, 1)
    }

    func testRedoClearsCurrentCapture() {
        let model = RemoteWizardModel(bindings: makeStore())
        model.capture(.arrowUp, source: "keyboard")
        model.redo()
        XCTAssertNil(model.capturedKey)
        XCTAssertNil(model.capturedSource)
        XCTAssertFalse(model.capturedPointerScroll)
        XCTAssertEqual(model.stepIndex, 0, "redo does not advance")
    }

    func testFullFlowBindsRecordToggleAndFinishes() {
        let store = makeStore()
        let model = RemoteWizardModel(bindings: store)

        // Play/Pause → letter p
        model.capture(.letter("p"), source: "keyboard")
        model.commitAndAdvance()
        // Scroll Up → arrow up
        model.capture(.arrowUp, source: "keyboard")
        model.commitAndAdvance()
        // Scroll Down → arrow down
        model.capture(.arrowDown, source: "keyboard")
        model.commitAndAdvance()
        // Record → letter x (proves record is a bindable action via the wizard)
        XCTAssertEqual(model.currentStep.event, .recordToggle)
        XCTAssertFalse(model.isFinished)
        model.capture(.letter("x"), source: "keyboard")
        model.commitAndAdvance()

        XCTAssertTrue(model.isFinished, "committing the last step finishes the flow")
        XCTAssertEqual(store.event(for: .letter("p")), .playPause)
        XCTAssertEqual(store.event(for: .arrowUp), .lineUp)
        XCTAssertEqual(store.event(for: .arrowDown), .lineDown)
        XCTAssertEqual(store.event(for: .letter("x")), .recordToggle,
                       "the wizard's RECORD slot binds a key to .recordToggle")
    }

    func testSkippingAllStepsFinishesWithoutBinding() {
        let store = makeStore()
        let model = RemoteWizardModel(bindings: store)
        // No unrelated key should get bound if the user skips everything.
        model.skip(); model.skip(); model.skip(); model.skip()
        XCTAssertTrue(model.isFinished)
        // letter x was never touched.
        XCTAssertNil(store.event(for: .letter("x")))
    }

    // MARK: - currentBoundKey readout

    func testCurrentBoundKeyReflectsExistingBinding() {
        let store = makeStore()
        // Default: space → playPause. Step 0 targets playPause.
        let model = RemoteWizardModel(bindings: store)
        // allBindings is sorted by key.id; the first playPause key is what the
        // row shows. Just assert it resolves to SOME key bound to playPause.
        let key = model.currentBoundKey
        XCTAssertNotNil(key)
        XCTAssertEqual(store.event(for: key!), .playPause)
    }
}
