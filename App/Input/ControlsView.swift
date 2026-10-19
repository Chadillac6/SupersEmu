import SwiftUI
import SupersEmuKit
#if os(macOS)
import AppKit
#endif

/// Remapping: pick a console control, press the physical input for it, or reset to defaults.
/// From Settings every console is editable; from the in-game menu it's fixed to the running game.
struct ControlsView: View {
    var fixedSystem: SystemID?
    var gameID: String?
    var gameTitle: String?
    var game: Game?

    @State private var store = InputMappingStore.shared
    @State private var hub = ControllerHub.shared
    @State private var system = SystemID.snes
    @State private var controllerType = ControllerType.keyboard
    @State private var thisGameOnly = false
    @State private var capturing: String?
    @State private var captureHeld: Set<PadInput> = []
    @State private var captureTimer: Timer?
    #if os(macOS)
    @State private var keyMonitor: Any?
    #endif
    #if os(iOS)
    @AppStorage(PlayerChrome.hideTouchControlsKey) private var hideTouchControls = true
    #endif
    @Environment(\.dismiss) private var dismiss

    private var layout: ConsoleLayout { .forSystem(system) }
    private var scope: MappingScope {
        if thisGameOnly, let gameID { .game(gameID) } else { .controllerType(controllerType) }
    }
    private var bindings: [String: PadInput] {
        store.bindings(for: layout, controllerType: controllerType, gameID: gameID)
    }

    /// Keyboard, connected pads and any pad type that already has remappings.
    private var controllerTypes: [(type: String, name: String)] {
        var result: [(String, String)] = [(ControllerType.keyboard, "Keyboard")]
        for controller in hub.controllers where !result.contains(where: { $0.0 == controller.type }) {
            result.append((controller.type, controller.name))
        }
        for type in store.mappings.controllerOverrides.keys.sorted() where !result.contains(where: { $0.0 == type }) {
            result.append((type, Self.displayName(for: type)))
        }
        return result
    }

    var body: some View {
        Form {
            #if os(iOS)
            Section {
                Toggle("Hide on-screen controls when a controller is connected", isOn: $hideTouchControls)
                    .accessibilityIdentifier("controls-hide-touch-with-controller")
            } footer: {
                Text("The game goes full screen; tap the screen to show the toolbar.")
            }
            #endif
            Section {
                Picker("Controller", selection: $controllerType) {
                    ForEach(controllerTypes, id: \.type) { Text($0.name).tag($0.type) }
                }
                .accessibilityIdentifier("controls-controller")
                #if os(macOS)
                hidPresetPicker
                #endif
                if fixedSystem == nil {
                    Picker("Console", selection: $system) {
                        ForEach(ConsoleLayout.systems, id: \.self) { Text(ConsoleLayout.title(for: $0)).tag($0) }
                    }
                    .accessibilityIdentifier("controls-console")
                }
                if let gameTitle, gameID != nil {
                    Toggle("Only for \(gameTitle)", isOn: $thisGameOnly)
                        .accessibilityIdentifier("controls-this-game")
                }
            } footer: {
                Text("Controls map by position: \"Bottom button\" is the bottom face button on any pad, whatever it's labelled. "
                     + "Per-game changes win over controller changes, which win over the console's defaults.")
            }
            Section(layout.title) {
                ForEach(layout.controls) { control in row(control) }
            }
            Section {
                Button("Reset to Default", role: .destructive) {
                    stopCapture()
                    store.reset(system: system, scope: scope)
                }
                .accessibilityIdentifier("controls-reset")
            }
            Section("Diagnostics") {
                NavigationLink {
                    DiagnosticsView(game: game)
                } label: {
                    Label("Diagnostics", systemImage: "waveform.path.ecg")
                }
                .accessibilityIdentifier("controls-diagnostics")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Controls")
        .toolbar {
            if fixedSystem != nil {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.accessibilityIdentifier("controls-done")
                }
            }
        }
        .onAppear {
            system = fixedSystem ?? system
            if let first = hub.controllers.first { controllerType = first.type }
        }
        .onDisappear(perform: stopCapture)
        .onChange(of: controllerType) { stopCapture() }
        .onChange(of: system) { stopCapture() }
        .frame(minWidth: 460, minHeight: 520)
    }

    private func row(_ control: ConsoleControl) -> some View {
        let input = bindings[control.id] ?? control.defaultInput
        let isCapturing = capturing == control.id
        return Button {
            isCapturing ? stopCapture() : startCapture(control.id)
        } label: {
            HStack {
                Text(control.id)
                Spacer()
                if isCapturing {
                    Text("Press a button…").foregroundStyle(Color.accentColor)
                } else {
                    Text(input.label).foregroundStyle(input == .unbound ? .tertiary : .secondary)
                    if let origin = origin(of: control) {
                        Text(origin).font(.caption2).padding(.horizontal, 5).padding(.vertical, 2)
                            .background(.quaternary, in: Capsule())
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("controls-row-\(control.id)")
        .accessibilityValue(isCapturing ? "Waiting for input" : input.label)
    }

    /// Which layer the binding comes from, when it isn't the console default.
    private func origin(of control: ConsoleControl) -> String? {
        if let gameID, store.mappings.gameOverrides[gameID]?[control.id] != nil { return "This game" }
        if store.mappings.controllerOverrides[controllerType]?[system.rawValue]?[control.id] != nil { return "Custom" }
        return nil
    }

    #if os(macOS)
    @ViewBuilder private var hidPresetPicker: some View {
        if let controller = hub.controllers.first(where: { $0.type == controllerType && $0.kind == .hid }),
           let device = hub.hidDevice(for: controller) {
            let current = hub.preset(for: device, console: system)
            Picker("Layout", selection: Binding(
                get: { store.mappings.hidPresets[controllerType] ?? current.id },
                set: { store.setHIDPreset($0, for: controllerType) })) {
                ForEach(HIDPreset.all) { preset in
                    Text(preset.source == .unverified ? "\(preset.name) (unverified)" : preset.name).tag(preset.id)
                }
            }
            .accessibilityIdentifier("controls-hid-layout")
            Text(String(format: "USB %04X:%04X · %@", device.vendorID, device.productID, device.productName))
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    #endif

    private func startCapture(_ control: String) {
        stopCapture()
        capturing = control
        captureHeld = currentPhysical()
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { _ in
            MainActor.assumeIsolated { pollCapture() }
        }
        RunLoop.main.add(timer, forMode: .common)
        captureTimer = timer
        #if os(macOS)
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 {  // Esc cancels.
                stopCapture()
                return nil
            }
            guard controllerType == ControllerType.keyboard, let input = GameInput.keyCodeMap[event.keyCode] else { return event }
            assign(input)
            return nil
        }
        #endif
    }

    private func pollCapture() {
        let state = currentPhysical()
        let fresh = state.subtracting(captureHeld)
        captureHeld = state
        #if os(macOS)
        if controllerType == ControllerType.keyboard { return }  // The key monitor captures keys.
        #endif
        guard let input = PadInput.allCases.first(where: { fresh.contains($0) }) else { return }
        assign(input)
    }

    /// Held inputs on pads of the selected type, with sticks counted once pushed past 60%.
    private func currentPhysical() -> Set<PadInput> {
        var held: Set<PadInput> = []
        #if os(iOS)
        if controllerType == ControllerType.keyboard { held = GameInput.hardwareKeyboardPressed() }
        #endif
        for controller in hub.controllers where controller.type == controllerType {
            let state = hub.state(of: controller, console: system)
            held.formUnion(state.pressed)
            held.formUnion(PadInput.allCases.filter { $0.isStick && state.value(of: $0) > 0.6 })
        }
        return held
    }

    private func assign(_ input: PadInput) {
        guard let capturing else { return }
        store.set(input, for: capturing, system: system, scope: scope)
        stopCapture()
    }

    private func stopCapture() {
        capturing = nil
        captureTimer?.invalidate()
        captureTimer = nil
        #if os(macOS)
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        #endif
    }

    static func displayName(for type: String) -> String {
        if type == ControllerType.keyboard { return "Keyboard" }
        let parts = type.split(separator: ":", maxSplits: 2).map(String.init)
        if parts.first == "hid", parts.count == 3 {
            let ids = "\(parts[1]):\(parts[2])".uppercased()
            if let vid = Int(parts[1], radix: 16), let pid = Int(parts[2], radix: 16),
               let preset = HIDPreset.all.first(where: { $0.vendorID == vid && $0.productID == pid }) {
                return "\(preset.name) (USB \(ids))"
            }
            return "USB gamepad \(ids)"
        }
        return parts.last ?? type
    }
}
