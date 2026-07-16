//
//  GCMouseSource.swift
//  OpenPrompter
//
//  Pointer / trackpad remote source (BLE-M5 Capture.md — the founder's remote).
//
//  ╭──────────────────────────── WHY THIS EXISTS ───────────────────────────╮
//  │ The founder's BLE-M5 D-pad is NOT a keyboard. HID capture on macOS      │
//  │ (BLE-M5 Capture.md) proved it emits Generic-Desktop pointer X/Y axis    │
//  │ movement (`0x30` / `0x31`) plus digitizer taps (`0x42` Tip Switch) —    │
//  │ i.e. iOS sees a MOUSE, not arrow keys. A `GCKeyboard`-only remote layer │
//  │ would capture the shutter's-cousin keyboards but MISS this D-pad        │
//  │ entirely: its directional navigation would silently do nothing.        │
//  │                                                                        │
//  │ This source captures `GCMouse` via GameController: pointer deltas +     │
//  │ scroll wheel → one-line scroll navigation, and buttons (the D-pad       │
//  │ CENTER and AUX SHUTTER are digitizer taps → mouse clicks) → a bindable  │
//  │ `RemoteKey` (`mouseClick` / `mouseRightClick` / `mouseMiddleClick`).    │
//  │ Focus-independent, like `GameControllerKeyboardSource`.                 │
//  ╰────────────────────────────────────────────────────────────────────────╯
//
//  Delta accumulation: pointer / scroll deltas arrive as a continuous stream
//  of small floats, not discrete presses. We integrate them and emit ONE
//  line-step event each time the accumulated magnitude crosses a threshold,
//  then subtract the threshold (keeping the remainder). This turns a smooth
//  drag into evenly-spaced, predictable line steps instead of a firehose.
//

import Foundation
import GameController
import os

#if DEBUG
/// Shared `[Remote-Capture]` channel (see VolumeEventSource for rationale).
/// Filter Console on subsystem `app.openprompter.remote` to trace whether the
/// GCMouse handlers attach and whether iOS delivers ANY pointer movement for
/// the founder's BLE-M5 D-pad.
fileprivate let remoteCaptureLog = Logger(
    subsystem: "app.openprompter.remote",
    category: "Remote-Capture"
)
#endif

@MainActor
final class GCMouseSource: RemoteEventSource {
    private let bus: RemoteEventBus
    private let store: RemoteBindingStore

    /// Optional tap invoked with the resolved `RemoteKey` for every handled
    /// pointer BUTTON (click), before the binding lookup — the Labs capture
    /// tool subscribes so unmapped pointer buttons still surface. `nil` in
    /// the normal prompter path. `@MainActor` to match every caller / sink.
    private let onCapture: (@MainActor (RemoteKey) -> Void)?

    /// Optional tap invoked with each emitted scroll direction (pointer /
    /// wheel travel that crossed a step threshold). Scroll travel has no
    /// bindable `RemoteKey`, so the capture tool observes it through this
    /// dedicated hook to SHOW the founder's D-pad axes moving. `nil` in the
    /// normal prompter path.
    private let onScrollCapture: (@MainActor (RemoteEvent) -> Void)?

    /// DEBUG diagnostic tap: fired with the RAW `(dx, dy)` of EVERY pointer
    /// move, BEFORE threshold integration. The capture tool uses it to show a
    /// live delta counter so the founder can see whether iOS delivers ANY
    /// GCMouse movement for the BLE-M5 D-pad — conclusive even when a nudge is
    /// below the scroll-step threshold (which would emit nothing on its own).
    /// `nil` in the normal prompter path.
    private let onRawPointer: (@MainActor (Float, Float) -> Void)?

    private var started: Bool = false
    private var attachedMouse: GCMouse?

    private var connectObserver: NSObjectProtocol?
    private var disconnectObserver: NSObjectProtocol?

    /// Accumulated vertical pointer travel since the last emitted step, in the
    /// mouse's own delta units. Reset by the threshold subtraction, not zeroed,
    /// so continuous motion produces evenly-spaced steps.
    private var pointerAccumulator: Float = 0
    /// Same for the scroll wheel, which reports in a different unit scale.
    private var scrollAccumulator: Float = 0

    /// Magnitude of accumulated pointer delta that equals one line step. Tuned
    /// so a deliberate D-pad nudge on the BLE-M5 (a short axis stream) lands
    /// one line, not a page. `internal static` so the tuning is unit-testable.
    /// `nonisolated` so referencing it as a default-argument value never trips
    /// the "main-actor static referenced from a nonisolated context" check —
    /// it's an immutable `Sendable` constant with no actor state.
    nonisolated static let pointerStepThreshold: Float = 12
    /// Scroll wheel reports coarser detents; one notch is roughly one step.
    nonisolated static let scrollStepThreshold: Float = 1

    init(
        bus: RemoteEventBus,
        store: RemoteBindingStore,
        onCapture: (@MainActor (RemoteKey) -> Void)? = nil,
        onScrollCapture: (@MainActor (RemoteEvent) -> Void)? = nil,
        onRawPointer: (@MainActor (Float, Float) -> Void)? = nil
    ) {
        self.bus = bus
        self.store = store
        self.onCapture = onCapture
        self.onScrollCapture = onScrollCapture
        self.onRawPointer = onRawPointer
    }

    func start() {
        guard !started else { return }
        started = true

        #if DEBUG
        remoteCaptureLog.info("mouse.start — GCMouse present=\(GCMouse.current != nil || !GCMouse.mice().isEmpty, privacy: .public) count=\(GCMouse.mice().count, privacy: .public)")
        #endif

        attachHandlersIfPossible()

        connectObserver = NotificationCenter.default.addObserver(
            forName: .GCMouseDidConnect,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // `guard let self` keeps the `assumeIsolated` closure returning
            // Void — a bare `self?.method()` yields `Void?`, whose unused
            // result the compiler flags on the non-`@discardableResult`
            // `assumeIsolated`.
            MainActor.assumeIsolated {
                guard let self else { return }
                self.attachHandlersIfPossible()
            }
        }
        disconnectObserver = NotificationCenter.default.addObserver(
            forName: .GCMouseDidDisconnect,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.detachHandlers()
            }
        }
    }

    func stop() {
        guard started else { return }
        started = false
        detachHandlers()
        if let o = connectObserver { NotificationCenter.default.removeObserver(o) }
        if let o = disconnectObserver { NotificationCenter.default.removeObserver(o) }
        connectObserver = nil
        disconnectObserver = nil
        pointerAccumulator = 0
        scrollAccumulator = 0
    }

    // MARK: - Handler attach / detach

    private func attachHandlersIfPossible() {
        guard let mouse = GCMouse.current ?? GCMouse.mice().first,
              let input = mouse.mouseInput else {
            #if DEBUG
            remoteCaptureLog.error("mouse.attach FAILED — no usable GCMouse (current=\(GCMouse.current != nil, privacy: .public) mice=\(GCMouse.mice().count, privacy: .public))")
            #endif
            return
        }
        if attachedMouse != nil {
            #if DEBUG
            remoteCaptureLog.info("mouse.attach skipped — handlers already attached")
            #endif
            return
        }
        attachedMouse = mouse

        #if DEBUG
        remoteCaptureLog.info("mouse.attach OK — movement / scroll / button handlers wired")
        #endif

        // Pointer movement: integrate vertical delta into line steps. GC's
        // `deltaY` is positive UP, so a positive accumulation is "scroll up"
        // (content moves toward earlier lines) to match natural reading. We
        // also surface the RAW (dx, dy) — including horizontal, which nav
        // doesn't consume — so the capture tool can PROVE iOS is delivering
        // pointer movement for the D-pad even when it's below the step
        // threshold.
        input.mouseMovedHandler = { [weak self] _, deltaX, deltaY in
            MainActor.assumeIsolated {
                guard let self else { return }
                #if DEBUG
                remoteCaptureLog.info("mouse.move dx=\(Double(deltaX), privacy: .public) dy=\(Double(deltaY), privacy: .public)")
                #endif
                self.onRawPointer?(deltaX, deltaY)
                self.handlePointerDelta(deltaY)
            }
        }

        // Scroll wheel: `scroll` is a direction pad; its yAxis carries the
        // wheel. Integrate the same way as pointer travel.
        input.scroll.valueChangedHandler = { [weak self] _, _, yValue in
            MainActor.assumeIsolated {
                guard let self else { return }
                #if DEBUG
                remoteCaptureLog.info("mouse.scroll y=\(Double(yValue), privacy: .public)")
                #endif
                self.handleScrollDelta(yValue)
            }
        }

        input.leftButton.pressedChangedHandler = { [weak self] _, _, pressed in
            MainActor.assumeIsolated {
                guard let self else { return }
                #if DEBUG
                remoteCaptureLog.info("mouse.leftButton pressed=\(pressed, privacy: .public)")
                #endif
                if pressed { self.publish(for: .mouseClick) }
            }
        }
        input.rightButton?.pressedChangedHandler = { [weak self] _, _, pressed in
            MainActor.assumeIsolated {
                guard let self else { return }
                #if DEBUG
                remoteCaptureLog.info("mouse.rightButton pressed=\(pressed, privacy: .public)")
                #endif
                if pressed { self.publish(for: .mouseRightClick) }
            }
        }
        input.middleButton?.pressedChangedHandler = { [weak self] _, _, pressed in
            MainActor.assumeIsolated {
                guard let self else { return }
                #if DEBUG
                remoteCaptureLog.info("mouse.middleButton pressed=\(pressed, privacy: .public)")
                #endif
                if pressed { self.publish(for: .mouseMiddleClick) }
            }
        }
    }

    private func detachHandlers() {
        if let input = attachedMouse?.mouseInput {
            input.mouseMovedHandler = nil
            input.scroll.valueChangedHandler = nil
            input.leftButton.pressedChangedHandler = nil
            input.rightButton?.pressedChangedHandler = nil
            input.middleButton?.pressedChangedHandler = nil
        }
        attachedMouse = nil
    }

    // MARK: - Delta integration

    /// Integrate a vertical pointer delta and emit line-step scroll events for
    /// each threshold crossed. `internal` so unit tests can drive the
    /// accumulation without a live `GCMouse`. Returns the number of steps
    /// emitted (for test assertions).
    @discardableResult
    func handlePointerDelta(_ deltaY: Float, threshold: Float = GCMouseSource.pointerStepThreshold) -> Int {
        pointerAccumulator += deltaY
        return drain(&pointerAccumulator, threshold: threshold)
    }

    /// Same integration for the scroll wheel. Wheel-up (`yValue > 0`) scrolls
    /// the content up, matching the pointer convention.
    @discardableResult
    func handleScrollDelta(_ yValue: Float, threshold: Float = GCMouseSource.scrollStepThreshold) -> Int {
        scrollAccumulator += yValue
        return drain(&scrollAccumulator, threshold: threshold)
    }

    /// Emit one `scrollUp` / `scrollDown` per whole `threshold` of accumulated
    /// travel, leaving the sub-threshold remainder in the accumulator. Positive
    /// travel is "up" (toward earlier lines).
    private func drain(_ accumulator: inout Float, threshold: Float) -> Int {
        guard threshold > 0 else { return 0 }
        var steps = 0
        while abs(accumulator) >= threshold {
            if accumulator > 0 {
                emit(.scrollUp)
                accumulator -= threshold
            } else {
                emit(.scrollDown)
                accumulator += threshold
            }
            steps += 1
        }
        return steps
    }

    // MARK: - Publish

    /// Directly publish a scroll direction event. The scroll vocabulary has no
    /// per-source binding (it's not a physical key); it routes to line steps in
    /// `PrompterViewModel.handleRemoteEvent`. Surfaced to the capture tool via
    /// `onScrollCapture` so the founder SEES the D-pad axes emitting.
    private func emit(_ event: RemoteEvent) {
        #if DEBUG
        remoteCaptureLog.info("mouse.emit scroll \(event.rawValue, privacy: .public) (threshold crossed) scrollHook=\(self.onScrollCapture != nil, privacy: .public)")
        #endif
        onScrollCapture?(event)
        bus.publish(event)
    }

    /// Look up a bindable pointer-button key and publish its event.
    private func publish(for key: RemoteKey) {
        #if DEBUG
        remoteCaptureLog.info("mouse.publish button key=\(key.id, privacy: .public) captureHook=\(self.onCapture != nil, privacy: .public)")
        #endif
        onCapture?(key)
        guard let event = store.event(for: key) else { return }
        bus.publish(event)
    }
}
