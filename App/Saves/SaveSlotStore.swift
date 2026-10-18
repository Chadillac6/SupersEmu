import CryptoKit
import Foundation
import ImageIO
import SupersEmuKit

struct SaveSlotInfo: Equatable, Identifiable {
    let slot: Int
    let savedAt: Date?
    let screenshotURL: URL?
    /// The device that made this save when it came from another device; nil for this device's own saves.
    var deviceName: String? = nil
    /// Came from another device and hasn't been seen in the Save States panel yet.
    var isNew = false

    var isEmpty: Bool { savedAt == nil }
    var id: Int { slot }
}

enum SaveSlotError: Error, LocalizedError, Equatable {
    case occupied(Int)
    case invalidSlot(Int)

    var errorDescription: String? {
        switch self {
        case .occupied(let slot): "Slot \(slot) already contains a save."
        case .invalidSlot(let slot): "Slot \(slot) is invalid."
        }
    }
}

struct SaveSlotStore {
    private struct Metadata: Codable {
        let savedAt: Date
        let stateSHA256: String
        let screenshotSHA256: String?
        var deviceName: String?
        var isNew: Bool?
    }

    static let slots = 1...3
    let directory: URL

    func stateURL(_ slot: Int) -> URL {
        directory.appendingPathComponent("slot\(slot).state")
    }

    private func metadataURL(_ slot: Int) -> URL {
        directory.appendingPathComponent("slot\(slot).json")
    }

    func screenshotURL(_ slot: Int) -> URL {
        directory.appendingPathComponent("slot\(slot).png")
    }

    static func lineSlot(_ slot: Int) -> String { "slot\(slot)" }

    func slots() -> [SaveSlotInfo] {
        Self.slots.map { slot in
            let state = stateURL(slot)
            guard FileManager.default.fileExists(atPath: state.path) else {
                return SaveSlotInfo(slot: slot, savedAt: nil, screenshotURL: nil)
            }

            if let data = try? Data(contentsOf: state),
               let metadataData = try? Data(contentsOf: metadataURL(slot)),
               let metadata = try? JSONDecoder().decode(Metadata.self, from: metadataData),
               metadata.stateSHA256 == Self.sha256(data) {
                let screenshot = screenshotURL(slot)
                let screenshotData = try? Data(contentsOf: screenshot)
                let validScreenshotURL: URL?
                if let screenshotSHA256 = metadata.screenshotSHA256,
                   let screenshotData,
                   Self.sha256(screenshotData) == screenshotSHA256 {
                    validScreenshotURL = screenshot
                } else {
                    validScreenshotURL = nil
                }
                return SaveSlotInfo(slot: slot, savedAt: metadata.savedAt,
                                    screenshotURL: validScreenshotURL, deviceName: metadata.deviceName,
                                    isNew: metadata.isNew == true)
            }

            let savedAt = (try? FileManager.default.attributesOfItem(atPath: state.path)[.modificationDate]) as? Date
            return SaveSlotInfo(slot: slot, savedAt: savedAt, screenshotURL: nil)
        }
    }

    /// Returns the newest slot screenshot whose state and screenshot still match their saved metadata.
    func latestScreenshotURL() -> URL? {
        slots()
            .compactMap { slot -> (Date, URL)? in
                guard let savedAt = slot.savedAt, let screenshotURL = slot.screenshotURL else { return nil }
                return (savedAt, screenshotURL)
            }
            .max { $0.0 < $1.0 }?
            .1
    }

    func save(into slot: Int, savedAt: Date, screenshotPNG: Data?, writeState: (URL) throws -> Void) throws {
        try validate(slot)
        guard !FileManager.default.fileExists(atPath: stateURL(slot).path) else {
            throw SaveSlotError.occupied(slot)
        }
        try write(slot, savedAt: savedAt, screenshotPNG: screenshotPNG, replaceExisting: false, writeState: writeState)
    }

    func overwrite(_ slot: Int, savedAt: Date, screenshotPNG: Data?, writeState: (URL) throws -> Void) throws {
        try validate(slot)
        try write(slot, savedAt: savedAt, screenshotPNG: screenshotPNG, replaceExisting: true, writeState: writeState)
    }

    private func write(
        _ slot: Int,
        savedAt: Date,
        screenshotPNG: Data?,
        replaceExisting: Bool,
        writeState: (URL) throws -> Void
    ) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = stateURL(slot)
        let stateTemporary = directory.appendingPathComponent("slot\(slot).state.tmp")
        let metadataTemporary = directory.appendingPathComponent("slot\(slot).json.tmp")
        let screenshotTemporary = directory.appendingPathComponent("slot\(slot).png.tmp")
        let temporaryFiles = [stateTemporary, metadataTemporary, screenshotTemporary]
        for url in temporaryFiles {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue {
                try? FileManager.default.removeItem(at: url)
            }
        }

        let stateData: Data
        do {
            try writeState(stateTemporary)
            stateData = try Data(contentsOf: stateTemporary)
        } catch {
            removeTemporaryFiles(temporaryFiles)
            throw error
        }

        var hasStagedScreenshot = false
        var screenshotSHA256: String?
        if let screenshotPNG {
            do {
                try screenshotPNG.write(to: screenshotTemporary, options: .atomic)
                let stagedScreenshot = try Data(contentsOf: screenshotTemporary)
                screenshotSHA256 = Self.sha256(stagedScreenshot)
                hasStagedScreenshot = true
            } catch {
                try? FileManager.default.removeItem(at: screenshotTemporary)
            }
        }

        do {
            let metadata = Metadata(
                savedAt: savedAt,
                stateSHA256: Self.sha256(stateData),
                screenshotSHA256: screenshotSHA256
            )
            try JSONEncoder().encode(metadata).write(to: metadataTemporary, options: .atomic)
        } catch {
            removeTemporaryFiles(temporaryFiles)
            throw error
        }

        do {
            if replaceExisting, FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: stateTemporary)
            } else {
                try FileManager.default.moveItem(at: stateTemporary, to: destination)
            }
        } catch {
            removeTemporaryFiles(temporaryFiles)
            throw error
        }

        if hasStagedScreenshot {
            if !replaceOrMove(screenshotTemporary, to: screenshotURL(slot)) {
                try? FileManager.default.removeItem(at: screenshotURL(slot))
            }
        } else {
            try? FileManager.default.removeItem(at: screenshotURL(slot))
        }
        replaceOrMove(metadataTemporary, to: metadataURL(slot))
        removeTemporaryFiles(temporaryFiles)
    }

    func delete(_ slot: Int) throws {
        try validate(slot)
        for url in [stateURL(slot), metadataURL(slot), screenshotURL(slot)] where FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    func recordRemote(_ slot: Int, savedAt: Date, deviceName: String? = nil, screenshotPNG: Data? = nil) {
        guard Self.slots.contains(slot) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let state = stateURL(slot)
        guard let data = try? Data(contentsOf: state) else {
            try? FileManager.default.removeItem(at: metadataURL(slot))
            try? FileManager.default.removeItem(at: screenshotURL(slot))
            return
        }
        try? FileManager.default.removeItem(at: screenshotURL(slot))
        var screenshotSHA256: String?
        if let screenshotPNG, (try? screenshotPNG.write(to: screenshotURL(slot), options: .atomic)) != nil {
            screenshotSHA256 = Self.sha256(screenshotPNG)
        }
        if let metadataData = try? JSONEncoder().encode(Metadata(
            savedAt: savedAt,
            stateSHA256: Self.sha256(data),
            screenshotSHA256: screenshotSHA256,
            deviceName: deviceName,
            isNew: deviceName != nil
        )) {
            try? metadataData.write(to: metadataURL(slot), options: .atomic)
        }
    }

    /// Clears the "new from another device" mark on every slot.
    func markSeen() {
        for slot in Self.slots {
            guard let data = try? Data(contentsOf: metadataURL(slot)),
                  var metadata = try? JSONDecoder().decode(Metadata.self, from: data), metadata.isNew == true else { continue }
            metadata.isNew = false
            if let encoded = try? JSONEncoder().encode(metadata) { try? encoded.write(to: metadataURL(slot), options: .atomic) }
        }
    }

    static func pngData(from image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    private func validate(_ slot: Int) throws {
        guard Self.slots.contains(slot) else { throw SaveSlotError.invalidSlot(slot) }
    }

    private func replaceOrMove(_ temporary: URL, to destination: URL) -> Bool {
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
            } else {
                try FileManager.default.moveItem(at: temporary, to: destination)
            }
            return true
        } catch {
            return false
        }
    }

    private func removeTemporaryFiles(_ urls: [URL]) {
        for url in urls {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private static func sha256(_ data: Data) -> String {
        Hashing.sha256Hex(data)
    }
}
