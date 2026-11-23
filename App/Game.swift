import Foundation

struct Game: Identifiable, Hashable, Sendable {
    /// SHA-256 of the ROM contents; stable across renames and devices.
    let id: String
    let title: String
    let fileURL: URL
    let console: String
    let hasResumePoint: Bool
}
