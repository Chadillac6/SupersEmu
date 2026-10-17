import XCTest

final class N64PresetTests: XCTestCase {
    func testAllCasesAreInDiagnosticsPickerOrder() {
        XCTAssertEqual(N64Preset.allCases, [.standard, .faster, .balanced, .fastest])
    }

    func testBalancedPresetHasExpectedCoreOptionOverrides() {
        XCTAssertEqual(N64Preset.balanced.coreOptionOverrides, [
            "mupen64plus-43screensize": "320x240",
            "mupen64plus-CountPerOp": "3",
            "mupen64plus-EnableCopyColorToRDRAM": "Async",
            "mupen64plus-EnableCopyDepthToRDRAM": "Software",
            "mupen64plus-EnableLODEmulation": "True",
        ])
    }

    func testBalancedPresetCanBeCreatedFromRawValue() {
        XCTAssertEqual(N64Preset(rawValue: "balanced"), .balanced)
    }

    func testDefaultPresetFallsBackToBalancedInIsolatedUserDefaults() throws {
        let suiteName = "N64PresetTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(N64Preset.defaultPreset(from: defaults), .balanced)
    }

    func testSavedStandardDefaultIsPreservedInIsolatedUserDefaults() throws {
        let suiteName = "N64PresetTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        N64Preset.setDefaultPreset(.standard, in: defaults)

        XCTAssertEqual(N64Preset.defaultPreset(from: defaults), .standard)
    }

    func testPerGamePresetRoundTripsInIsolatedUserDefaults() throws {
        let suiteName = "N64PresetTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        N64Preset.setPreset(.balanced, forGameID: "game-id", in: defaults)

        XCTAssertEqual(N64Preset.preset(forGameID: "game-id", from: defaults), .balanced)
    }

    func testPerGameFastestOverrideBeatsSavedDefaultInIsolatedUserDefaults() throws {
        let suiteName = "N64PresetTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        N64Preset.setDefaultPreset(.standard, in: defaults)
        N64Preset.setPreset(.fastest, forGameID: "game-id", in: defaults)

        XCTAssertEqual(N64Preset.selectedPreset(forGameID: "game-id", from: defaults), .fastest)
    }
}
