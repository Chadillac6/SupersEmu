import SwiftUI

enum Brand {
    enum Colors {
        static let paper = Color("BrandPaper")
        static let surface = Color("BrandSurface")
        static let card = Color("BrandCard")
        static let line = Color("BrandLine")
        static let ink = Color("BrandInk")
        static let ink2 = Color("BrandInk2")
        static let ink3 = Color("BrandInk3")
        static let red = Color("BrandRed")
        static let redPressed = Color("BrandRedPressed")
        static let redText = Color("BrandRedText")
        static let redTint = Color("BrandRedTint")
    }

    enum Radii {
        static let card: CGFloat = 14
        static let button: CGFloat = 12
        static let row: CGFloat = 10
    }

    static let eyebrow = Font.caption.monospaced().weight(.semibold)
    static let serifTitle = Font.system(.largeTitle, design: .serif).weight(.bold)

    static func wordmark(size: CGFloat) -> Font {
        .custom("Silkscreen-Bold", size: size, relativeTo: .title2)
    }
}

struct BrandPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.body, weight: .semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 44)
            .padding(.horizontal, 16)
            .background(configuration.isPressed ? Brand.Colors.redPressed : Brand.Colors.red,
                        in: RoundedRectangle(cornerRadius: Brand.Radii.button))
            .contentShape(RoundedRectangle(cornerRadius: Brand.Radii.button))
    }
}

struct BrandSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.body, weight: .semibold))
            .foregroundStyle(Brand.Colors.ink)
            .frame(maxWidth: .infinity, minHeight: 44)
            .padding(.horizontal, 16)
            .background(Brand.Colors.surface.opacity(configuration.isPressed ? 0.7 : 1),
                        in: RoundedRectangle(cornerRadius: Brand.Radii.button))
            .overlay {
                RoundedRectangle(cornerRadius: Brand.Radii.button)
                    .stroke(Brand.Colors.line, lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: Brand.Radii.button))
    }
}

struct BrandMark: View {
    var size: CGFloat = 24
    var litDots: Int = 6

    var body: some View {
        ZStack {
            CartridgeOutline()
                .stroke(Brand.Colors.ink, style: StrokeStyle(lineWidth: 1.7 * size / 24, lineJoin: .round))
            Canvas { context, _ in
                var index = 0
                for y in [8.4, 11.8] {
                    for x in [8.6, 12.0, 15.4] {
                        let dot = CGRect(
                            x: (x - 1.15) * size / 24,
                            y: (y - 1.15) * size / 24,
                            width: 2.3 * size / 24,
                            height: 2.3 * size / 24
                        )
                        let opacity = index >= litDots ? 0.15 : 1
                        context.fill(Path(ellipseIn: dot), with: .color(Brand.Colors.red.opacity(opacity)))
                        index += 1
                    }
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

private struct CartridgeOutline: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: point(4, 2.5, in: rect))
        path.addLine(to: point(20, 2.5, in: rect))
        path.addArc(center: point(20, 4, in: rect), radius: 1.5 * scale(in: rect),
                    startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)
        path.addLine(to: point(21.5, 21.5, in: rect))
        path.addLine(to: point(17.5, 21.5, in: rect))
        path.addLine(to: point(17.5, 19.3, in: rect))
        path.addLine(to: point(6.5, 19.3, in: rect))
        path.addLine(to: point(6.5, 21.5, in: rect))
        path.addLine(to: point(2.5, 21.5, in: rect))
        path.addLine(to: point(2.5, 4, in: rect))
        path.addArc(center: point(4, 4, in: rect), radius: 1.5 * scale(in: rect),
                    startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        path.closeSubpath()
        return path
    }

    private func point(_ x: CGFloat, _ y: CGFloat, in rect: CGRect) -> CGPoint {
        CGPoint(x: rect.minX + x * scale(in: rect), y: rect.minY + y * scale(in: rect))
    }

    private func scale(in rect: CGRect) -> CGFloat {
        min(rect.width, rect.height) / 24
    }
}

struct BrandLockup: View {
    var size: CGFloat = 22

    var body: some View {
        HStack {
            BrandMark(size: size * 1.1)
            BrandWordmark(size: size)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("SupersEmu")
    }
}

struct BrandWordmark: View {
    var size: CGFloat = 22

    var body: some View {
        (Text("SUPERS").foregroundColor(Brand.Colors.ink)
         + Text("EMU").foregroundColor(Brand.Colors.redText))
            .font(Brand.wordmark(size: size))
            .tracking(1)
            .accessibilityLabel("SupersEmu")
    }
}

struct BrandPanel: ViewModifier {
    var radius: CGFloat = Brand.Radii.card

    func body(content: Content) -> some View {
        content
            .background(Brand.Colors.surface, in: RoundedRectangle(cornerRadius: radius))
            .overlay {
                RoundedRectangle(cornerRadius: radius)
                    .stroke(Brand.Colors.line, lineWidth: 1)
            }
    }
}

extension View {
    func brandPanel(radius: CGFloat = Brand.Radii.card) -> some View {
        modifier(BrandPanel(radius: radius))
    }
}
