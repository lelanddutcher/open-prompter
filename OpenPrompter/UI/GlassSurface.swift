//
//  GlassSurface.swift
//  OpenPrompter
//
//  One place for the Liquid Glass availability gate. iOS 26+ gets Apple's
//  Liquid Glass material; iOS 17–25 falls back to the classic Rig-Gray fill
//  + hairline border so the look degrades gracefully. Reserve for chrome /
//  control surfaces (bars, chips, control cards) — not content.
//

import SwiftUI

extension View {
    /// Liquid Glass surface in `shape` on iOS 26+, else a solid fill +
    /// hairline. Pass `tint` for active/prominent states (tinted glass on
    /// 26+, solid fill below); `interactive: true` for tappable surfaces so
    /// the glass reacts to touch.
    @ViewBuilder
    func glassSurface<S: Shape>(in shape: S, tint: Color? = nil, interactive: Bool = true) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(opLiquidGlass(tint: tint, interactive: interactive), in: shape)
        } else {
            self
                .background(tint ?? Theme.surface, in: shape)
                .overlay(shape.stroke(tint == nil ? Theme.border : Color.clear, lineWidth: 1))
        }
    }
}

@available(iOS 26.0, *)
private func opLiquidGlass(tint: Color?, interactive: Bool) -> Glass {
    var glass: Glass = .regular
    if let tint { glass = glass.tint(tint) }
    if interactive { glass = glass.interactive() }
    return glass
}
