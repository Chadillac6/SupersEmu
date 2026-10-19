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
    /// The state file was saved, but its date and screenshot record wasn't.
    case metadataNotRecorded(Int, String)

    var errorDescription: String? {
        switch self {
        case .occupied(let slot): "Slot \(slot) already contains a save."
        case .invalidSlot(let slot): "Slot \(slot) is invalid."
        case .metadataNotRecorded(let slot, let reason): "Slot \(slot) was saved, but its details weren't: \(reason)"
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

    private static let linePrefix = "slot"

    func stateURL(_ slot: Int) -> URL {
        fileURL(slot, "state")
    }

    private func metadataURL(_ slot: Int) -> URL {
        fileURL(slot, "json")
    }

    func screenshotURL(_ slot: Int) -> URL {
        fileURL(slot, "png")
    }

    private func fileURL(_ slot: Int, _ suffix: String) -> URL {
        directory.appendingPathComponent("\(Self.lineSlot(slot)).\(suffix)")
    }

    /// The SaveSync line name for a slot ("slot2"); `slot(fromLine:)` reads it back.
    static func lineSlot(_ slot: Int) -> String { "\(linePrefix)\(slot)" }

    /// The slot a `lineSlot(_:)` name refers to, or nil when it isn't a valid slot.
    static func slot(fromLine line: String) -> Int? {
        guard line.hasPrefix(linePrefix), let slot = Int(line.dropFirst(linePrefix.count)), slots.contains(slot) else { return nil }
        return slot
    }

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
        let stateTemporary = fileURL(slot, "state.tmp")
        let metadataTemporary = fileURL(slot, "json.tmp")
        let screenshotTemporary = fileURL(slot, "png.tmp")
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

        // The state is committed. A missing screenshot only hides the picture (its hash no longer matches),
        // but a missing metadata file pairs the new state with stale details, so that is reported.
        if hasStagedScreenshot {
            do {
                try replaceOrMove(screenshotTemporary, to: screenshotURL(slot))
            } catch {
                try? FileManager.default.removeItem(at: screenshotURL(slot))
            }
        } else {
            try? FileManager.default.removeItem(at: screenshotURL(slot))
        }
        do {
            try replaceOrMove(metadataTemporary, to: metadataURL(slot))
        } catch {
            removeTemporaryFiles(temporaryFiles)
            throw SaveSlotError.metadataNotRecorded(slot, error.localizedDescription)
        }
        removeTemporaryFiles(temporaryFiles)
    }

    func delete(_ slot: Int) throws {
        try validate(slot)
        for url in [stateURL(slot), metadataURL(slot), screenshotURL(slot)] where FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    /// Records the details of a slot state that another device saved. The screenshot is optional, so failing
    /// to write it only drops the picture; failing to write the metadata throws.
    func recordRemote(_ slot: Int, savedAt: Date, deviceName: String? = nil, screenshotPNG: Data? = nil) throws {
        try validate(slot)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let state = stateURL(slot)
        guard FileManager.default.fileExists(atPath: state.path) else {
            try removeIfPresent(metadataURL(slot))
            try removeIfPresent(screenshotURL(slot))
            return
        }
        let data = try Data(contentsOf: state)
        try removeIfPresent(screenshotURL(slot))
        var screenshotSHA256: String?
        if let screenshotPNG, (try? screenshotPNG.write(to: screenshotURL(slot), options: .atomic)) != nil {
            screenshotSHA256 = Self.sha256(screenshotPNG)
        }
        let metadataData = try JSONEncoder().encode(Metadata(
            savedAt: savedAt,
            stateSHA256: Self.sha256(data),
            screenshotSHA256: screenshotSHA256,
            deviceName: deviceName,
            isNew: deviceName != nil
        ))
        try metadataData.write(to: metadataURL(slot), options: .atomic)
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

    private func replaceOrMove(_ temporary: URL, to destination: URL) throws {
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: destination)
        }
    }

    private func removeIfPresent(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
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
