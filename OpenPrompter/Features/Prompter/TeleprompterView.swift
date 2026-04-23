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

            // Mirrored stage — text only
            scrollingText
                .scaleEffect(
                    x: vm.mirroredHorizontal ? -1 : 1,
                    y: vm.mirroredVertical ? -1 : 1
                )
                .animation(.easeInOut(duration: Theme.mirrorAnim), value: vm.mirroredHorizontal)
                .animation(.easeInOut(duration: Theme.mirrorAnim), value: vm.mirroredVertical)

            // Chrome — top bar + bottom controls. Outside mirror stage.
            VStack {
                PrompterTopBarView(vm: vm)
                    .padding(.top, 8)
                Spacer()
                PrompterControlsView(vm: vm)
                    .padding(.bottom, 12)
            }
            .opacity(vm.focus ? 0.08 : 1.0)
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

            // Loading / error
            if vm.isLoading {
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(Theme.fg)
            } else if let error = vm.loadError {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 36))
                    Text("Couldn't load this file.")
                        .font(.system(size: 17, weight: .bold))
                    Text(error)
                        .font(.system(size: 13, weight: .regular))
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
                VStack {
                    Text(vm.parsed.bodyText)
                        .font(.system(size: vm.fontSize, weight: .semibold))
                        .foregroundStyle(Theme.fg)
                        .multilineTextAlignment(.center)
                        .lineSpacing(vm.fontSize * 0.35)
                        .padding(.horizontal, 24)
                        .padding(.vertical, geo.size.height * 0.8)
                        .background(
                            GeometryReader { inner in
                                Color.clear.onAppear {
                                    vm.contentHeight = inner.size.height
                                    vm.viewportHeight = geo.size.height
                                }
                                .onChange(of: inner.size.height) { _, new in
                                    vm.contentHeight = new
                                }
                            }
                        )
                }
                .offset(y: -vm.scroller.offset)
            }
            .scrollDisabled(vm.isPlaying)
            .onAppear {
                vm.viewportHeight = geo.size.height
            }
        }
    }
}
