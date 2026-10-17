#if os(macOS)
import Foundation

enum UpdateStatus: Equatable {
    case sourceBuild
    case notConfigured
    case checking
    case upToDate(checkedAt: Date)
    case available(version: String)
    case readyToInstall(version: String)
    case failed(message: String, checkedAt: Date?)

    static func initial(isDebugBuild: Bool, isConfigured: Bool, lastCheckDate: Date?) -> UpdateStatus {
        if isDebugBuild { return .sourceBuild }
        guard isConfigured else { return .notConfigured }
        guard let lastCheckDate else { return .checking }
        return .upToDate(checkedAt: lastCheckDate)
    }

    #if DEBUG
    static func previewName(arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: "-UpdateStatusPreview"),
              arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }

    static func preview(arguments: [String], now: Date = Date()) -> UpdateStatus? {
        switch previewName(arguments: arguments) {
        case "sourceBuild": .sourceBuild
        case "checking": .checking
        case "upToDate": .upToDate(checkedAt: now.addingTimeInterval(-5 * 60))
        case "available": .available(version: "0.0.6")
        case "readyToInstall": .readyToInstall(version: "0.0.6")
        case "failed": .failed(message: "Sample update check failure", checkedAt: nil)
        default: nil
        }
    }
    #endif
}

enum UpdateStatusPresentation {
    static func menuText(for status: UpdateStatus, now: Date = Date()) -> String {
        switch status {
        case .sourceBuild:
            "Built from source, update with scripts/update-mac.sh"
        case .notConfigured:
            "Update signing is not configured"
        case .checking:
            "Checking…"
        case .upToDate(let checkedAt):
            "Up to date · checked \(relativeAge(of: checkedAt, now: now))"
        case .available(let version):
            "Downloading \(version)…"
        case .readyToInstall(let version):
            "\(version) ready, installs when you quit"
        case .failed:
            "Update check failed"
        }
    }

    static func versionLabel(shortVersion: String?, buildVersion: String?) -> String {
        "\(shortVersion ?? "Unknown") (\(buildVersion ?? "Unknown"))"
    }

    static var currentVersionLabel: String {
        versionLabel(
            shortVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            buildVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        )
    }

    private static func relativeAge(of date: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return "just now" }
        if seconds < 3_600 { return "\(Int(seconds / 60)) min ago" }
        if seconds < 86_400 { return "\(Int(seconds / 3_600)) hr ago" }
        let days = Int(seconds / 86_400)
        return "\(days) day\(days == 1 ? "" : "s") ago"
    }
}

struct PendingUpdateNotice: Equatable, Identifiable {
    let version: String
    let build: String
    let notes: String

    var id: String { build }
}

enum UpdateNoticeStore {
    static let versionKey = "updates.pendingReleaseNotesVersion"
    static let buildKey = "updates.pendingReleaseNotesBuild"
    static let notesKey = "updates.pendingReleaseNotes"

    static func shouldPresent(savedBuild: String?, runningBuild: String) -> Bool {
        savedBuild == runningBuild
    }

    static func save(version: String, build: String, notes: String, to defaults: UserDefaults = .standard) {
        defaults.set(version, forKey: versionKey)
        defaults.set(build, forKey: buildKey)
        defaults.set(notes, forKey: notesKey)
    }

    static func consume(forRunningBuild runningBuild: String, from defaults: UserDefaults = .standard) -> PendingUpdateNotice? {
        guard let build = defaults.string(forKey: buildKey),
              shouldPresent(savedBuild: build, runningBuild: runningBuild),
              let version = defaults.string(forKey: versionKey),
              let notes = defaults.string(forKey: notesKey) else { return nil }
        clear(from: defaults)
        return PendingUpdateNotice(version: version, build: build, notes: notes)
    }

    static func clear(from defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: versionKey)
        defaults.removeObject(forKey: buildKey)
        defaults.removeObject(forKey: notesKey)
    }

    static func plainTextNotes(_ notes: String?, format: String?) -> String {
        guard let notes else { return "" }
        let isHTML = format?.lowercased() == "html"
            || notes.range(of: "<[^>]+>", options: .regularExpression) != nil
        guard isHTML else { return notes.trimmingCharacters(in: .whitespacesAndNewlines) }

        var text = notes
            .replacingOccurrences(of: "(?i)<br\\s*/?>", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "(?i)</li\\s*>", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "(?i)</p\\s*>", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        for (entity, character) in [
            ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
            ("&quot;", "\""), ("&apos;", "'"), ("&#39;", "'"), ("&nbsp;", " ")
        ] {
            text = text.replacingOccurrences(of: entity, with: character, options: .caseInsensitive)
        }
        return text
            .replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: " *\\n *", with: "\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
#endif
