import os

/// Unified-logging channels for app events outside a game session (`log show --predicate 'subsystem == "com.chadillac6.supersemu"'`).
enum AppLog {
    static let connection = Logger(subsystem: "com.chadillac6.supersemu", category: "connection")
    static let input = Logger(subsystem: "com.chadillac6.supersemu", category: "input")
}
