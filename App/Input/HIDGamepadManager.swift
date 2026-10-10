#if os(macOS)
import GameController
import IOKit.hid

/// USB/Bluetooth HID gamepads that GameController ignores (Retrolink and other DragonRise boards, generic pads).
final class HIDGamepad: Identifiable {
    let id: UInt64
    let vendorID: Int
    let productID: Int
    let productName: String
    let descriptor: HIDReportDescriptor
    fileprivate let device: IOHIDDevice
    fileprivate var buffer: UnsafeMutablePointer<UInt8>
    fileprivate let bufferSize: Int
    private(set) var report = HIDGamepadReport()

    var controllerType: String { HIDPreset.controllerType(vendorID: vendorID, productID: productID) }

    fileprivate init(device: IOHIDDevice, id: UInt64) {
        self.device = device
        self.id = id
        vendorID = Self.intProperty(device, kIOHIDVendorIDKey) ?? 0
        productID = Self.intProperty(device, kIOHIDProductIDKey) ?? 0
        productName = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? "USB gamepad"
        let bytes = (IOHIDDeviceGetProperty(device, kIOHIDReportDescriptorKey as CFString) as? Data).map(Array.init) ?? []
        descriptor = HIDReportDescriptor(bytes)
        bufferSize = max(Self.intProperty(device, kIOHIDMaxInputReportSizeKey) ?? 64, 64)
        buffer = .allocate(capacity: bufferSize)
    }

    deinit { buffer.deallocate() }

    fileprivate func receive(_ bytes: UnsafePointer<UInt8>, length: Int) {
        let report = [UInt8](UnsafeBufferPointer(start: bytes, count: length))
        if let decoded = descriptor.decode(report) { self.report = decoded }
    }

    private static func intProperty(_ device: IOHIDDevice, _ key: String) -> Int? {
        (IOHIDDeviceGetProperty(device, key as CFString) as? NSNumber)?.intValue
    }
}

/// Watches for HID joysticks/gamepads with hot-plug, skipping anything GCController drives.
final class HIDGamepadManager {
    private(set) var gamepads: [HIDGamepad] = []
    var onChange: (() -> Void)?
    private let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    private var nextID: UInt64 = 1

    init() {
        let usages = [kHIDUsage_GD_Joystick, kHIDUsage_GD_GamePad, kHIDUsage_GD_MultiAxisController].map {
            [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: $0] as CFDictionary
        }
        IOHIDManagerSetDeviceMatchingMultiple(manager, usages as CFArray)
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, device in
            guard let context else { return }
            Unmanaged<HIDGamepadManager>.fromOpaque(context).takeUnretainedValue().attach(device)
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, device in
            guard let context else { return }
            Unmanaged<HIDGamepadManager>.fromOpaque(context).takeUnretainedValue().detach(device)
        }, context)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    deinit {
        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    private func attach(_ device: IOHIDDevice) {
        // GCController already reads Xbox, PlayStation, Switch, MFi and most 8BitDo pads; reading them here too would double every press.
        guard !GCController.supportsHIDDevice(device), !gamepads.contains(where: { $0.device === device }) else { return }
        let pad = HIDGamepad(device: device, id: nextID)
        nextID += 1
        guard !pad.descriptor.elements.isEmpty else { return }
        gamepads.append(pad)
        IOHIDDeviceRegisterInputReportCallback(device, pad.buffer, pad.bufferSize, { context, result, _, _, _, report, length in
            guard let context, result == kIOReturnSuccess else { return }
            Unmanaged<HIDGamepad>.fromOpaque(context).takeUnretainedValue().receive(report, length: length)
        }, Unmanaged.passUnretained(pad).toOpaque())
        onChange?()
    }

    private func detach(_ device: IOHIDDevice) {
        guard let index = gamepads.firstIndex(where: { $0.device === device }) else { return }
        let pad = gamepads.remove(at: index)
        IOHIDDeviceRegisterInputReportCallback(device, pad.buffer, pad.bufferSize, nil, nil)
        onChange?()
    }
}
#endif
