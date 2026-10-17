import Foundation
import SwiftUI

struct LaunchSplash: View {
    private static var hasShown = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var litDots = 0
    @State private var cartOffset: CGFloat = -120
    @State private var cartOpacity = 0.0
    @State private var wordmarkOffset: CGFloat = 8
    @State private var wordmarkOpacity = 0.0
    @State private var splashOpacity = 1.0
    @State private var isDismissing = false
    @State private var timelineTask: Task<Void, Never>?
    #if os(macOS)
    @FocusState private var hasFocus: Bool
    #endif

    let onFinish: () -> Void

    static func claimColdLaunch() -> Bool {
        guard !hasShown, ProcessInfo.processInfo.environment["SUPERSEMU_SPLASH"] != "off" else { return false }
        hasShown = true
        return true
    }

    private var markSize: CGFloat {
        #if os(macOS)
        96
        #else
        84
        #endif
    }

    private var skipPrompt: String {
        #if os(macOS)
        "PRESS ANY KEY"
        #else
        "TAP TO SKIP"
        #endif
    }

    private var holdsFinalFrame: Bool {
        ProcessInfo.processInfo.environment["SUPERSEMU_SPLASH"] == "hold"
    }

    var body: some View {
        ZStack {
            Brand.Colors.paper.ignoresSafeArea()
            VStack {
                Spacer()
                VStack(spacing: 0) {
                    BrandMark(size: markSize, litDots: litDots)
                        .offset(y: cartOffset)
                        .opacity(cartOpacity)
                    Capsule()
                        .fill(Brand.Colors.card)
                        .frame(width: 150, height: 14)
                        .overlay {
                            Capsule().stroke(Brand.Colors.line, lineWidth: 1)
                        }
                        .offset(y: -(markSize * 2.5 / 24 + 4))
                    BrandWordmark(size: 30)
                        .padding(.top, 28)
                        .offset(y: wordmarkOffset)
                        .opacity(wordmarkOpacity)
                }
                Spacer()
                Text(skipPrompt)
                    .font(Brand.eyebrow)
                    .tracking(1.2)
                    .foregroundStyle(Brand.Colors.ink3)
                    .padding(.bottom, 28)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .opacity(splashOpacity)
        .contentShape(Rectangle())
        .ignoresSafeArea()
        .onTapGesture(perform: skip)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("SupersEmu")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(.default, skip)
        #if os(macOS)
        .focusable()
        .focused($hasFocus)
        .onKeyPress { _ in
            skip()
            return .handled
        }
        #endif
        .onAppear(perform: start)
        .onDisappear {
            timelineTask?.cancel()
            timelineTask = nil
        }
    }

    private func start() {
        guard timelineTask == nil else { return }
        #if os(macOS)
        hasFocus = true
        #endif
        timelineTask = Task { @MainActor in
            if reduceMotion {
                cartOffset = 0
                cartOpacity = 1
                litDots = 6
                wordmarkOffset = 0
                wordmarkOpacity = 1
                if !holdsFinalFrame, await pause(800_000_000) {
                    await dismiss()
                }
                return
            }

            withAnimation(.spring(response: 1.1, dampingFraction: 0.72)) {
                cartOffset = 0
                cartOpacity = 1
            }
            guard await pause(700_000_000) else { return }
            for dotCount in 1...6 {
                litDots = dotCount
                guard await pause(80_000_000) else { return }
            }
            guard await pause(70_000_000) else { return }
            withAnimation(.easeOut(duration: 0.5)) {
                wordmarkOffset = 0
                wordmarkOpacity = 1
            }
            guard await pause(1_050_000_000) else { return }
            if !holdsFinalFrame {
                await dismiss()
            }
        }
    }

    private func skip() {
        guard !isDismissing else { return }
        timelineTask?.cancel()
        Task { @MainActor in await dismiss() }
    }

    private func dismiss() async {
        guard !isDismissing else { return }
        isDismissing = true
        withAnimation(.easeOut(duration: 0.3)) {
            splashOpacity = 0
        }
        guard await pause(300_000_000) else { return }
        onFinish()
    }

    private func pause(_ nanoseconds: UInt64) async -> Bool {
        do {
            try await Task.sleep(nanoseconds: nanoseconds)
            return !Task.isCancelled
        } catch {
            return false
        }
    }
}
