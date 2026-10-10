import ArgumentParser
import Foundation
import SupersEmuKit

/// `~/.config/supersemu/config.json`, written by `supersemu login` with mode 0600.
struct CLIConfigFile: Codable, Equatable {
    var server: String
    var token: String

    static func defaultURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let path = environment["SUPERSEMU_CONFIG"], !path.isEmpty { return URL(fileURLWithPath: path) }
        let base = environment["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config", isDirectory: true)
        return base.appendingPathComponent("supersemu/config.json")
    }

    static func load(from url: URL) throws -> CLIConfigFile? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            return try JSONDecoder().decode(CLIConfigFile.self, from: Data(contentsOf: url))
        } catch {
            throw CLIError.usage("Can't read config \(url.path): \(error.localizedDescription)")
        }
    }

    /// Writes atomically; the directory is 0700 and the file 0600 because it holds a token.
    func write(to url: URL) throws {
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let tmp = dir.appendingPathComponent(".config.json.\(UUID().uuidString)")
        guard fm.createFile(atPath: tmp.path, contents: try encoder.encode(self), attributes: [.posixPermissions: 0o600]) else {
            throw CLIError.usage("Can't write \(url.path)")
        }
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmp.path)
        if fm.fileExists(atPath: url.path) {
            _ = try fm.replaceItemAt(url, withItemAt: tmp)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } else {
            try fm.moveItem(at: tmp, to: url)
        }
    }
}

/// Server + token options shared by every command that talks to the API.
/// Precedence: flags, then SUPERSEMU_SERVER / SUPERSEMU_TOKEN, then the config file, then (on the
/// Mac mini only) the server's local `admin.token`.
struct Connection: ParsableArguments {
    static let defaultServer = "http://127.0.0.1:8487"
    static let localAdminTokenPath = "/Library/Application Support/SupersEmu Server/admin.token"

    @Option(help: "Server URL. Env: SUPERSEMU_SERVER. Default: config file, else \(Connection.defaultServer).")
    var server: String?
    @Option(help: "API or device token. Env: SUPERSEMU_TOKEN. Default: config file, else the local admin.token on the Mac mini.")
    var token: String?
    @Flag(help: "Print JSON (stdout) and JSON errors (stderr).")
    var json = false

    struct Resolved: Equatable {
        var server: URL
        var token: String?
    }

    func resolve(environment: [String: String] = ProcessInfo.processInfo.environment,
                 configURL: URL? = nil,
                 localAdminTokenPath: String = Connection.localAdminTokenPath) throws -> Resolved {
        let config = try CLIConfigFile.load(from: configURL ?? CLIConfigFile.defaultURL(environment: environment))
        let serverString = nonEmpty(server) ?? nonEmpty(environment["SUPERSEMU_SERVER"]) ?? config?.server ?? Self.defaultServer
        guard let url = URL(string: serverString), let scheme = url.scheme, ["http", "https"].contains(scheme), url.host != nil else {
            throw CLIError.usage("Invalid server URL: \(serverString)")
        }
        // Only reuse a saved or local token for the server it belongs to, so it is never sent elsewhere.
        var resolvedToken = nonEmpty(token) ?? nonEmpty(environment["SUPERSEMU_TOKEN"])
        if resolvedToken == nil, let config, Self.sameServer(config.server, serverString) {
            resolvedToken = nonEmpty(config.token)
        }
        if resolvedToken == nil, ["127.0.0.1", "localhost", "::1"].contains(url.host ?? "") {
            resolvedToken = nonEmpty((try? String(contentsOfFile: localAdminTokenPath, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return Resolved(server: url, token: resolvedToken)
    }

    func client() throws -> APIClient {
        let resolved = try resolve()
        return APIClient(baseURL: resolved.server, token: resolved.token)
    }

    static func sameServer(_ a: String, _ b: String) -> Bool {
        func normalized(_ s: String) -> String { s.hasSuffix("/") ? String(s.dropLast()) : s }
        return normalized(a).lowercased() == normalized(b).lowercased()
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}
