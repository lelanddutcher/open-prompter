//
//  PrompterTopBarView.swift
//  OpenPrompter
//
//  Top chrome. After the post-merge dogfooding pass that centralized control
//  affordances, this strip is intentionally minimal — just the Back button.
//  The previous occupants (sync/edited status, mirror status pill, pencil
//  edit shortcut) all moved down to the bottom chip row alongside the camera-
//  style and REC chips so the user has a single place to look for actions.
//
//  Styling follows design-language.md §7.2.
//

import SwiftUI

struct PrompterTopBarView: View {
    @Environment(AppState.self) private var state
    /// View-model handed in by the parent. The top bar no longer reads any
    /// VM state directly (after the dogfood-pass-2 reshuffle), but we keep
    /// the parameter so the parent's call site doesn't need to change and
    /// future top-bar additions can hook into the VM without re-threading
    /// the property graph.
    var vm: PrompterViewModel

    var body: some View {
        HStack(spacing: 8) {
            // Back sits TRAILING (3.2). iPadOS draws its window-control pill
            // in the top-LEADING corner whenever the app is in a window rather
            // than full screen, and it covered this button — leaving no way
            // out of the prompter. Trailing clears it on every platform and
            // window size with no device check and no window-state detection,
            // and it keeps the top bar flush so the reading line stays under
            // the lens (see the eye-line note at the call site). Trailing is
            // also where close/done lives in an iOS modal, so it reads
            // correctly on iPhone too.
            Spacer(minLength: 6)

            Button(action: { state.closeScript() }) {
                // 44pt outer hit target per Apple HIG; inner capsule is
                // drawn at the visual size we want (36×32) so the chrome
                // stays compact without shrinking the tap area.
                Image(systemName: "chevron.left")
                    .font(.system(size: 13, weight: .bold))
                    .frame(width: 36, height: 32)
                    .foregroundStyle(Theme.fg)
                    .glassSurface(in: Capsule())
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Back to library")
        }
        .padding(.horizontal, 10)
    }
}
