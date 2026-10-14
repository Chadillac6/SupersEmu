import SupersEmuKit
import SwiftUI

struct PlayerView: View {
    @State var session: GameSession
    let onExit: () -> Void
    @Environment(\.scenePhase) private var scenePhase
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @AppStorage(PlayerChrome.hideTouchControlsKey) private var hideTouchControls = true
    @State private var hub = ControllerHub.shared
    #endif
    @State private var topBarAutoHide = TopBarAutoHide()

    private var chrome: PlayerChrome {
        #if os(iOS)
        PlayerChrome.resolve(
            controllerActive: PlayerChrome.isControllerActive(connectedGamepads: hub.controllers.count),
            hideWhenControllerConnected: hideTouchControls, hasTouchControls: true)
        #else
        PlayerChrome.resolve(controllerActive: false, hideWhenControllerConnected: false, hasTouchControls: false)
        #endif
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 0) {
                if !chrome.isFullScreen { topBar }
                EmulatorScreen(session: session)
                    .accessibilityIdentifier("emulator-screen")
                    #if os(iOS)
                    .ignoresSafeArea(edges: chrome.isFullScreen ? .all : [])
                    .contentShape(Rectangle())
                    .onTapGesture { if chrome.isFullScreen { topBarAutoHide.toggle() } }
                    #endif
                #if os(iOS)
                if chrome.showsTouchControls {
                    TouchControls(input: session.input)
                        .containerRelativeFrame(.horizontal)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                #endif
            }
            #if os(iOS)
            .overlay(alignment: .top) {
                if chrome.isFullScreen && topBarAutoHide.isRevealed {
                    topBar.transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            #endif
            if session.isChoosingDisc {
                DiscPicker(session: session)
            }
            if session.isMenuOpen && !session.isShowingSaveSlots {
                InGameMenu(session: session)
            }
            if session.isShowingSaveSlots {
                SaveSlotsView(session: session)
            }
            if let name = session.disconnectedController, !session.isMenuOpen && !session.isShowingSaveSlots {
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
        #if os(iOS)
        .defersSystemGestures(on: .all)
        .persistentSystemOverlays(.hidden)
        .statusBarHidden(chrome.isFullScreen)
        #endif
        .animation(.easeInOut(duration: 0.25), value: chrome)
        .animation(.easeInOut(duration: 0.25), value: topBarAutoHide.isRevealed)
        .onChange(of: chrome.isFullScreen) { _, fullScreen in
            if fullScreen {
                topBarAutoHide.reveal()
            } else {
                topBarAutoHide.hide()
            }
        }
        .onChange(of: chrome.showsTouchControls) { _, shows in
            if !shows { session.input.touchState = PadState() }
        }
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
        .onAppear {
            session.start()
            if chrome.isFullScreen { topBarAutoHide.reveal() }
        }
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
        #if os(iOS)
        let compact = horizontalSizeClass == .compact
        #else
        let compact = false
        #endif
        return HStack(spacing: compact ? 8 : 16) {
            Button {
                session.stop()
                onExit()
            } label: {
                toolbarLabel("Library", systemImage: "chevron.left", compact: compact)
            }
            .fixedSize()
            .accessibilityLabel("Library")
            .accessibilityIdentifier("exit-game")
            if !compact { Spacer(minLength: 0) }
            Text(session.status)
                .font(.caption)
                .lineLimit(compact ? 1 : 2)
                .minimumScaleFactor(compact ? 1 : 0.75)
                .multilineTextAlignment(.center)
                .truncationMode(.tail)
                .layoutPriority(compact ? -1 : 0)
                .frame(maxWidth: compact ? .infinity : nil, alignment: .center)
                .foregroundStyle(.white.opacity(0.7))
                .accessibilityIdentifier("session-status")
            if !compact { Spacer(minLength: 0) }
            Button { session.openMenu() } label: {
                toolbarLabel("Menu", systemImage: "line.3.horizontal", compact: compact)
            }
            .fixedSize()
            .disabled(session.isSyncing || session.pendingConflict != nil)
            .help("In-game menu (hold Select + Start for 1 second, or hold Home on a controller)")
            .accessibilityLabel("Menu")
            .accessibilityIdentifier("open-menu")
            Button { session.openSaveSlots(preferEmpty: true) } label: {
                toolbarLabel("Save", systemImage: "square.and.arrow.down", compact: compact)
            }
            .fixedSize()
            .disabled(session.isSyncing || session.pendingConflict != nil)
            .accessibilityLabel("Save")
            .accessibilityIdentifier("save-state")
            Button { session.openSaveSlots(preferEmpty: false) } label: {
                toolbarLabel("Load", systemImage: "arrow.counterclockwise", compact: compact)
            }
            .fixedSize()
            .disabled(!session.hasManualState || session.isSyncing)
            .accessibilityLabel("Load")
            .accessibilityIdentifier("load-state")
            if session.diskCount > 1 {
                Button { session.openDiscPicker() } label: {
                    toolbarLabel("Swap disc", systemImage: "opticaldisc", compact: compact)
                }
                .fixedSize()
                .keyboardShortcut("d", modifiers: .command)
                .disabled(session.isSyncing || session.pendingConflict != nil)
                .help("Swap disc (Command-D, or L + R + Select on a controller)")
                .accessibilityValue("Disc \(session.currentDisk + 1) of \(session.diskCount)")
                .accessibilityLabel("Swap disc")
                .accessibilityIdentifier("swap-disc")
            }
        }
        .buttonStyle(.borderless)
        .lineLimit(1)
        .padding(.horizontal, compact ? 8 : 16)
        .padding(.vertical, 10)
        .background(.black)
    }

    @ViewBuilder private func toolbarLabel(_ title: String, systemImage: String, compact: Bool) -> some View {
        if compact {
            Image(systemName: systemImage).frame(width: 32, height: 32)
        } else {
            Label(title, systemImage: systemImage)
        }
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
                    .accessibilityIdentifier(item == .restart ? "menu-restart" : "menu-\(item.rawValue)")
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
        .confirmationDialog("Restart the game?", isPresented: $session.isConfirmingRestart, titleVisibility: .visible) {
            Button("Restart", role: .destructive) {
                session.restart()
                session.closeMenu()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Unsaved progress since your last in-game save will be lost. In-game saves are kept.")
        }
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
