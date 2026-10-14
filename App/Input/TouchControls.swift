#if os(iOS)
import Observation
import SwiftUI
import UIKit

@MainActor
@Observable
private final class TouchPadModel {
    var pressed: Set<String> = []
    var stick = SIMD2<Float>.zero
}

@MainActor
struct TouchControls: View {
    let input: GameInput
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var model = TouchPadModel()
    @State private var frames: [String: CGRect] = [:]
    @State private var availableWidth: CGFloat = 375

    private static let coordinateSpace = "touch-controls"
    private var isCompactPortrait: Bool {
        horizontalSizeClass == .compact && verticalSizeClass != .compact
    }
    private var requiredPortraitWidth: CGFloat {
        let dpad: CGFloat = 156
        let pill: CGFloat = 64
        let button: CGFloat = 62
        let gap: CGFloat = 8
        switch input.layout.system {
        case "n64":
            let cButtons: CGFloat = 116
            let faceButtons: CGFloat = 134
            let topRowWidth = dpad + pill + cButtons + 2 * gap
            let bottomRowWidth: CGFloat = 120 + faceButtons + gap
            return max(topRowWidth, bottomRowWidth)
        case "genesis", "segacd", "sega32x":
            let faceButtons = 3 * button + 8
            let buttonRowWidth = dpad + faceButtons + gap
            let pillRowWidth = 2 * pill + gap
            return max(buttonRowWidth, pillRowWidth)
        case "psx":
            return dpad + pill + 2 * button + 10 + 2 * gap
        case "gb", "gbc", "gba":
            return dpad + pill + 2 * button + 8 + 2 * gap
        default:
            return dpad + pill + 2 * button + 10 + 2 * gap
        }
    }
    private var scale: CGFloat {
        isCompactPortrait ? min(1.3, max(0.75, (availableWidth - 24) / requiredPortraitWidth)) : 1
    }

    var body: some View {
        Group {
            if isCompactPortrait {
                portraitLayout(scale: scale)
            } else {
                landscapeLayout
            }
        }
        .padding(.horizontal, isCompactPortrait ? 12 : 10)
        .padding(.vertical, isCompactPortrait ? 8 : 12)
        .frame(maxWidth: .infinity)
        .coordinateSpace(name: Self.coordinateSpace)
        .background {
            GeometryReader { geometry in
                Color.clear
                    .onAppear { availableWidth = geometry.size.width }
                    .onChange(of: geometry.size.width) { _, width in availableWidth = width }
            }
        }
        .overlay {
            TouchPadSurface(input: input, model: model, zones: touchZones)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onPreferenceChange(TouchZoneFramesKey.self) { frames = $0 }
    }

    private var touchZones: [TouchZone] {
        frames.compactMap { entry in
            let (id, frame) = entry
            guard !["Up", "Down", "Left", "Right"].contains(id) else { return nil }
            let kind: TouchZone.Kind
            switch id {
            case "DPad": kind = .dpad
            case "Stick": kind = .stick
            default: kind = .button
            }
            return TouchZone(id: id, frame: frame, kind: kind)
        }
    }

    @ViewBuilder
    private var landscapeLayout: some View {
        switch input.layout.system {
        case "n64": legacyN64
        case "genesis", "segacd", "sega32x": legacyGenesis
        case "psx": legacyPSX
        case "gb", "gbc", "gba": legacyHandheld
        default: legacySNES
        }
    }

    @ViewBuilder
    private func portraitLayout(scale: CGFloat) -> some View {
        switch input.layout.system {
        case "n64": n64Portrait(scale: scale)
        case "genesis", "segacd", "sega32x": genesisPortrait(scale: scale)
        case "psx": psxPortrait(scale: scale)
        case "gb", "gbc", "gba": handheldPortrait(scale: scale)
        default: snesPortrait(scale: scale)
        }
    }

    private var legacySNES: some View {
        HStack(alignment: .center, spacing: 0) {
            legacyDpad()
            Spacer(minLength: 0)
            VStack(spacing: 10) {
                HStack(spacing: 6) { pill("L"); pill("R") }
                HStack(spacing: 6) { pill("Select"); pill("Start") }
            }
            Spacer(minLength: 0)
            legacyDiamond(top: "X", left: "Y", right: "A", bottom: "B")
        }
    }

    private var legacyHandheld: some View {
        HStack(alignment: .center, spacing: 0) {
            legacyDpad()
            Spacer(minLength: 0)
            VStack(spacing: 10) {
                if input.layout.system == "gba" { HStack(spacing: 6) { pill("L"); pill("R") } }
                HStack(spacing: 6) { pill("Select"); pill("Start") }
            }
            Spacer(minLength: 0)
            HStack(spacing: 8) { pad("B").offset(y: 12); pad("A").offset(y: -12) }
        }
    }

    private var legacyGenesis: some View {
        HStack(alignment: .center, spacing: 0) {
            legacyDpad()
            Spacer(minLength: 0)
            HStack(spacing: 6) { pill("Mode"); pill("Start") }
            Spacer(minLength: 0)
            VStack(spacing: 8) {
                HStack(spacing: 4) { pad("X", size: 34); pad("Y", size: 34); pad("Z", size: 34) }
                HStack(spacing: 4) { pad("A", size: 38); pad("B", size: 38); pad("C", size: 38) }
            }
            .frame(width: 122)
        }
    }

    private var legacyPSX: some View {
        HStack(alignment: .center, spacing: 0) {
            legacyDpad()
            Spacer(minLength: 0)
            VStack(spacing: 8) {
                HStack(spacing: 6) { pill("L1"); pill("R1") }
                HStack(spacing: 6) { pill("L2"); pill("R2") }
                HStack(spacing: 6) { pill("Select"); pill("Start") }
            }
            Spacer(minLength: 0)
            legacyDiamond(top: "Triangle", left: "Square", right: "Circle", bottom: "Cross",
                          labels: ["Triangle": "△", "Square": "□", "Circle": "○", "Cross": "✕"])
        }
    }

    private var legacyN64: some View {
        HStack(alignment: .center, spacing: 0) {
            VStack(spacing: 8) {
                pill("Z")
                analogStick(radius: 46)
            }
            .frame(width: 118)
            Spacer(minLength: 0)
            VStack(spacing: 8) {
                HStack(spacing: 6) { pill("L"); pill("R") }
                pill("Start")
                legacyDpad(size: 26)
            }
            Spacer(minLength: 0)
            VStack(spacing: 4) {
                cButtonCross(size: 30, scale: 1)
                HStack(spacing: 10) { pad("B").offset(y: -8); pad("A").offset(y: 8) }
            }
            .frame(width: 118)
        }
    }

    private func snesPortrait(scale: CGFloat) -> some View {
        HStack(spacing: 0) {
            portraitDpad(scale: scale)
            Spacer(minLength: 8 * scale)
            VStack(spacing: 6 * scale) {
                pill("L", width: 64 * scale, height: 32 * scale)
                pill("R", width: 64 * scale, height: 32 * scale)
                pill("Select", width: 64 * scale, height: 32 * scale)
                pill("Start", width: 64 * scale, height: 32 * scale)
            }
            Spacer(minLength: 8 * scale)
            portraitDiamond(top: "X", left: "Y", right: "A", bottom: "B", scale: scale)
        }
    }

    private func handheldPortrait(scale: CGFloat) -> some View {
        HStack(spacing: 0) {
            portraitDpad(scale: scale)
            Spacer(minLength: 8 * scale)
            VStack(spacing: 6 * scale) {
                if input.layout.system == "gba" {
                    pill("L", width: 64 * scale, height: 32 * scale)
                    pill("R", width: 64 * scale, height: 32 * scale)
                }
                pill("Select", width: 64 * scale, height: 32 * scale)
                pill("Start", width: 64 * scale, height: 32 * scale)
            }
            Spacer(minLength: 8 * scale)
            HStack(spacing: 8 * scale) {
                pad("B", size: 62 * scale).offset(y: 12 * scale)
                pad("A", size: 62 * scale).offset(y: -12 * scale)
            }
        }
    }

    private func psxPortrait(scale: CGFloat) -> some View {
        HStack(spacing: 0) {
            portraitDpad(scale: scale)
            Spacer(minLength: 8 * scale)
            VStack(spacing: 6 * scale) {
                pill("L1", width: 64 * scale, height: 32 * scale)
                pill("R1", width: 64 * scale, height: 32 * scale)
                pill("L2", width: 64 * scale, height: 32 * scale)
                pill("R2", width: 64 * scale, height: 32 * scale)
                pill("Select", width: 64 * scale, height: 32 * scale)
                pill("Start", width: 64 * scale, height: 32 * scale)
            }
            Spacer(minLength: 8 * scale)
            portraitDiamond(top: "Triangle", left: "Square", right: "Circle", bottom: "Cross",
                            labels: ["Triangle": "△", "Square": "□", "Circle": "○", "Cross": "✕"], scale: scale)
        }
    }

    private func genesisPortrait(scale: CGFloat) -> some View {
        VStack(spacing: 6 * scale) {
            HStack(spacing: 0) {
                portraitDpad(scale: scale)
                Spacer(minLength: 8 * scale)
                VStack(spacing: 4 * scale) {
                    HStack(spacing: 4 * scale) {
                        pad("X", size: 62 * scale); pad("Y", size: 62 * scale); pad("Z", size: 62 * scale)
                    }
                    HStack(spacing: 4 * scale) {
                        pad("A", size: 62 * scale); pad("B", size: 62 * scale); pad("C", size: 62 * scale)
                    }
                }
            }
            HStack(spacing: 8 * scale) {
                pill("Mode", width: 64 * scale, height: 32 * scale)
                pill("Start", width: 64 * scale, height: 32 * scale)
            }
        }
    }

    private func n64Portrait(scale: CGFloat) -> some View {
        VStack(spacing: 6 * scale) {
            HStack(spacing: 0) {
                portraitDpad(scale: scale)
                Spacer(minLength: 0)
                VStack(spacing: 6 * scale) {
                    pill("L", width: 64 * scale, height: 32 * scale)
                    pill("R", width: 64 * scale, height: 32 * scale)
                    pill("Start", width: 64 * scale, height: 32 * scale)
                }
                Spacer(minLength: 8 * scale)
                cButtonCross(size: 52 * scale, scale: scale)
            }
            HStack(spacing: 0) {
                VStack(spacing: 6 * scale) {
                    pill("Z", width: 64 * scale, height: 32 * scale)
                    analogStick(radius: 60 * scale)
                }
                Spacer(minLength: 8 * scale)
                HStack(spacing: 10 * scale) {
                    pad("B", size: 62 * scale).offset(y: -8 * scale)
                    pad("A", size: 62 * scale).offset(y: 8 * scale)
                }
            }
        }
    }

    private func portraitDpad(scale: CGFloat) -> some View {
        let diameter = 156 * scale
        let button = 56 * scale
        return ZStack {
            Circle().fill(.white.opacity(0.08)).frame(width: diameter, height: diameter)
            pad("Up", label: "▲", size: button).position(x: diameter / 2, y: button / 2 + 2 * scale)
            pad("Down", label: "▼", size: button).position(x: diameter / 2, y: diameter - button / 2 - 2 * scale)
            pad("Left", label: "◀", size: button).position(x: button / 2 + 2 * scale, y: diameter / 2)
            pad("Right", label: "▶", size: button).position(x: diameter - button / 2 - 2 * scale, y: diameter / 2)
        }
        .frame(width: diameter, height: diameter)
        .background(zoneFrame("DPad"))
    }

    private func legacyDpad(size: CGFloat = 44) -> some View {
        VStack(spacing: 2) {
            pad("Up", label: "▲", size: size)
            HStack(spacing: size * 0.68) { pad("Left", label: "◀", size: size); pad("Right", label: "▶", size: size) }
            pad("Down", label: "▼", size: size)
        }
        .background(zoneFrame("DPad"))
    }

    private func legacyDiamond(top: String, left: String, right: String, bottom: String,
                               labels: [String: String] = [:]) -> some View {
        VStack(spacing: 2) {
            pad(top, label: labels[top] ?? top)
            HStack(spacing: 30) { pad(left, label: labels[left] ?? left); pad(right, label: labels[right] ?? right) }
            pad(bottom, label: labels[bottom] ?? bottom)
        }
    }

    private func portraitDiamond(top: String, left: String, right: String, bottom: String,
                                 labels: [String: String] = [:], scale: CGFloat) -> some View {
        VStack(spacing: 2 * scale) {
            pad(top, label: labels[top] ?? top, size: 62 * scale)
            HStack(spacing: 10 * scale) {
                pad(left, label: labels[left] ?? left, size: 62 * scale)
                pad(right, label: labels[right] ?? right, size: 62 * scale)
            }
            pad(bottom, label: labels[bottom] ?? bottom, size: 62 * scale)
        }
    }

    private func cButtonCross(size: CGFloat, scale: CGFloat) -> some View {
        VStack(spacing: 2 * scale) {
            pad("C-Up", label: "▲", size: size)
            HStack(spacing: 12 * scale) {
                pad("C-Left", label: "◀", size: size)
                pad("C-Right", label: "▶", size: size)
            }
            pad("C-Down", label: "▼", size: size)
        }
    }

    private func pad(_ control: String, label: String? = nil, size: CGFloat = 44) -> some View {
        Circle()
            .fill(.white.opacity(model.pressed.contains(control) ? 0.45 : 0.18))
            .frame(width: size, height: size)
            .overlay(Text(label ?? control).font(size < 40 ? .subheadline.bold() : .headline))
            .background(zoneFrame(control))
            .accessibilityIdentifier("pad-\(control)")
    }

    private func pill(_ control: String, width: CGFloat = 50, height: CGFloat = 28) -> some View {
        Capsule()
            .fill(.white.opacity(model.pressed.contains(control) ? 0.45 : 0.18))
            .frame(width: width, height: height)
            .overlay(Text(control).font(.caption.bold()).lineLimit(1).minimumScaleFactor(0.7))
            .background(zoneFrame(control))
            .accessibilityIdentifier("pad-\(control)")
    }

    private func analogStick(radius: CGFloat) -> some View {
        ZStack {
            Circle()
                .fill(.white.opacity(0.12))
                .frame(width: radius * 2, height: radius * 2)
            Circle()
                .fill(.white.opacity(model.pressed.contains("Stick") ? 0.45 : 0.25))
                .frame(width: radius * 0.72, height: radius * 0.72)
                .offset(x: CGFloat(model.stick.x) * radius, y: -CGFloat(model.stick.y) * radius)
        }
        .frame(width: radius * 2, height: radius * 2)
        .background(zoneFrame("Stick"))
        .accessibilityIdentifier("pad-Stick")
    }

    private func zoneFrame(_ id: String) -> some View {
        GeometryReader { geometry in
            Color.clear.preference(
                key: TouchZoneFramesKey.self,
                value: [id: geometry.frame(in: .named(Self.coordinateSpace))]
            )
        }
    }
}

private struct TouchZoneFramesKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]

    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

@MainActor
private struct TouchPadSurface: UIViewRepresentable {
    let input: GameInput
    let model: TouchPadModel
    let zones: [TouchZone]

    func makeUIView(context: Context) -> TouchPadSurfaceView {
        let view = TouchPadSurfaceView()
        view.configure(input: input, model: model, zones: zones)
        return view
    }

    func updateUIView(_ view: TouchPadSurfaceView, context: Context) {
        view.configure(input: input, model: model, zones: zones)
    }
}

@MainActor
private final class TouchPadSurfaceView: UIView {
    private struct ActiveTouch {
        var point: CGPoint
        let ownsStick: Bool
    }

    private var input: GameInput?
    private var model: TouchPadModel?
    private var zones: [TouchZone] = []
    private var activeTouches: [ObjectIdentifier: ActiveTouch] = [:]
    private var touchOrder: [ObjectIdentifier] = []
    private let feedback = UIImpactFeedbackGenerator(style: .light)

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func configure(input: GameInput, model: TouchPadModel, zones: [TouchZone]) {
        self.input = input
        self.model = model
        guard !zonesMatch(self.zones, zones) else { return }
        self.zones = zones
        updateState()
    }

    private func zonesMatch(_ lhs: [TouchZone], _ rhs: [TouchZone]) -> Bool {
        lhs.count == rhs.count && lhs.allSatisfy { rhs.contains($0) }
    }

    /// Removed from the window (e.g. a controller took over): drop held touches so inputs don't stick.
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            activeTouches.removeAll()
            touchOrder.removeAll()
            updateState()
        }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        feedback.prepare()
        for touch in touches {
            let identifier = ObjectIdentifier(touch)
            let point = touch.location(in: self)
            activeTouches[identifier] = ActiveTouch(point: point, ownsStick: TouchZones.stickZone(at: point, zones: zones) != nil)
            touchOrder.append(identifier)
        }
        updateState()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            let identifier = ObjectIdentifier(touch)
            activeTouches[identifier]?.point = touch.location(in: self)
        }
        updateState()
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        remove(touches)
        updateState()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        remove(touches)
        updateState()
    }

    private func remove(_ touches: Set<UITouch>) {
        for touch in touches {
            let identifier = ObjectIdentifier(touch)
            activeTouches.removeValue(forKey: identifier)
            touchOrder.removeAll { $0 == identifier }
        }
    }

    private func updateState() {
        guard let input, let model else { return }
        var pressed = Set<String>()
        var stick = SIMD2<Float>.zero
        for identifier in touchOrder {
            guard let touch = activeTouches[identifier] else { continue }
            if touch.ownsStick {
                pressed.insert("Stick")
                if stick == .zero, let zone = zones.first(where: { $0.kind == .stick }) {
                    stick = TouchZones.stickVector(at: touch.point, zone: zone)
                }
            } else {
                pressed.formUnion(TouchZones.controls(at: touch.point, zones: zones).subtracting(["Stick"]))
            }
        }
        let newlyPressed = pressed.subtracting(model.pressed)
        let padInputs = Set(pressed.compactMap { input.layout.control($0)?.defaultInput })
        let touchState = PadState(pressed: padInputs, leftStick: stick)
        if input.touchState != touchState { input.touchState = touchState }
        if model.pressed != pressed { model.pressed = pressed }
        if model.stick != stick { model.stick = stick }
        for _ in newlyPressed {
            feedback.impactOccurred()
            feedback.prepare()
        }
    }
}
#endif
