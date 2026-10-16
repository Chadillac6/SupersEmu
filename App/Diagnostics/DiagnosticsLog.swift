import Dispatch
import Foundation

final class DiagnosticsLog: @unchecked Sendable {
    struct Header {
        let appVersion: String
        let appBuild: String
        let deviceModel: String
        let osVersion: String
        let lowPowerMode: Bool
        let gameTitle: String
        let gameID: String
        let system: String
        let coreName: String
        let coreVersion: String
        let sampleRate: Double
        let framesPerSecond: Double
        let n64Preset: String
        let coreOptions: [String: String]
    }

    struct LogFile: Identifiable {
        let url: URL
        let date: Date
        let gameTitle: String
        let size: Int64

        var id: URL { url }
    }

    static let defaultDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("SupersEmu/Diagnostics", isDirectory: true)

    let url: URL

    private let queue = DispatchQueue(label: "com.chadillac6.supersemu.diagnostics", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var fileHandle: FileHandle?
    private var pendingText = ""
    private var pendingCoreLine: String?
    private var preHeaderCoreLines: [String] = []
    private var pendingCoreRepeatCount = 0
    private var writtenCoreRepeatCount = 0
    private var pendingCoreLineWritten = false
    private var coreLineCount = 0
    private var isStopped = false
    private var hasWrittenHeader = false

    init(title: String, directory: URL = DiagnosticsLog.defaultDirectory, date: Date = Date()) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.timeZone = .current
        dateFormatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = dateFormatter.string(from: date)
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let sanitized = title.components(separatedBy: allowed.inverted).filter { !$0.isEmpty }.joined(separator: "-")
        let safeTitle = sanitized.isEmpty ? "game" : sanitized
        let stem = "\(stamp)-\(safeTitle)"
        var candidate = directory.appendingPathComponent("\(stem).log")
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(stem)-\(suffix).log")
            suffix += 1
        }
        url = candidate
        FileManager.default.createFile(atPath: candidate.path, contents: nil)
        fileHandle = try FileHandle(forWritingTo: candidate)
        fileHandle?.seekToEndOfFile()
        Self.retainNewestLogs(in: directory)

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { [weak self] in self?.flushOnQueue() }
        self.timer = timer
        timer.resume()
    }

    func writeHeader(_ header: Header) {
        queue.async {
            guard !self.isStopped else { return }
            self.pendingText += """
            SupersEmu diagnostics
            appVersion=\(header.appVersion)
            appBuild=\(header.appBuild)
            deviceModel=\(header.deviceModel)
            osVersion=\(header.osVersion)
            lowPowerMode=\(header.lowPowerMode)
            gameTitle=\(header.gameTitle)
            gameID=\(header.gameID)
            system=\(header.system)
            coreName=\(header.coreName)
            coreVersion=\(header.coreVersion)
            sampleRate=\(header.sampleRate)
            fps=\(header.framesPerSecond)
            n64Preset=\(header.n64Preset)
            coreOptions:
            """
            self.pendingText += "\n"
            for key in header.coreOptions.keys.sorted() {
                self.pendingText += "  \(key)=\(header.coreOptions[key] ?? "")\n"
            }
            self.pendingText += "started=\(Self.timestamp())\n"
            self.hasWrittenHeader = true
            for line in self.preHeaderCoreLines {
                self.appendCoreLine(line)
            }
            self.preHeaderCoreLines.removeAll(keepingCapacity: true)
        }
    }

    func appendEvent(_ event: String) {
        queue.async {
            guard !self.isStopped else { return }
            self.flushPendingCoreLine(reset: true)
            self.pendingText += "\(Self.timestamp()) event \(event)\n"
        }
    }

    func appendPerformance(_ summary: PerformanceStats.Summary, thermalState: String) {
        queue.async {
            guard !self.isStopped else { return }
            self.flushPendingCoreLine(reset: true)
            self.pendingText += summary.performanceLine(thermalState: thermalState) + "\n"
        }
    }

    func appendCoreLog(level: Int, message: String, detailedCoreLogging: Bool) {
        guard level >= 2 || detailedCoreLogging else { return }
        let name: String
        switch level {
        case 0: name = "DEBUG"
        case 1: name = "INFO"
        case 2: name = "WARN"
        default: name = "ERROR"
        }
        let line = "[\(name)] \(message)"
        queue.async {
            guard !self.isStopped, self.coreLineCount < 5000 else { return }
            self.coreLineCount += 1
            if !self.hasWrittenHeader {
                self.preHeaderCoreLines.append(line)
            } else {
                self.appendCoreLine(line)
            }
        }
    }

    func flush() {
        queue.sync { flushOnQueue() }
    }

    func stop() {
        queue.sync {
            guard !self.isStopped else { return }
            self.isStopped = true
            self.timer?.cancel()
            self.timer = nil
            for line in self.preHeaderCoreLines {
                self.appendCoreLine(line)
            }
            self.preHeaderCoreLines.removeAll(keepingCapacity: true)
            self.flushPendingCoreLine(reset: true)
            self.writePendingText()
            self.fileHandle?.synchronizeFile()
            self.fileHandle?.closeFile()
            self.fileHandle = nil
        }
    }

    static func files(in directory: URL = defaultDirectory) -> [LogFile] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles])) ?? []
        return urls.filter { $0.pathExtension == "log" }.map { url in
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let contents = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            let title = contents.split(separator: "\n").first(where: { $0.hasPrefix("gameTitle=") })
                .map { String($0.dropFirst("gameTitle=".count)) }
                ?? url.deletingPathExtension().lastPathComponent
            return LogFile(
                url: url,
                date: values?.contentModificationDate ?? .distantPast,
                gameTitle: title,
                size: Int64(values?.fileSize ?? 0))
        }
        .sorted { $0.date > $1.date }
    }

    static func deleteAll(in directory: URL = defaultDirectory) {
        for file in files(in: directory) {
            try? FileManager.default.removeItem(at: file.url)
        }
    }

    static func retainNewestLogs(in directory: URL, limit: Int = 20) {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles])) ?? []
        let logs = files.filter { $0.pathExtension == "log" }.sorted {
            let first = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let second = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if first == second { return $0.lastPathComponent > $1.lastPathComponent }
            return first > second
        }
        for file in logs.dropFirst(max(limit, 0)) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    private func flushOnQueue() {
        guard !isStopped else { return }
        flushPendingCoreLine(reset: false)
        writePendingText()
        fileHandle?.synchronizeFile()
    }

    private func flushPendingCoreLine(reset: Bool) {
        if let line = pendingCoreLine {
            if !pendingCoreLineWritten {
                pendingText += "core \(line)\n"
                pendingCoreLineWritten = true
            }
            if pendingCoreRepeatCount > writtenCoreRepeatCount {
                pendingText += "core (repeated \(pendingCoreRepeatCount - writtenCoreRepeatCount) times)\n"
                writtenCoreRepeatCount = pendingCoreRepeatCount
            }
        }
        if reset {
            pendingCoreLine = nil
            pendingCoreRepeatCount = 0
            writtenCoreRepeatCount = 0
            pendingCoreLineWritten = false
        }
    }

    private func appendCoreLine(_ line: String) {
        if line == pendingCoreLine {
            pendingCoreRepeatCount += 1
        } else {
            flushPendingCoreLine(reset: true)
            pendingCoreLine = line
            pendingCoreRepeatCount = 0
            writtenCoreRepeatCount = 0
            pendingCoreLineWritten = false
        }
    }

    private func writePendingText() {
        guard !pendingText.isEmpty else { return }
        if let data = pendingText.data(using: .utf8) {
            try? fileHandle?.write(contentsOf: data)
        }
        pendingText.removeAll(keepingCapacity: true)
    }

    private static func timestamp() -> String {
        ISO8601DateFormatter().string(from: Date())
    }
}
