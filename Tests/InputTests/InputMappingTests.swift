import XCTest

final class InputMappingTests: XCTestCase {
    private let snes = ConsoleLayout.forSystem("snes")
    private let n64 = ConsoleLayout.forSystem("n64")
    private let genesis = ConsoleLayout.forSystem("genesis")

    func testConsoleDefaultsMapByPosition() {
        var state = PadState(pressed: [.south, .east, .l1])
        let output = InputMapper.output(for: state, layout: snes, bindings: snes.defaults)
        XCTAssertEqual(output.buttons, RetroButton.b.mask | RetroButton.a.mask | RetroButton.l.mask)

        // Genesis A/B/C sit on the bottom row: RetroPad Y, B, A for Genesis Plus GX and PicoDrive.
        state = PadState(pressed: [.west, .south, .east, .select])
        let sega = InputMapper.output(for: state, layout: genesis, bindings: genesis.defaults)
        XCTAssertEqual(sega.buttons, RetroButton.y.mask | RetroButton.b.mask | RetroButton.a.mask | RetroButton.select.mask)
    }

    func testPrecedenceIsConsoleThenControllerThenGame() {
        var mappings = InputMappings()
        let pad = "gc:Gamepad:8BitDo Pro 2"
        XCTAssertEqual(mappings.bindings(for: snes, controllerType: pad, gameID: "g1")["B"], .south)

        mappings.set(.east, for: "B", system: "snes", scope: .controllerType(pad))
        XCTAssertEqual(mappings.bindings(for: snes, controllerType: pad, gameID: "g1")["B"], .east)
        XCTAssertEqual(mappings.bindings(for: snes, controllerType: "keyboard", gameID: "g1")["B"], .south)
        XCTAssertEqual(mappings.bindings(for: genesis, controllerType: pad, gameID: "g1")["B"], .south, "overrides are per console")

        mappings.set(.north, for: "B", system: "snes", scope: .game("g1"))
        XCTAssertEqual(mappings.bindings(for: snes, controllerType: pad, gameID: "g1")["B"], .north)
        XCTAssertEqual(mappings.bindings(for: snes, controllerType: "keyboard", gameID: "g1")["B"], .north)
        XCTAssertEqual(mappings.bindings(for: snes, controllerType: pad, gameID: "g2")["B"], .east)

        mappings.reset(system: "snes", scope: .game("g1"))
        XCTAssertEqual(mappings.bindings(for: snes, controllerType: pad, gameID: "g1")["B"], .east)
        mappings.reset(system: "snes", scope: .controllerType(pad))
        XCTAssertEqual(mappings.bindings(for: snes, controllerType: pad, gameID: "g1")["B"], .south)
        XCTAssertTrue(mappings.controllerOverrides.isEmpty)
    }

    func testRemappedInputDrivesTheControl() {
        var mappings = InputMappings()
        mappings.set(.r2, for: "A", system: "snes", scope: .controllerType("pad"))
        let bindings = mappings.bindings(for: snes, controllerType: "pad", gameID: nil)
        XCTAssertTrue(InputMapper.output(for: PadState(pressed: [.r2]), layout: snes, bindings: bindings).contains(.a))
        XCTAssertFalse(InputMapper.output(for: PadState(pressed: [.east]), layout: snes, bindings: bindings).contains(.a))
    }

    func testN64SticksAreAnalogAndCButtonsUseTheRightStick() {
        let state = PadState(pressed: [.south, .l2], leftStick: [0.5, 1], rightStick: [0, -1])
        let output = InputMapper.output(for: state, layout: n64, bindings: n64.defaults)
        XCTAssertEqual(output.buttons, RetroButton.b.mask | RetroButton.l2.mask)
        XCTAssertEqual(output.leftStick, SIMD2(16384, -32767), "libretro +y is down")
        XCTAssertEqual(output.rightStick, SIMD2(0, 32767))
    }

    func testDigitalConsolesReadTheLeftStickAsDpad() {
        let output = InputMapper.output(for: PadState(leftStick: [-0.9, 0.2]), layout: snes, bindings: snes.defaults)
        XCTAssertEqual(output.buttons, RetroButton.left.mask)
        XCTAssertEqual(output.leftStick, .zero)
    }

    func testKeyboardArrowsDriveTheN64Stick() {
        let bindings = InputMappings().bindings(for: n64, controllerType: ControllerType.keyboard, gameID: nil)
        let output = InputMapper.output(for: PadState(pressed: [.dpadUp]), layout: n64, bindings: bindings)
        XCTAssertEqual(output.leftStick, SIMD2(0, -32767))
        XCTAssertEqual(output.buttons, 0)
    }

    func testMappingsPersistAsJSON() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Controls.json")
        let store = InputMappingStore(url: url)
        store.set(.l2, for: "Z", system: "n64", scope: .controllerType("hid:0079:0006"))
        store.set(.west, for: "C", system: "genesis", scope: .game("abc"))
        store.setHIDPreset("retrolink-genesis", for: "hid:0079:0011")

        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        let overrides = json?["controllerOverrides"] as? [String: [String: [String: String]]]
        XCTAssertEqual(overrides?["hid:0079:0006"]?["n64"]?["Z"], "l2")

        let reloaded = InputMappingStore(url: url)
        XCTAssertEqual(reloaded.mappings, store.mappings)
        XCTAssertEqual(reloaded.bindings(for: genesis, controllerType: "keyboard", gameID: "abc")["C"], .west)
        XCTAssertEqual(reloaded.mappings.hidPresets["hid:0079:0011"], "retrolink-genesis")

        reloaded.reset(system: "n64", scope: .controllerType("hid:0079:0006"))
        XCTAssertNil(InputMappingStore(url: url).mappings.controllerOverrides["hid:0079:0006"])
    }

    func testCorruptFileFallsBackToDefaults() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("{not json".utf8).write(to: url)
        XCTAssertEqual(InputMappingStore(url: url).mappings, InputMappings())
    }
}
