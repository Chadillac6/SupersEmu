import Foundation

/// UserDefaults keys and defaults for the Diagnostics settings, shared by the settings screen and the player.
enum DiagnosticsSettings {
    enum Key {
        static let showPerformanceOverlay = "diagnostics.showPerformanceOverlay"
        static let recordLogs = "diagnostics.recordLogs"
        static let detailedCoreLogs = "diagnostics.detailedCoreLogs"
    }

    enum Default {
        static let showPerformanceOverlay = false
        static let recordLogs = true
        static let detailedCoreLogs = false
    }

    static var recordLogs: Bool {
        UserDefaults.standard.object(forKey: Key.recordLogs) as? Bool ?? Default.recordLogs
    }

    static var detailedCoreLogs: Bool {
        UserDefaults.standard.object(forKey: Key.detailedCoreLogs) as? Bool ?? Default.detailedCoreLogs
    }
}
