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
        ZStack {
            Theme.bg.ignoresSafeArea()

            // Mirrored stage — text only.
            scrollingText
                .scaleEffect(
                    x: vm.mirroredHorizontal ? -1 : 1,
                    y: vm.mirroredVertical ? -1 : 1
                )
                .animation(.easeInOut(duration: Theme.mirrorAnim), value: vm.mirroredHorizontal)
                .animation(.easeInOut(duration: Theme.mirrorAnim), value: vm.mirroredVertical)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // Top bar floats flush to safe-area top, controls to safe-area bottom.
                .overlay(alignment: .top) {
                    PrompterTopBarView(vm: vm)
                        .padding(.top, 4)
                        .opacity(vm.focus ? 0.0 : 1.0)
                        .allowsHitTesting(!vm.focus)
                        .animation(.easeInOut(duration: Theme.focusAnim), value: vm.focus)
                }
                .overlay(alignment: .bottom) {
                    PrompterControlsView(vm: vm)
                        .padding(.bottom, 6)
                        .opacity(vm.focus ? 0.0 : 1.0)
                        .allowsHitTesting(!vm.focus)
                        .animation(.easeInOut(duration: Theme.focusAnim), value: vm.focus)
                }
                .overlay(alignment: .bottomTrailing) {
                    // Always-visible escape button while focus mode is on —
                    // otherwise the user can't find a tap target to turn chrome
                    // back on. Plain opacity change avoids view-identity flicker.
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
                    .opacity(vm.focus ? 1.0 : 0.0)
                    .allowsHitTesting(vm.focus)
                    .animation(.easeInOut(duration: Theme.focusAnim), value: vm.focus)
                }

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

            // Loading / error
            if vm.isLoading {
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(Theme.fg)
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
            }
        }
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
    private var scrollingText: some View {
        GeometryReader { geo in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .center, spacing: vm.fontSize * 0.45) {
                    ForEach(Array(vm.parsed.blocks.enumerated()), id: \.offset) { _, block in
                        blockView(for: block)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 24)
                .padding(.vertical, geo.size.height * 0.8)
                .background(
                    GeometryReader { inner in
                        Color.clear
                            .onAppear {
                                vm.contentHeight = inner.size.height
                                vm.viewportHeight = geo.size.height
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
                vm.viewportHeight = geo.size.height
            }
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
