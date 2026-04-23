//
//  Theme.swift
//  OpenPrompter
//
//  Design tokens — colors, dimensions, durations. Dark mode is the only mode.
//

import SwiftUI

enum Theme {
    // MARK: - Colors

    static let bg = Color.black
    static let fg = Color.white
    static let dim = Color(red: 0.533, green: 0.533, blue: 0.533)            // #888
    static let alert = Color(red: 1.0, green: 0.231, blue: 0.188)            // #FF3B30
    static let safe = Color(red: 0.204, green: 0.780, blue: 0.349)           // #34C759
    static let accent = Color(red: 0.247, green: 0.933, blue: 0.478)         // #3FEE7A (electric green)
    static let controlBg = Color.black.opacity(0.94)                          // pill / control bar base
    static let controlBorder = Color.white.opacity(0.10)

    // MARK: - Dimensions

    static let minButtonSize: CGFloat = 52
    static let cornerRadius: CGFloat = 14
    static let pillRadius: CGFloat = 999
    static let controlGap: CGFloat = 8

    // MARK: - Type scale

    static let sizeLabelSm: CGFloat = 12    // all-caps micro labels
    static let sizePill: CGFloat = 13       // pills, small captions
    static let sizeBody: CGFloat = 15       // regular UI labels
    static let sizeButton: CGFloat = 17     // primary button labels
    static let sizeTitle: CGFloat = 22      // screen titles
    static let sizeDisplay: CGFloat = 32    // onboarding display

    // MARK: - Durations

    static let mirrorAnim: Double = 0.14
    static let focusAnim: Double = 0.25
    static let pillTap: Double = 0.08
}
