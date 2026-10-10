import SupersEmuKit
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
            if session.isChoosingDisc {
                DiscPicker(session: session)
            }
            if let conflict = session.pendingConflict {
                SaveConflictPrompt(conflict: conflict) { session.resolveConflict($0) }
            } else if session.isSyncing {
                ProgressView("Checking for newer saves…")
                    .padding(24)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                    .accessibilityIdentifier("save-sync-progress")
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
                .lineLimit(2)
                .minimumScaleFactor(0.75)
                .multilineTextAlignment(.center)
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
            .disabled(!session.hasManualState || session.isSyncing)
            .accessibilityIdentifier("load-state")
            if session.diskCount > 1 {
                Button { session.openDiscPicker() } label: {
                    Label("Swap disc", systemImage: "opticaldisc")
                }
                .fixedSize()
                .keyboardShortcut("d", modifiers: .command)
                .disabled(session.isSyncing || session.pendingConflict != nil)
                .help("Swap disc (Command-D, or L + R + Select on a controller)")
                .accessibilityValue("Disc \(session.currentDisk + 1) of \(session.diskCount)")
                .accessibilityIdentifier("swap-disc")
            }
        }
        .buttonStyle(.borderless)
        .lineLimit(1)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.black)
    }
}

/// "Swap disc" sheet over the paused game. Arrow keys / d-pad move, Return / A inserts, Esc / B cancels;
/// number keys pick a disc directly.
struct DiscPicker: View {
    @Bindable var session: GameSession

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Swap disc").font(.title3.bold())
            Text("Disc \(session.currentDisk + 1) of \(session.diskCount) is in the tray.")
                .font(.callout)
                .foregroundStyle(.secondary)
            VStack(spacing: 6) {
                ForEach(0..<session.diskCount, id: \.self) { index in
                    row(index)
                }
            }
            HStack {
                Text("↑↓ choose · Return/A insert · Esc/B cancel")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { session.closeDiscPicker(inserting: nil) }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("swap-disc-cancel")
            }
        }
        .padding(22)
        .frame(width: 340)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Swap disc")
        .accessibilityIdentifier("swap-disc-picker")
    }

    private func row(_ index: Int) -> some View {
        let isSelected = index == session.discSelection
        let inTray = index == session.currentDisk
        return Button { session.closeDiscPicker(inserting: index) } label: {
            HStack {
                Image(systemName: inTray ? "opticaldisc.fill" : "opticaldisc")
                Text(session.discLabel(index) ?? "Disc \(index + 1) of \(session.diskCount)")
                Spacer()
                if inTray { Text("In tray").font(.caption).foregroundStyle(.secondary) }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? Color.accentColor.opacity(0.35) : Color.white.opacity(0.06),
                        in: RoundedRectangle(cornerRadius: 10))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .keyboardShortcut(index < 9 ? KeyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: []) : nil)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityHint(inTray ? "Already in the tray" : "Inserts this disc")
        .accessibilityIdentifier("swap-disc-\(index + 1)")
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
