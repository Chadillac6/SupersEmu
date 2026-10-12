import Foundation

struct TouchZone: Equatable {
    enum Kind: Equatable {
        case button
        case dpad
        case stick
    }

    let id: String
    let frame: CGRect
    let kind: Kind
}

enum TouchZones {
    static func controls(at point: CGPoint, zones: [TouchZone]) -> Set<String> {
        var controls = Set<String>()

        if let zone = zones.first(where: { $0.kind == .dpad }) {
            let center = CGPoint(x: zone.frame.midX, y: zone.frame.midY)
            let radius = min(zone.frame.width, zone.frame.height) / 2
            let dx = point.x - center.x
            let dy = center.y - point.y
            let distance = hypot(dx, dy)
            if distance >= radius * 0.18, distance <= radius * 1.25 {
                let degrees = atan2(dy, dx) * 180 / .pi
                let sector = (Int((degrees / 45).rounded()) % 8 + 8) % 8
                switch sector {
                case 0: controls.insert("Right")
                case 1: controls.formUnion(["Up", "Right"])
                case 2: controls.insert("Up")
                case 3: controls.formUnion(["Up", "Left"])
                case 4: controls.insert("Left")
                case 5: controls.formUnion(["Down", "Left"])
                case 6: controls.insert("Down")
                default: controls.formUnion(["Down", "Right"])
                }
            }
        }

        let buttons = zones.filter {
            $0.kind == .button && $0.frame.insetBy(dx: -14, dy: -14).contains(point)
        }
        if let nearest = buttons.min(by: { distance(from: point, to: $0.frame) < distance(from: point, to: $1.frame) }) {
            controls.insert(nearest.id)
        }

        if let stick = stickZone(at: point, zones: zones) {
            controls.insert(stick.id)
        }
        return controls
    }

    static func controls(for points: [CGPoint], zones: [TouchZone]) -> Set<String> {
        points.reduce(into: Set<String>()) { result, point in
            result.formUnion(controls(at: point, zones: zones))
        }
    }

    static func stickZone(at point: CGPoint, zones: [TouchZone]) -> TouchZone? {
        zones.first { zone in
            guard zone.kind == .stick else { return false }
            let center = CGPoint(x: zone.frame.midX, y: zone.frame.midY)
            let radius = min(zone.frame.width, zone.frame.height) / 2
            return distance(from: point, to: center) <= radius
        }
    }

    static func stickVector(at point: CGPoint, zone: TouchZone) -> SIMD2<Float> {
        let center = CGPoint(x: zone.frame.midX, y: zone.frame.midY)
        let radius = min(zone.frame.width, zone.frame.height) / 2
        var vector = SIMD2<Float>(
            Float((point.x - center.x) / radius),
            Float((center.y - point.y) / radius)
        )
        let length = hypot(vector.x, vector.y)
        if length > 1 { vector /= length }
        return vector
    }

    private static func distance(from point: CGPoint, to frame: CGRect) -> CGFloat {
        distance(from: point, to: CGPoint(x: frame.midX, y: frame.midY))
    }

    private static func distance(from point: CGPoint, to center: CGPoint) -> CGFloat {
        hypot(point.x - center.x, point.y - center.y)
    }
}
