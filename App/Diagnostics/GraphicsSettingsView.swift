import SwiftUI

/// N64 picture settings, shared by iPhone, iPad and Mac.
struct GraphicsSettingsView: View {
    var game: Game?

    @AppStorage(N64Graphics.Key.quality) private var quality = N64Graphics.defaultQuality.rawValue
    @AppStorage(N64Graphics.Key.screenLook) private var screenLook = N64Graphics.defaultScreenLook.rawValue
    @AppStorage(N64Graphics.Key.resolution) private var resolution = N64Graphics.followsPreset
    @AppStorage(N64Graphics.Key.edgeSmoothing) private var edgeSmoothing = N64Graphics.followsPreset
    @AppStorage(N64Graphics.Key.textureFilter) private var textureFilter = N64Graphics.followsPreset
    @AppStorage(N64Graphics.Key.textureEnhancement) private var textureEnhancement = N64TextureEnhancement.off.rawValue
    @AppStorage(N64Graphics.Key.sharp2D) private var sharp2D = false
    @State private var gameQuality = Self.useDefault
    @State private var widescreen = false

    private static let useDefault = "use-default"

    private var n64Game: Game? {
        game.flatMap { GameSession.system(for: $0) == "n64" ? $0 : nil }
    }

    /// The quality that applies to the game being edited, so preset labels match what it will get.
    private var activeQuality: N64Quality {
        N64Quality(rawValue: gameQuality) ?? N64Quality(rawValue: quality) ?? N64Graphics.defaultQuality
    }

    private var autoCap: N64Resolution {
        n64Game.map { N64Graphics.autoCap(forGameID: $0.id) } ?? .deviceAuto
    }

    private var deviceName: String {
        #if os(macOS)
        "this Mac"
        #else
        UIDevice.current.userInterfaceIdiom == .pad ? "this iPad" : "this iPhone"
        #endif
    }

    var body: some View {
        Form {
            Section {
                Picker("Quality", selection: $quality) {
                    ForEach(N64Quality.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityIdentifier("graphics-quality")
            } header: {
                Text("N64 quality")
            } footer: {
                Text("Auto picks the sharpest setting that keeps full speed, up to \(N64Resolution.deviceAuto.title) on "
                     + "\(deviceName). If a game slows down, Auto steps that game down a level. Best is 4×. "
                     + "Original is the classic 320×240 look.")
            }

            Section {
                Picker("Screen look", selection: $screenLook) {
                    ForEach(N64ScreenLook.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityIdentifier("graphics-screen-look")
            } header: {
                Text("Screen look")
            } footer: {
                Text("Changes right away. CRT adds TV-style scanlines.")
            }

            if let n64Game {
                Section {
                    Picker("Shape", selection: $widescreen) {
                        Text("Original 4:3").tag(false)
                        Text("Widescreen").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .accessibilityIdentifier("graphics-shape")
                    .onChange(of: widescreen) { _, wide in N64Graphics.setWidescreen(wide, forGameID: n64Game.id) }
                } header: {
                    Text("Shape")
                } footer: {
                    Text("Only for \(n64Game.title). Widescreen can glitch at the screen edges in games that weren't made for it.")
                }
            }

            Section {
                Picker("Resolution", selection: $resolution) {
                    Text("\(activeQuality.title) (\(N64Graphics.presetResolution(for: activeQuality, autoCap: autoCap).title))")
                        .tag(N64Graphics.followsPreset)
                    ForEach(N64Resolution.allCases) { Text($0.title).tag(String($0.rawValue)) }
                }
                .accessibilityIdentifier("graphics-resolution")
                Picker("Edge smoothing", selection: $edgeSmoothing) {
                    Text("\(activeQuality.title) (\(N64Graphics.presetEdgeSmoothing(for: activeQuality).title))")
                        .tag(N64Graphics.followsPreset)
                    ForEach(N64EdgeSmoothing.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .accessibilityIdentifier("graphics-edge-smoothing")
                Picker("Texture filter", selection: $textureFilter) {
                    Text("\(activeQuality.title) (\(N64Graphics.presetTextureFilter(for: activeQuality).title))")
                        .tag(N64Graphics.followsPreset)
                    ForEach(N64TextureFilter.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .accessibilityIdentifier("graphics-texture-filter")
                Picker("Texture enhancement", selection: $textureEnhancement) {
                    ForEach(N64TextureEnhancement.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .accessibilityIdentifier("graphics-texture-enhancement")
                Toggle("Sharp 2D text & menus", isOn: $sharp2D)
                    .accessibilityIdentifier("graphics-sharp-2d")
                Button("Reset Auto for all games") { N64Graphics.resetAutoCaps() }
                    .accessibilityIdentifier("graphics-reset-auto")
            } header: {
                Text("Advanced")
            } footer: {
                Text("Settings that name a preset follow the quality above. Changing a manual resolution turns off "
                     + "Auto's slowdown protection. Sharp 2D text can misplace some menus.")
            }

            if let n64Game {
                Section {
                    Picker("For \(n64Game.title)", selection: $gameQuality) {
                        Text("Use default").tag(Self.useDefault)
                        ForEach(N64Quality.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                    .accessibilityIdentifier("graphics-game-quality")
                    .onChange(of: gameQuality) { _, raw in
                        N64Graphics.setQuality(N64Quality(rawValue: raw), forGameID: n64Game.id)
                    }
                } header: {
                    Text("Per-game override")
                } footer: {
                    Text("Quality, resolution and shape take effect the next time you open the game.")
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Graphics")
        .onAppear {
            guard let n64Game else { return }
            gameQuality = N64Graphics.quality(forGameID: n64Game.id)?.rawValue ?? Self.useDefault
            widescreen = N64Graphics.isWidescreen(forGameID: n64Game.id)
        }
    }
}
