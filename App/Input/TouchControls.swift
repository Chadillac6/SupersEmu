#if os(iOS)
import simd
import SwiftUI

/// On-screen pad for the running console. Controls press the console's default positions, so they work the same
/// whatever a physical controller is remapped to.
struct TouchControls: View {
    let input: GameInput
    @State private var pressed: Set<String> = []
    @State private var stick: SIMD2<Float> = .zero

    var body: some View {
        // Fits a 375-pt-wide portrait iPhone: 2 x 118 (pads) + 106 (pills) + 20 (padding).
        Group {
            switch input.layout.system {
            case "n64": n64
            case "genesis", "segacd", "sega32x": genesis
            case "psx": psx
            case "gb", "gbc", "gba": handheld
            default: snes
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 12)
    }

    private var snes: some View {
        HStack(alignment: .center, spacing: 0) {
            dpad
            Spacer(minLength: 0)
            VStack(spacing: 10) {
                HStack(spacing: 6) { pill("L"); pill("R") }
                HStack(spacing: 6) { pill("Select"); pill("Start") }
            }
            Spacer(minLength: 0)
            diamond(top: "X", left: "Y", right: "A", bottom: "B")
        }
    }

    private var handheld: some View {
        HStack(alignment: .center, spacing: 0) {
            dpad
            Spacer(minLength: 0)
            VStack(spacing: 10) {
                if input.layout.system == "gba" { HStack(spacing: 6) { pill("L"); pill("R") } }
                HStack(spacing: 6) { pill("Select"); pill("Start") }
            }
            Spacer(minLength: 0)
            HStack(spacing: 8) { pad("B").offset(y: 12); pad("A").offset(y: -12) }
        }
    }

    private var genesis: some View {
        HStack(alignment: .center, spacing: 0) {
            dpad
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

    private var psx: some View {
        HStack(alignment: .center, spacing: 0) {
            dpad
            Spacer(minLength: 0)
            VStack(spacing: 8) {
                HStack(spacing: 6) { pill("L1"); pill("R1") }
                HStack(spacing: 6) { pill("L2"); pill("R2") }
                HStack(spacing: 6) { pill("Select"); pill("Start") }
            }
            Spacer(minLength: 0)
            diamond(top: "Triangle", left: "Square", right: "Circle", bottom: "Cross",
                    labels: ["Triangle": "△", "Square": "□", "Circle": "○", "Cross": "✕"])
        }
    }

    private var n64: some View {
        HStack(alignment: .center, spacing: 0) {
            VStack(spacing: 8) {
                pill("Z")
                AnalogStick(value: $stick) { setStick($0) }
                    .accessibilityIdentifier("pad-Stick")
            }
            .frame(width: 118)
            Spacer(minLength: 0)
            VStack(spacing: 10) {
                HStack(spacing: 6) { pill("L"); pill("R") }
                pill("Start")
            }
            Spacer(minLength: 0)
            VStack(spacing: 4) {
                VStack(spacing: 0) {
                    pad("C-Up", label: "▲", size: 30)
                    HStack(spacing: 26) { pad("C-Left", label: "◀", size: 30); pad("C-Right", label: "▶", size: 30) }
                    pad("C-Down", label: "▼", size: 30)
                }
                HStack(spacing: 10) { pad("B").offset(y: -8); pad("A").offset(y: 8) }
            }
            .frame(width: 118)
        }
    }

    private var dpad: some View {
        VStack(spacing: 2) {
            pad("Up", label: "▲")
            HStack(spacing: 30) { pad("Left", label: "◀"); pad("Right", label: "▶") }
            pad("Down", label: "▼")
        }
    }

    private func diamond(top: String, left: String, right: String, bottom: String, labels: [String: String] = [:]) -> some View {
        VStack(spacing: 2) {
            pad(top, label: labels[top] ?? top)
            HStack(spacing: 30) { pad(left, label: labels[left] ?? left); pad(right, label: labels[right] ?? right) }
            pad(bottom, label: labels[bottom] ?? bottom)
        }
    }

    private func pad(_ control: String, label: String? = nil, size: CGFloat = 44) -> some View {
        Circle()
            .fill(.white.opacity(pressed.contains(control) ? 0.45 : 0.18))
            .frame(width: size, height: size)
            .overlay(Text(label ?? control).font(size < 40 ? .subheadline.bold() : .headline))
            .gesture(press(control))
            .accessibilityIdentifier("pad-\(control)")
    }

    private func pill(_ control: String) -> some View {
        Capsule()
            .fill(.white.opacity(pressed.contains(control) ? 0.45 : 0.18))
            .frame(width: 50, height: 28)
            .overlay(Text(control).font(.caption.bold()))
            .gesture(press(control))
            .accessibilityIdentifier("pad-\(control)")
    }

    private func press(_ control: String) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { _ in set(control, pressed: true) }
            .onEnded { _ in set(control, pressed: false) }
    }

    private func set(_ control: String, pressed isPressed: Bool) {
        if isPressed { pressed.insert(control) } else { pressed.remove(control) }
        sync()
    }

    private func setStick(_ value: SIMD2<Float>) {
        stick = value
        sync()
    }

    private func sync() {
        let layout = input.layout
        input.touchState = PadState(pressed: Set(pressed.compactMap { layout.control($0)?.defaultInput }), leftStick: stick)
    }
}

/// Drag-anywhere analog stick; reports -1...1 with +y up and springs back on release.
private struct AnalogStick: View {
    @Binding var value: SIMD2<Float>
    let onChange: (SIMD2<Float>) -> Void
    private let radius: CGFloat = 46

    var body: some View {
        Circle()
            .fill(.white.opacity(0.12))
            .frame(width: radius * 2, height: radius * 2)
            .overlay(
                Circle()
                    .fill(.white.opacity(value == .zero ? 0.25 : 0.45))
                    .frame(width: 42, height: 42)
                    .offset(x: CGFloat(value.x) * radius, y: -CGFloat(value.y) * radius)
            )
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        var vector = SIMD2<Float>(Float(drag.location.x - radius), Float(radius - drag.location.y)) / Float(radius)
                        let length = simd_length(vector)
                        if length > 1 { vector /= length }
                        onChange(vector)
                    }
                    .onEnded { _ in onChange(.zero) }
            )
    }
}
#endif
