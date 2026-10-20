import XCTest

final class N64GraphicsTests: XCTestCase {
    private func isolatedDefaults() throws -> (UserDefaults, String) {
        let suiteName = "N64GraphicsTests.\(UUID().uuidString)"
        return (try XCTUnwrap(UserDefaults(suiteName: suiteName)), suiteName)
    }

    func testPresetsAreInMockupOrder() {
        XCTAssertEqual(N64Quality.allCases, [.auto, .good, .better, .best, .original])
        XCTAssertEqual(N64ScreenLook.allCases, [.sharp, .smooth, .crt])
    }

    func testOriginalKeepsTodaysNativeLook() {
        let graphics = N64Graphics(quality: .original, resolution: nil, edgeSmoothing: nil, textureFilter: nil,
                                   textureEnhancement: .off, sharp2D: false, widescreen: false)
        XCTAssertEqual(graphics.coreOptionOverrides(autoCap: .x3), [
            "mupen64plus-aspect": "4:3",
            "mupen64plus-43screensize": "320x240",
        ])
    }

    func testBestUsesFourTimesWithFXAAAndThreePoint() {
        let graphics = N64Graphics(quality: .best, resolution: nil, edgeSmoothing: nil, textureFilter: nil,
                                   textureEnhancement: .off, sharp2D: false, widescreen: false)
        XCTAssertEqual(graphics.coreOptionOverrides(autoCap: .x2), [
            "mupen64plus-aspect": "4:3",
            "mupen64plus-43screensize": "1280x960",
            "mupen64plus-FXAA": "1",
            "mupen64plus-BilinearMode": "3point",
        ])
    }

    func testAutoFollowsCapAndAdvancedOverridesWin() {
        var graphics = N64Graphics(quality: .auto, resolution: nil, edgeSmoothing: .off, textureFilter: .standard,
                                   textureEnhancement: .xbrz, sharp2D: true, widescreen: true)
        XCTAssertTrue(graphics.isAutoResolution)
        XCTAssertEqual(graphics.coreOptionOverrides(autoCap: .x2), [
            "mupen64plus-aspect": "16:9 adjusted",
            "mupen64plus-169screensize": "960x540",
            "mupen64plus-txEnhancementMode": "4xBRZ",
            "mupen64plus-EnableNativeResTexrects": "Optimized",
        ])
        graphics.resolution = .x4
        XCTAssertFalse(graphics.isAutoResolution)
        XCTAssertEqual(graphics.effectiveResolution(autoCap: .native), .x4)
    }

    func testDefaultsAreAutoAndSmooth() throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let graphics = N64Graphics.load(forGameID: "g", from: defaults)
        XCTAssertEqual(graphics.quality, .auto)
        XCTAssertNil(graphics.resolution)
        XCTAssertFalse(graphics.widescreen)
        XCTAssertEqual(N64Graphics.screenLook(from: defaults), .smooth)
    }

    func testPerGameQualityAndWidescreenOverrideGlobal() throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(N64Quality.better.rawValue, forKey: N64Graphics.Key.quality)
        defaults.set("4", forKey: N64Graphics.Key.resolution)
        N64Graphics.setQuality(.original, forGameID: "dk64", in: defaults)
        N64Graphics.setWidescreen(true, forGameID: "dk64", in: defaults)

        let dk64 = N64Graphics.load(forGameID: "dk64", from: defaults)
        XCTAssertEqual(dk64.quality, .original)
        XCTAssertEqual(dk64.resolution, .x4)
        XCTAssertTrue(dk64.widescreen)
        XCTAssertEqual(N64Graphics.load(forGameID: "tennis", from: defaults).quality, .better)

        N64Graphics.setQuality(nil, forGameID: "dk64", in: defaults)
        N64Graphics.setWidescreen(false, forGameID: "dk64", in: defaults)
        XCTAssertEqual(N64Graphics.load(forGameID: "dk64", from: defaults).quality, .better)
        XCTAssertFalse(N64Graphics.isWidescreen(forGameID: "dk64", from: defaults))
    }

    func testAutoCapStepsDownPerGameUntilNativeAndResets() throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(N64Graphics.autoCap(forGameID: "dk64", from: defaults), .deviceAuto)
        var steps: [N64Resolution] = []
        while let lower = N64Graphics.lowerAutoCap(forGameID: "dk64", in: defaults) { steps.append(lower) }
        XCTAssertEqual(steps.last, .native)
        XCTAssertEqual(steps.count, N64Resolution.deviceAuto.rawValue - 1)
        XCTAssertEqual(N64Graphics.autoCap(forGameID: "tennis", from: defaults), .deviceAuto)
        N64Graphics.resetAutoCaps(in: defaults)
        XCTAssertEqual(N64Graphics.autoCap(forGameID: "dk64", from: defaults), .deviceAuto)
    }
}
