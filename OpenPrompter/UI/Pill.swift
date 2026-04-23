//
//  Pill.swift
//  OpenPrompter
//
//  Reusable pill chrome used for status indicators (Mirror ON, x/y progress).
//  Dim by default, alert variant turns red.
//

import SwiftUI

struct Pill: View {
    let text: String
    var alert: Bool = false

    var body: some View {
        Text(text)
            .font(.system(size: 13, weight: .bold))
            .tracking(0.05 * 13)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(alert ? Theme.alert : Theme.controlBg)
            .foregroundStyle(alert ? Color.white : Theme.dim)
            .clipShape(Capsule())
            .overlay(Capsule().stroke(alert ? Theme.alert : Theme.controlBorder, lineWidth: 1))
    }
}
