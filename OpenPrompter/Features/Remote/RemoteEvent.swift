//
//  RemoteEvent.swift
//  OpenPrompter
//
//  Vocabulary of high-level prompter actions any remote source can emit.
//  Sources (keyboard / media keys / volume buttons / future Watch) translate
//  device-specific input into one of these cases. The PrompterViewModel
//  consumes the event stream and runs the corresponding action.
//
//  Adding a new event:
//   1. Add the case here.
//   2. Add a default key (or `nil` for "unbound by default") in
//      `RemoteBindingStore.defaultBindings`.
//   3. Add a humanized label in `displayName`.
//   4. Map the case to a PrompterViewModel call site in `bind(to:)`.
//

import Foundation

/// A pluggable, source-agnostic action issued by a remote control. Sources
/// fan into a single `RemoteEventBus` so the view model only ever subscribes
/// to one stream. New event sources (Watch, Multipeer) join by emitting one
/// of these cases — they don't need to know about the prompter or its state.
enum RemoteEvent: String, Codable, CaseIterable, Hashable, Sendable {
    case playPause
    case scrollUp
    case scrollDown
    case scrollLeft
    case scrollRight
    /// One-line nudge up / down. Distinct from the half-viewport `jump*`
    /// leaps — a `lineUp`/`lineDown` step is ~`fontSize * 1.6` so a presenter
    /// can fine-position to the exact line they want. `scrollUp`/`scrollDown`
    /// (pointer / scroll-wheel deltas from a mouse-class remote) route here.
    case lineUp
    case lineDown
    case speedUp
    case speedDown
    case jumpBackward
    case jumpForward
    case mirrorToggle
    case restart
    /// Bottom of the script — the counterpart to `restart` (top). Added in
    /// 3.2 after a user described mapping keypad `1` and `2` to the top and
    /// bottom of the script on a Bluetooth 10-key: `restart` already covered
    /// the top, but there was no way to bind the end, so the pair was
    /// unbuildable. Useful on its own for jumping to a sign-off or outro.
    case jumpToEnd
    case nextSection
    case prevSection
    /// **Novel for Open Prompter.** Returns scroll position to where the
    /// user pressed play on the current take. None of the surveyed
    /// competitors expose this on a remote. See `Roadmap V2.md` §7.
    case jumpToStart
    /// Start / cancel / stop recording — the SAME action the on-screen REC
    /// chip and the hardware capture button perform, expressed as a bindable
    /// remote action so the founder can put "record" on ANY button via the
    /// "Learn your remote" wizard (v3: "the wizard decides everything").
    /// Superseded the hardwired `HardwareCaptureBridge.onPrimary → record`
    /// path — the hardware shutter now runs whatever it's bound to (default
    /// play/pause), and `.recordToggle` is what a wizard "RECORD" slot binds.
    case recordToggle
    /// **Novel for Open Prompter (V3 headline).** Drops a video marker into
    /// the in-flight recording at the exact press moment — the hands-free
    /// counterpart to the on-screen "mark" chip. Bind it to a Bluetooth
    /// shutter or a wizard slot to flag a keeper take without reaching for
    /// the screen. No-op when nothing is recording. See `V3 Feature Ideas.md`
    /// H0a.
    case dropMarker

    /// Human-readable label used in the binding picker.
    var displayName: String {
        switch self {
        case .playPause:     return "Play / pause"
        case .scrollUp:      return "Scroll up"
        case .scrollDown:    return "Scroll down"
        case .scrollLeft:    return "Scroll left"
        case .scrollRight:   return "Scroll right"
        case .lineUp:        return "Line up"
        case .lineDown:      return "Line down"
        case .speedUp:       return "Speed up"
        case .speedDown:     return "Speed down"
        // These are half-viewport leaps, not time-based seeks. The prior
        // "5s" labels were inaccurate (audit B3 label bug) — the prompter
        // has no time axis, only scroll offset.
        case .jumpBackward:  return "Jump back (half screen)"
        case .jumpForward:   return "Jump forward (half screen)"
        case .mirrorToggle:  return "Toggle mirror"
        case .restart:       return "Restart (top of script)"
        case .jumpToEnd:     return "Jump to end of script"
        case .nextSection:   return "Next section"
        case .prevSection:   return "Previous section"
        case .jumpToStart:   return "Jump to start of take"
        case .recordToggle:  return "Start / stop recording"
        case .dropMarker:    return "Drop marker"
        }
    }
}
