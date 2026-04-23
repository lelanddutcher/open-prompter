//
//  TeleprompterView.swift
//  OpenPrompter
//
//  The prompter itself. One scrolling block of text, optional mirror flip
//  on horizontal and/or vertical axes, auto-scroll driven by TimelineView,
//  dimmable chrome. Controls live OUTSIDE the mirrored ZStack so they're
//  always readable regardless of flip state.
//

import SwiftUI

struct TeleprompterView: View {
    @Environment(AppState.self) private var appState
    @State private var vm: PrompterViewModel
    @State private var changeWatcher: Task<Void, Never>? = nil

    init(file: ScriptFile) {
        _vm = State(initialValue: PrompterViewModel(file: file))
    }

    var body: some View {
        // One top-level GeometryReader gives us an unambiguous screen size;
        // every layer is then sized and positioned explicitly against it.
        // This is the fix for chrome drifting into the middle third on device:
        // nested GeometryReaders in an overlay/ZStack can resolve to a parent's
        // ideal size rather than the full safe-area bounds.
        GeometryReader { outer in
            ZStack(alignment: .topLeading) {
                Theme.bg.ignoresSafeArea()

                // Mirrored stage — text only.
                scrollingText(viewport: outer.size)
                    .frame(width: outer.size.width, height: outer.size.height)
                    .scaleEffect(
                        x: vm.mirroredHorizontal ? -1 : 1,
                        y: vm.mirroredVertical ? -1 : 1
                    )
                    .animation(.easeInOut(duration: Theme.mirrorAnim), value: vm.mirroredHorizontal)
                    .animation(.easeInOut(duration: Theme.mirrorAnim), value: vm.mirroredVertical)

                // Chrome canvas — explicitly sized, VStack with Spacer fills it.
                VStack(spacing: 0) {
                    PrompterTopBarView(vm: vm)
                        .padding(.top, 4)
                    Spacer(minLength: 0)
                    PrompterControlsView(vm: vm)
                        .padding(.bottom, 6)
                }
                .frame(width: outer.size.width, height: outer.size.height)
                .opacity(vm.focus ? 0.0 : 1.0)
                .allowsHitTesting(!vm.focus)
                .animation(.easeInOut(duration: Theme.focusAnim), value: vm.focus)

                // Floating escape for focus mode — pinned bottom-trailing
                // on its own full-size frame so it stays anchored even when
                // the chrome VStack is hidden.
                Button(action: { vm.toggleFocus() }) {
                    Image(systemName: "eye")
                        .font(.system(size: 16, weight: .bold))
                        .frame(width: 44, height: 44)
                        .foregroundStyle(Theme.fg.opacity(0.9))
                        .background(.ultraThinMaterial, in: Circle())
                        .overlay(Circle().stroke(Theme.controlBorder, lineWidth: 1))
                }
                .padding(.trailing, 16)
                .padding(.bottom, 16)
                .frame(width: outer.size.width, height: outer.size.height, alignment: .bottomTrailing)
                .opacity(vm.focus ? 1.0 : 0.0)
                .allowsHitTesting(vm.focus)
                .animation(.easeInOut(duration: Theme.focusAnim), value: vm.focus)

                // Auto-scroll driver — invisible, just ticks the AutoScroller.
                TimelineView(.animation(minimumInterval: nil, paused: !vm.isPlaying)) { context in
                    Color.clear.frame(width: 1, height: 1)
                        .onChange(of: context.date) { _, newDate in
                            guard vm.isPlaying else { return }
                            let delta = vm.scroller.advance(now: newDate, speed: vm.speed)
                            vm.scroller.apply(delta: delta, maxOffset: vm.maxScrollOffset)
                            if vm.scroller.didReachEnd {
                                vm.isPlaying = false
                            }
                        }
                }

                // Loading / error — centered
                if vm.isLoading {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(Theme.fg)
                        .frame(width: outer.size.width, height: outer.size.height)
                } else if let error = vm.loadError {
                    VStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 36))
                        Text("Couldn't load this file.")
                            .font(.system(size: Theme.sizeButton, weight: .bold))
                        Text(error)
                            .font(.system(size: Theme.sizePill, weight: .regular))
                            .foregroundStyle(Theme.dim)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                    }
                    .foregroundStyle(Theme.fg)
                    .frame(width: outer.size.width, height: outer.size.height)
                }
            }
        }
        .ignoresSafeArea(.keyboard)
        .contentShape(Rectangle())
        .onTapGesture { vm.togglePlay() }
        .task { await vm.load() }
        .task {
            // Listen for file changes while this script is open.
            for await url in appState.watcher.changed {
                if url == vm.file.url {
                    vm.reloadAvailable = true
                }
            }
        }
        .statusBarHidden()
    }

    @ViewBuilder
    private func scrollingText(viewport: CGSize) -> some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .center, spacing: vm.fontSize * 0.45) {
                ForEach(Array(vm.parsed.blocks.enumerated()), id: \.offset) { _, block in
                    blockView(for: block)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 24)
            // Top padding lets the first line start roughly mid-viewport (eye-line).
            // Bottom padding lets the last line scroll up past the middle.
            .padding(.top, viewport.height * 0.5)
            .padding(.bottom, viewport.height * 0.8)
            .background(
                GeometryReader { inner in
                    Color.clear
                        .onAppear {
                            vm.contentHeight = inner.size.height
                            vm.viewportHeight = viewport.height
                        }
                        .onChange(of: inner.size.height) { _, new in
                            vm.contentHeight = new
                        }
                }
            )
            .offset(y: -vm.scroller.offset)
        }
        .scrollDisabled(vm.isPlaying)
        .onAppear {
            vm.viewportHeight = viewport.height
        }
        .onChange(of: viewport.height) { _, new in
            vm.viewportHeight = new
        }
    }

    @ViewBuilder
    private func blockView(for block: ScriptBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(text)
                .font(.system(size: headingSize(level: level), weight: .heavy))
                .foregroundStyle(Theme.fg)
                .multilineTextAlignment(.center)
                .lineSpacing(vm.fontSize * 0.2)
                .frame(maxWidth: .infinity, alignment: .center)

        case .paragraph(let text):
            Text(text)
                .font(.system(size: vm.fontSize, weight: .semibold))
                .foregroundStyle(Theme.fg)
                .multilineTextAlignment(.center)
                .lineSpacing(vm.fontSize * 0.35)
                .frame(maxWidth: .infinity, alignment: .center)

        case .bullet(let text):
            listRow(marker: "•", text: text)

        case .numbered(let index, let text):
            listRow(marker: "\(index).", text: text)
        }
    }

    @ViewBuilder
    private func listRow(marker: String, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: vm.fontSize * 0.35) {
            Text(marker)
                .font(.system(size: vm.fontSize, weight: .bold))
                .foregroundStyle(Theme.accent)
            Text(text)
                .font(.system(size: vm.fontSize, weight: .semibold))
                .foregroundStyle(Theme.fg)
                .multilineTextAlignment(.leading)
                .lineSpacing(vm.fontSize * 0.35)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, vm.fontSize * 0.25)
    }

    private func headingSize(level: Int) -> CGFloat {
        // H1 → 1.45×, H2 → 1.25×, H3+ → 1.1×. Caps at the font slider maximum.
        let multiplier: CGFloat
        switch level {
        case 1: multiplier = 1.45
        case 2: multiplier = 1.25
        default: multiplier = 1.1
        }
        return min(vm.fontSize * multiplier, 180)
    }
}
