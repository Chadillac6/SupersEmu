import ArgumentParser
import Foundation
import SupersEmuKit

struct Library: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List, import and review games on the server.",
        subcommands: [List.self, Import.self, Scan.self, Review.self])

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Games you can see.")
        @OptionGroup var connection: Connection

        func run() async throws {
            try await CLIOutput.run(json: connection.json) {
                let games = try await connection.client().library().games
                if connection.json { return try CLIOutput.json(games) }
                if games.isEmpty { return CLIOutput.stdout("No games yet. Try `supersemu library import <path>`.") }
                CLIOutput.table(["ID", "SYSTEM", "SIZE", "TITLE"], games.map {
                    [String($0.id.prefix(12)), $0.system.rawValue, ByteCountFormatter.string(fromByteCount: $0.totalSize, countStyle: .file), $0.title]
                })
            }
        }
    }

    struct Import: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Import files, folders or .zip archives. The server reads these paths, so run this on the Mac mini or pass server-side paths.")
        @Argument(help: "Files, folders or .zip archives.") var paths: [String]
        @OptionGroup var connection: Connection

        func run() async throws {
            try await CLIOutput.run(json: connection.json) {
                let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
                let absolute = paths.map { path -> String in
                    let expanded = (path as NSString).expandingTildeInPath
                    return expanded.hasPrefix("/") ? expanded : cwd.appendingPathComponent(expanded).standardizedFileURL.path
                }
                try printReport(try await connection.client().importLibrary(ImportRequest(paths: absolute)), json: connection.json)
            }
        }
    }

    struct Scan: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Import everything in the server's Incoming folder. Imported files move to Imported/<date>/; the rest stay put.")
        @OptionGroup var connection: Connection

        func run() async throws {
            try await CLIOutput.run(json: connection.json) {
                try printReport(try await connection.client().scanIncoming(), json: connection.json)
            }
        }
    }

    struct Review: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Files the server couldn't identify safely.")
        @OptionGroup var connection: Connection

        func run() async throws {
            try await CLIOutput.run(json: connection.json) {
                let items = try await connection.client().reviewQueue()
                if connection.json { return try CLIOutput.json(items) }
                if items.isEmpty { return CLIOutput.stdout("Review queue is empty.") }
                CLIOutput.table(["ID", "FILE", "REASON"], items.map { [String($0.id.prefix(12)), $0.filename, $0.reason] })
            }
        }
    }
}

private func printReport(_ report: ImportReport, json: Bool) throws {
    if json { return try CLIOutput.json(report) }
    for game in report.imported { CLIOutput.stdout("+ \(game.title) [\(game.system.rawValue)]") }
    for item in report.needsReview { CLIOutput.stdout("? \(item.filename): \(item.reason)") }
    for line in report.unsupported { CLIOutput.stdout("- \(line)") }
    CLIOutput.stdout("Imported \(report.imported.count), \(report.duplicates) already in library, \(report.needsReview.count) need review, \(report.unsupported.count) unsupported")
}
