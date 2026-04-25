//
//  PipCorner.swift
//  OpenPrompter
//
//  The five "snap-to" anchor points for the picture-in-picture camera tile.
//  Drag end → spring snap to nearest corner per V2 Design 01 §"PiP tile
//  behavior". `topCenter` is the first-run default position because
//  arm's-length eye-line drift is detectable past ~3-5° (see Roadmap V2 §1).
//
//  The top-center option is included alongside the four geometric corners
//  because it's the single position that puts the user's gaze nearest to
//  the front lens while reading. None of the surveyed competitors ship with
//  a center anchor in their PiP tile.
//

import CoreGraphics
import Foundation

/// Snap targets for the draggable PiP tile.
///
/// Persisted as a string via `Prefs.cameraPipCornerLast` so the schema is
/// resilient to enum re-ordering.
enum PipCorner: String, CaseIterable, Codable, Hashable, Sendable {
    case topLeading
    case topCenter
    case topTrailing
    case bottomLeading
    case bottomTrailing

    /// Human-friendly Settings label.
    var displayName: String {
        switch self {
        case .topLeading:     return "top leading"
        case .topCenter:      return "top center"
        case .topTrailing:    return "top trailing"
        case .bottomLeading:  return "bottom leading"
        case .bottomTrailing: return "bottom trailing"
        }
    }

    /// The center point of the tile when anchored to this corner, given a
    /// containing viewport, the tile size, and an inset margin.
    ///
    /// Layout pads the tile away from the safe area edges so the corner radius
    /// breathes. `inset` is the gap (in points) between the tile edge and the
    /// nearest viewport edge — recommended ~12pt to align with control chrome.
    func center(in viewport: CGSize, tileSize: CGSize, inset: CGFloat) -> CGPoint {
        let halfW = tileSize.width / 2
        let halfH = tileSize.height / 2
        let leftX = inset + halfW
        let rightX = viewport.width - inset - halfW
        let centerX = viewport.width / 2
        let topY = inset + halfH
        let bottomY = viewport.height - inset - halfH
        switch self {
        case .topLeading:     return CGPoint(x: leftX,   y: topY)
        case .topCenter:      return CGPoint(x: centerX, y: topY)
        case .topTrailing:    return CGPoint(x: rightX,  y: topY)
        case .bottomLeading:  return CGPoint(x: leftX,   y: bottomY)
        case .bottomTrailing: return CGPoint(x: rightX,  y: bottomY)
        }
    }

    /// Find the corner whose anchor point is geometrically closest to a
    /// given screen point. Used after a drag ends to snap the tile to the
    /// nearest corner. Pure function — unit-tested in `CameraTests`.
    ///
    /// Tie-breaks: when `point` is exactly equidistant from two corners,
    /// the case order in `allCases` decides. Practically rare, and harmless
    /// either way.
    static func nearestCorner(
        to point: CGPoint,
        in viewport: CGSize,
        tileSize: CGSize,
        inset: CGFloat = 12
    ) -> PipCorner {
        var best: (corner: PipCorner, distance: CGFloat) = (.topCenter, .greatestFiniteMagnitude)
        for corner in PipCorner.allCases {
            let anchor = corner.center(in: viewport, tileSize: tileSize, inset: inset)
            let dx = anchor.x - point.x
            let dy = anchor.y - point.y
            let dist = dx * dx + dy * dy   // squared distance is monotonic with distance
            if dist < best.distance {
                best = (corner, dist)
            }
        }
        return best.corner
    }
}
