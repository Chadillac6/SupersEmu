import ArgumentParser
import Foundation
import SupersEmuKit

extension SupersEmuCLI {
    struct Library: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "List, import and review games on the server.",
            subcommands: [List.self, Import.self, Scan.self, Review.self])

        struct List: AsyncParsableCommand {
            static let configuration = CommandConfiguration(abstract: "Games you can see.")
            @OptionGroup var connection: Connection

            func run() async throws {
                let games = try await connection.client().library().games
                if connection.json { return printJSON(games) }
                if games.isEmpty { return print("No games yet. Try `supersemu library import <path>`.") }
                for game in games {
                    print("\(game.id.prefix(12))  \(game.system.rawValue.padding(toLength: 8, withPad: " ", startingAt: 0)) \(game.title)  (\(byteString(game.totalSize)))")
                }
                print("\(games.count) game\(games.count == 1 ? "" : "s")")
            }
        }

        struct Import: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                abstract: "Import files, folders or .zip archives. Paths are read by the server, so run this on the Mac mini or pass server-side paths.")
            @OptionGroup var connection: Connection
            @Argument(help: "Files, folders or .zip archives.") var paths: [String]

            func run() async throws {
                let absolute = paths.map { path -> String in
                    let expanded = (path as NSString).expandingTildeInPath
                    return expanded.hasPrefix("/") ? expanded
                        : URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(expanded).standardizedFileURL.path
                }
                printReport(try await connection.client().importLibrary(ImportRequest(paths: absolute)), json: connection.json)
            }
        }

        struct Scan: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                abstract: "Import everything in the server's Incoming folder. Imported files move to Imported/<date>/; the rest stay put.")
            @OptionGroup var connection: Connection

            func run() async throws {
                printReport(try await connection.client().scanIncoming(), json: connection.json)
            }
        }

        struct Review: AsyncParsableCommand {
            static let configuration = CommandConfiguration(abstract: "Files the server couldn't identify safely.")
            @OptionGroup var connection: Connection

            func run() async throws {
                let items = try await connection.client().reviewQueue()
                if connection.json { return printJSON(items) }
                if items.isEmpty { return print("Review queue is empty.") }
                for item in items { print("\(item.id.prefix(12))  \(item.filename): \(item.reason)") }
                print("\(items.count) item\(items.count == 1 ? " needs" : "s need") review")
            }
        }
    }
}

private func printJSON(_ value: some Encodable) {
    print(String(decoding: (try? SupersEmuJSON.encoder().encode(value)) ?? Data(), as: UTF8.self))
}

private func printReport(_ report: ImportReport, json: Bool) {
    if json { return printJSON(report) }
    for game in report.imported { print("+ \(game.title) [\(game.system.rawValue)]") }
    for item in report.needsReview { print("? \(item.filename): \(item.reason)") }
    for line in report.unsupported { print("- \(line)") }
    print("Imported \(report.imported.count), \(report.duplicates) already in library, \(report.needsReview.count) need review, \(report.unsupported.count) unsupported")
}

private func byteString(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}
