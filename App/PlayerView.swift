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
            if session.isMenuOpen {
                InGameMenu(session: session)
            }
            if let name = session.disconnectedController, !session.isMenuOpen {
                DisconnectPrompt(session: session, name: name)
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
        .sheet(isPresented: $session.isShowingControls) {
            NavigationStack {
                ControlsView(fixedSystem: session.input.layout.system, gameID: session.game.id, gameTitle: session.game.title)
            }
            .preferredColorScheme(.dark)
        }
        .onChange(of: session.wantsExit) { _, exit in
            if exit {
                session.stop()
                onExit()
            }
        }
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
            Button { session.openMenu() } label: {
                Label("Menu", systemImage: "line.3.horizontal")
            }
            .fixedSize()
            .disabled(session.isSyncing || session.pendingConflict != nil)
            .help("In-game menu (hold Select + Start for 1 second, or hold Home on a controller)")
            .accessibilityIdentifier("open-menu")
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

/// Pause menu over the game. D-pad/stick moves, bottom face button or Start chooses, right face button,
/// Select or Home closes.
struct InGameMenu: View {
    @Bindable var session: GameSession

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(session.game.title).font(.title3.bold()).lineLimit(1)
            VStack(spacing: 6) {
                ForEach(Array(session.menuItems.enumerated()), id: \.element) { index, item in
                    Button { session.choose(item) } label: {
                        Text(item.rawValue)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 9)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(index == session.menuSelection ? Color.accentColor.opacity(0.35) : Color.white.opacity(0.06),
                                        in: RoundedRectangle(cornerRadius: 10))
                            .contentShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(index == session.menuSelection ? .isSelected : [])
                    .accessibilityIdentifier("menu-\(item.rawValue)")
                }
            }
            HStack {
                Text("↑↓ choose · A/Start select · B/Select close")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Close") { session.closeMenu() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("menu-close")
            }
        }
        .padding(22)
        .frame(width: 320)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("in-game-menu")
    }
}

/// Shown when a player's controller disconnects mid-game; the game stays paused until they continue.
struct DisconnectPrompt: View {
    let session: GameSession
    let name: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "gamecontroller").font(.largeTitle)
            Text(session.controllerReconnected ? "Controller reconnected" : "Reconnect controller").font(.title3.bold())
            Text(session.controllerReconnected
                 ? "Press A or Start to keep playing."
                 : "\(name) disconnected. Reconnect it, or continue with \(Self.fallback).")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("Continue") { session.dismissDisconnect() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("disconnect-continue")
        }
        .padding(24)
        .frame(width: 320)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .accessibilityIdentifier("disconnect-prompt")
    }

    #if os(iOS)
    private static let fallback = "the touch controls"
    #else
    private static let fallback = "the keyboard"
    #endif
}
