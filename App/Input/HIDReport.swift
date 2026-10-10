import Foundation

/// One input field from a HID report descriptor.
struct HIDElement: Equatable, Sendable {
    var reportID: UInt8
    var bitOffset: Int
    var bitSize: Int
    var usagePage: UInt16
    var usage: UInt16
    var logicalMin: Int32
    var logicalMax: Int32
}

enum HIDUsage {
    static let genericDesktop: UInt16 = 0x01
    static let button: UInt16 = 0x09
    static let x: UInt16 = 0x30, y: UInt16 = 0x31, z: UInt16 = 0x32
    static let rx: UInt16 = 0x33, ry: UInt16 = 0x34, rz: UInt16 = 0x35
    static let hatSwitch: UInt16 = 0x39
}

/// The input fields of a gamepad's report descriptor (HID 1.11 section 6.2.2), enough to decode its reports.
struct HIDReportDescriptor: Equatable, Sendable {
    var elements: [HIDElement] = []
    var usesReportIDs = false

    init(elements: [HIDElement], usesReportIDs: Bool) {
        self.elements = elements
        self.usesReportIDs = usesReportIDs
    }

    init(_ bytes: [UInt8]) {
        struct Globals {
            var usagePage: UInt16 = 0
            var logicalMin: Int32 = 0
            var logicalMax: Int32 = 0
            var reportSize = 0
            var reportCount = 0
            var reportID: UInt8 = 0
        }
        var globals = Globals()
        var stack: [Globals] = []
        var usages: [UInt32] = []
        var usageMin: UInt32?
        var usageMax: UInt32?
        var offsets: [UInt8: Int] = [:]
        var i = 0
        while i < bytes.count {
            let prefix = bytes[i]
            if prefix == 0xFE {  // Long item: skip it.
                guard i + 1 < bytes.count else { break }
                i += 3 + Int(bytes[i + 1])
                continue
            }
            let size = [0, 1, 2, 4][Int(prefix & 0x03)]
            guard i + size < bytes.count else { break }
            var unsigned: UInt32 = 0
            for k in 0..<size { unsigned |= UInt32(bytes[i + 1 + k]) << (8 * UInt32(k)) }
            let signed: Int32 = switch size {
            case 1: Int32(Int8(truncatingIfNeeded: unsigned))
            case 2: Int32(Int16(truncatingIfNeeded: unsigned))
            default: Int32(bitPattern: unsigned)
            }
            i += 1 + size
            switch prefix & 0xFC {
            case 0x80:  // Input
                let isConstant = unsigned & 0x01 != 0
                let isVariable = unsigned & 0x02 != 0
                var expanded = usages
                if let usageMin, let usageMax, usageMin <= usageMax, usageMax - usageMin < 1024 {
                    expanded += Array(usageMin...usageMax)
                }
                let start = offsets[globals.reportID, default: 0]
                if !isConstant, isVariable {
                    for n in 0..<globals.reportCount {
                        guard let raw = expanded.isEmpty ? nil : expanded[min(n, expanded.count - 1)] else { break }
                        let page = raw > 0xFFFF ? UInt16(raw >> 16) : globals.usagePage
                        elements.append(HIDElement(reportID: globals.reportID, bitOffset: start + n * globals.reportSize,
                                                   bitSize: globals.reportSize, usagePage: page, usage: UInt16(raw & 0xFFFF),
                                                   logicalMin: globals.logicalMin, logicalMax: globals.logicalMax))
                    }
                }
                offsets[globals.reportID] = start + globals.reportSize * globals.reportCount
                usages = []; usageMin = nil; usageMax = nil
            case 0x90, 0xB0, 0xA0, 0xC0:  // Output and Feature fields don't move input offsets; Collection; End Collection
                usages = []; usageMin = nil; usageMax = nil
            case 0x04: globals.usagePage = UInt16(truncatingIfNeeded: unsigned)
            case 0x14: globals.logicalMin = signed
            case 0x24: globals.logicalMax = globals.logicalMin >= 0 && size < 4 ? Int32(unsigned) : signed
            case 0x74: globals.reportSize = Int(unsigned)
            case 0x84: globals.reportID = UInt8(truncatingIfNeeded: unsigned); usesReportIDs = true
            case 0x94: globals.reportCount = Int(unsigned)
            case 0xA4: stack.append(globals)
            case 0xB4: if let popped = stack.popLast() { globals = popped }
            case 0x08: usages.append(size == 4 ? unsigned : unsigned & 0xFFFF)
            case 0x18: usageMin = size == 4 ? unsigned : unsigned & 0xFFFF
            case 0x28: usageMax = size == 4 ? unsigned : unsigned & 0xFFFF
            default: break
            }
        }
    }

    /// Reads one input report as delivered by IOKit (prefixed with the report ID when the device uses them).
    func decode(_ report: [UInt8]) -> HIDGamepadReport? {
        var payload = report[...]
        var reportID: UInt8 = 0
        if usesReportIDs {
            guard let first = report.first else { return nil }
            reportID = first
            payload = report.dropFirst()
        }
        let fields = elements.filter { $0.reportID == reportID }
        guard !fields.isEmpty else { return nil }
        let bytes = Array(payload)
        var result = HIDGamepadReport()
        for field in fields {
            guard let raw = Self.bits(bytes, offset: field.bitOffset, count: field.bitSize) else { continue }
            let signed = field.logicalMin < 0
            let value: Int32 = signed ? Self.signExtend(raw, bits: field.bitSize) : Int32(truncatingIfNeeded: raw)
            switch (field.usagePage, field.usage) {
            case (HIDUsage.button, let number):
                if value != 0 { result.buttons.insert(Int(number)) }
            case (HIDUsage.genericDesktop, HIDUsage.hatSwitch):
                let range = field.logicalMax - field.logicalMin
                // Only 8-way hats (logical range 0...7); values outside it mean centred.
                if range == 7, value >= field.logicalMin, value <= field.logicalMax { result.hat = Int(value - field.logicalMin) }
            case (HIDUsage.genericDesktop, let usage) where (HIDUsage.x...HIDUsage.rz).contains(usage):
                let span = Float(field.logicalMax - field.logicalMin)
                guard span > 0 else { continue }
                let clamped = min(max(value, field.logicalMin), field.logicalMax)
                result.axes[usage] = (Float(clamped - field.logicalMin) / span) * 2 - 1
            default:
                break
            }
        }
        return result
    }

    private static func bits(_ bytes: [UInt8], offset: Int, count: Int) -> UInt32? {
        guard count > 0, count <= 32, offset + count <= bytes.count * 8 else { return nil }
        var value: UInt32 = 0
        for n in 0..<count {
            let bit = offset + n
            if bytes[bit / 8] & (1 << UInt8(bit % 8)) != 0 { value |= 1 << UInt32(n) }
        }
        return value
    }

    private static func signExtend(_ value: UInt32, bits: Int) -> Int32 {
        guard bits < 32 else { return Int32(bitPattern: value) }
        let shift = UInt32(32 - bits)
        return Int32(bitPattern: value << shift) >> Int32(shift)
    }
}

/// A decoded report: pressed button numbers (1-based HID usages), hat direction 0 (up) ... 7 clockwise, axes -1...1.
struct HIDGamepadReport: Equatable, Sendable {
    var buttons: Set<Int> = []
    var hat: Int?
    var axes: [UInt16: Float] = [:]
}
