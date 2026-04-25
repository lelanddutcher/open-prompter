//
//  PipSize.swift
//  OpenPrompter
//
//  Three preset tile sizes for the PiP camera. Double-tap on the tile cycles
//  small → medium → large → small. Pinch-to-resize is intentionally NOT
//  supported (V2 Design 01 §"Gestures NOT supported"); discrete sizes are
//  predictable and avoid layout surprises across rotations.
//

import CoreGraphics
import Foundation

/// Discrete sizing presets for the PiP camera tile. All are 3:4 portrait
/// — at arm's-length on a portrait phone, a landscape PiP wastes screen.
enum PipSize: String, CaseIterable, Codable, Hashable, Sendable {
    case small
    case medium
    case large

    /// Settings label.
    var displayName: String {
        switch self {
        case .small:  return "small"
        case .medium: return "medium"
        case .large:  return "large"
        }
    }

    /// Width × height in SwiftUI points. Heights are 3/4 ratio for the
    /// portrait tile (chip is 130×175, etc.). Values pinned here so the
    /// gesture math (snap, drag clamps) reads from a single source of truth.
    var dimensions: CGSize {
        switch self {
        case .small:  return CGSize(width: 110, height: 145)
        case .medium: return CGSize(width: 130, height: 175)
        case .large:  return CGSize(width: 160, height: 215)
        }
    }

    /// Cycle order for the double-tap gesture: small → medium → large → small.
    var nextSize: PipSize {
        switch self {
        case .small:  return .medium
        case .medium: return .large
        case .large:  return .small
        }
    }
}
