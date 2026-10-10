import ArgumentParser
import Foundation
import SupersEmuKit

/// Errors the CLI reports with a stable exit code (documented in docs/specs/cli.md).
enum CLIError: Error, Equatable, CustomStringConvertible {
    case usage(String)
    case unreachable(String)
    case http(status: Int, message: String?)
    case unexpected(String)

    var exitCode: Int32 {
        switch self {
        case .usage: return 64
        case .unexpected: return 1
        case .unreachable: return 5
        case .http(let status, _):
            switch status {
            case 404: return 2
            case 401: return 3
            case 403: return 4
            case 500...: return 7
            default: return 6
            }
        }
    }

    var status: Int? { if case .http(let status, _) = self { return status }; return nil }

    var description: String {
        switch self {
        case .usage(let message), .unreachable(let message), .unexpected(let message): return message
        case .http(let status, let message):
            let hint = status == 401 ? " (check --server/--token, SUPERSEMU_TOKEN or `supersemu login`)" : ""
            return "HTTP \(status): \(message ?? HTTPURLResponse.localizedString(forStatusCode: status))\(hint)"
        }
    }

    init(_ error: Error) {
        switch error {
        case let error as CLIError: self = error
        case APIClientError.http(let status, let message): self = .http(status: status, message: message)
        case APIClientError.invalidResponse: self = .http(status: 502, message: "Invalid response from server")
        case let error as URLError: self = .unreachable("Can't reach server: \(error.localizedDescription)")
        case is DecodingError: self = .http(status: 502, message: "Unexpected response from server: \(error)")
        case let error as LocalizedError: self = .unexpected(error.errorDescription ?? "\(error)")
        default: self = .unexpected((error as NSError).localizedDescription)
        }
    }
}

/// All CLI output goes through here so tests can capture it.
enum CLIOutput {
    static var stdout: (String) -> Void = { print($0) }
    static var stderr: (String) -> Void = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }

    static func encoder() -> JSONEncoder {
        let encoder = SupersEmuJSON.encoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        return encoder
    }

    static func json<T: Encodable>(_ value: T) throws {
        stdout(String(decoding: try encoder().encode(value), as: UTF8.self))
    }

    /// Runs a command body, turning any failure into a message on stderr (JSON with `--json`)
    /// and a non-zero exit code.
    static func run(json: Bool, _ body: () async throws -> Void) async throws {
        do {
            try await body()
        } catch let exit as ExitCode {
            throw exit
        } catch {
            let cliError = CLIError(error)
            if json {
                struct Body: Encodable { var error: String; var status: Int?; var exitCode: Int32 }
                let data = try encoder().encode(Body(error: cliError.description, status: cliError.status, exitCode: cliError.exitCode))
                stderr(String(decoding: data, as: UTF8.self))
            } else {
                stderr("Error: \(cliError.description)")
            }
            throw ExitCode(cliError.exitCode)
        }
    }

    static func table(_ headers: [String], _ rows: [[String]]) {
        let widths = headers.indices.map { i in ([headers[i]] + rows.map { $0[i] }).map(\.count).max() ?? 0 }
        func line(_ cells: [String]) -> String {
            cells.enumerated().map { i, cell in i == cells.count - 1 ? cell : cell.padding(toLength: widths[i], withPad: " ", startingAt: 0) }
                .joined(separator: "  ")
        }
        stdout(line(headers))
        rows.forEach { stdout(line($0)) }
    }

    static func date(_ date: Date?) -> String {
        guard let date else { return "-" }
        return ISO8601DateFormatter().string(from: date)
    }
}
