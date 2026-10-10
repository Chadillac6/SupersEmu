import SwiftUI

struct PlayerView: View {
    @State var session: GameSession
    let onExit: () -> Void
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 0) {
                topBar
                EmulatorScreen(session: session)
                    .accessibilityIdentifier("emulator-screen")
                #if os(iOS)
                TouchControls(input: session.input)
                #endif
            }
            if let error = session.errorMessage {
                VStack(spacing: 12) {
                    Text("Couldn't start this game").font(.title3.bold())
                    Text(error).foregroundStyle(.secondary)
                    Button("Back to Library", action: onExit).buttonStyle(.borderedProminent)
                }
                .padding(24)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
        }
        .foregroundStyle(.white)
        .onAppear { session.start() }
        .onDisappear { session.stop() }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                session.autosave()
                session.pause()
            case .active:
                session.resume()
            default:
                break
            }
        }
    }

    private var topBar: some View {
        HStack(spacing: 16) {
            Button {
                session.stop()
                onExit()
            } label: {
                Label("Library", systemImage: "chevron.left")
            }
            .fixedSize()
            .accessibilityIdentifier("exit-game")
            Spacer()
            Text(session.status)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(.white.opacity(0.7))
                .accessibilityIdentifier("session-status")
            Spacer()
            Button { session.saveManualState() } label: {
                Label("Save", systemImage: "square.and.arrow.down")
            }
            .fixedSize()
            .accessibilityIdentifier("save-state")
            Button { session.loadManualState() } label: {
                Label("Load", systemImage: "arrow.counterclockwise")
            }
            .fixedSize()
            .disabled(!session.hasManualState)
            .accessibilityIdentifier("load-state")
        }
        .buttonStyle(.borderless)
        .lineLimit(1)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.black)
    }
}

#if os(iOS)
struct TouchControls: View {
    let input: GameInput
    @State private var pressed: SEJoypadButtons = []

    var body: some View {
        // Fits a 375-pt-wide portrait iPhone: 2 x 118 (pads) + 106 (pills) + 20 (padding).
        HStack(alignment: .center, spacing: 0) {
            VStack(spacing: 2) {
                pad("▲", .up)
                HStack(spacing: 30) { pad("◀", .left); pad("▶", .right) }
                pad("▼", .down)
            }
            Spacer(minLength: 0)
            VStack(spacing: 10) {
                HStack(spacing: 6) { pill("L", .l); pill("R", .r) }
                HStack(spacing: 6) { pill("Select", .select); pill("Start", .start) }
            }
            Spacer(minLength: 0)
            VStack(spacing: 2) {
                pad("X", .x)
                HStack(spacing: 30) { pad("Y", .y); pad("A", .a) }
                pad("B", .b)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 12)
    }

    private func pad(_ label: String, _ button: SEJoypadButtons) -> some View {
        Circle()
            .fill(.white.opacity(pressed.contains(button) ? 0.45 : 0.18))
            .frame(width: 44, height: 44)
            .overlay(Text(label).font(.headline))
            .gesture(press(button))
            .accessibilityIdentifier("pad-\(label)")
    }

    private func pill(_ label: String, _ button: SEJoypadButtons) -> some View {
        Capsule()
            .fill(.white.opacity(pressed.contains(button) ? 0.45 : 0.18))
            .frame(width: 50, height: 28)
            .overlay(Text(label).font(.caption.bold()))
            .gesture(press(button))
            .accessibilityIdentifier("pad-\(label)")
    }

    private func press(_ button: SEJoypadButtons) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { _ in set(button, pressed: true) }
            .onEnded { _ in set(button, pressed: false) }
    }

    private func set(_ button: SEJoypadButtons, pressed isPressed: Bool) {
        if isPressed { pressed.insert(button) } else { pressed.remove(button) }
        input.touchButtons = pressed
    }
}
#endif
