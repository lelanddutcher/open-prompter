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
    case speedUp
    case speedDown
    case jumpBackward
    case jumpForward
    case mirrorToggle
    case restart
    case nextSection
    case prevSection
    /// **Novel for Open Prompter.** Returns scroll position to where the
    /// user pressed play on the current take. None of the surveyed
    /// competitors expose this on a remote. See `Roadmap V2.md` §7.
    case jumpToStart

    /// Human-readable label used in the binding picker.
    var displayName: String {
        switch self {
        case .playPause:     return "Play / pause"
        case .scrollUp:      return "Scroll up"
        case .scrollDown:    return "Scroll down"
        case .scrollLeft:    return "Scroll left"
        case .scrollRight:   return "Scroll right"
        case .speedUp:       return "Speed up"
        case .speedDown:     return "Speed down"
        case .jumpBackward:  return "Jump back 5s"
        case .jumpForward:   return "Jump forward 5s"
        case .mirrorToggle:  return "Toggle mirror"
        case .restart:       return "Restart (top of script)"
        case .nextSection:   return "Next section"
        case .prevSection:   return "Previous section"
        case .jumpToStart:   return "Jump to start of take"
        }
    }
}
