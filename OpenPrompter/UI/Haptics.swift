//
//  Haptics.swift
//  OpenPrompter
//
//  Thin wrapper around UIImpactFeedbackGenerator for consistent taps.
//

#if canImport(UIKit)
import UIKit

enum Haptics {
    @MainActor
    static func tap(_ style: UIImpactFeedbackGenerator.FeedbackStyle = .light) {
        let generator = UIImpactFeedbackGenerator(style: style)
        generator.prepare()
        generator.impactOccurred()
    }

    @MainActor
    static func alert() {
        let generator = UINotificationFeedbackGenerator()
        generator.prepare()
        generator.notificationOccurred(.warning)
    }

    @MainActor
    static func success() {
        let generator = UINotificationFeedbackGenerator()
        generator.prepare()
        generator.notificationOccurred(.success)
    }
}
#else
enum Haptics {
    static func tap() {}
    static func alert() {}
    static func success() {}
}
#endif
