//
//  ContentWidth.swift
//  OpenPrompter
//
//  Content-width caps (3.2).
//
//  The app shipped iPhone-only through 3.0, so every control was tuned for a
//  ~390pt column and written as `.frame(maxWidth: .infinity)`. That is correct
//  at phone width and wrong at 1366pt, where the same declaration stretches a
//  call-to-action or a control row across the whole panel — the visual
//  signature of a scaled-up phone app, and a real ergonomic problem when a
//  control the hand should reach spans the full width of a mounted iPad.
//
//  WHY THIS KEYS OFF WIDTH, NOT DEVICE IDIOM
//
//  The first version of this gated on `UIDevice.current.userInterfaceIdiom
//  == .pad`. That is the wrong axis. iPadOS windowing and Macs running iPad
//  apps mean a `.pad` app can be in a phone-width window, and the platforms
//  keep converging — so "which device is this" no longer predicts "how much
//  room do I have." Sizing decisions belong to the geometry.
//
//  A bare `maxWidth` cap is exactly that: it is an UPPER BOUND, so when the
//  container is narrower than the cap the view simply fills the container and
//  the cap is inert. No idiom check is needed to protect narrow layouts —
//  the geometry protects them for free, at every window size, on every
//  platform, including ones that don't exist yet.
//

import SwiftUI

extension View {
    /// Cap this view's width so it stays a comfortable measure in a wide
    /// container, while filling a narrow one unchanged.
    ///
    /// Inert whenever the available width is below `maxWidth`, which is why
    /// this needs no device or size-class check — a phone, a narrow iPad
    /// window, and a small Mac window all simply use the width they have.
    ///
    /// The default (620pt) suits a control cluster; the script column uses its
    /// own font-relative cap (see `TeleprompterView.scriptColumnMaxWidth`)
    /// because line length has to scale with the reader's chosen text size.
    func padContentWidth(_ maxWidth: CGFloat = 620) -> some View {
        frame(maxWidth: maxWidth)
    }

    /// Measure for LISTS and FORMS, which tolerate more width than prose but
    /// must still not run edge-to-edge.
    ///
    /// Verified on a 13-inch iPad simulator: an uncapped `List` stretched a
    /// single script row across the full 1032pt, stranding its status dot at
    /// the far edge with a dead gap in between. A "Designed for iPad" app on
    /// Apple Silicon runs in a freely resizable window, so this gets worse,
    /// not better, on macOS. 760pt keeps a row scannable in one eye movement
    /// at any window size.
    func padListWidth(_ maxWidth: CGFloat = 760) -> some View {
        frame(maxWidth: maxWidth)
    }
}
