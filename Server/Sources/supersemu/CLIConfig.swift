import ArgumentParser
import Foundation
import SupersEmuKit

/// `~/.config/supersemu/config.json`, written by `supersemu login` with mode 0600.
struct CLIConfigFile: Codable, Equatable {
    var server: String
    var token: String
    /// Pin for a self-signed server, verified at login.
    var certificateSHA256: String? = nil

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
            throw CLIError.unexpected("Can't read config \(url.path): \(error.localizedDescription)")
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
            throw CLIError.unexpected("Can't write \(url.path)")
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
    static let defaultServer = "https://127.0.0.1:8487"
    static let localAdminTokenPath = "/Library/Application Support/SupersEmu Server/admin.token"
    static let localCertificatePath = "/Library/Application Support/SupersEmu Server/tls/server.cer"

    @Option(help: "Server URL. Env: SUPERSEMU_SERVER. Default: config file, else \(Connection.defaultServer).")
    var server: String?
    @Option(help: "API or device token. Env: SUPERSEMU_TOKEN. Default: config file, else the local admin.token on the Mac mini.")
    var token: String?
    @Option(help: "Server certificate SHA-256 to pin (self-signed). Env: SUPERSEMU_CERT_SHA256. Default: the local server's tls/server.cer on the Mac mini.")
    var certificateSHA256: String?
    @Flag(help: "Print JSON (stdout) and JSON errors (stderr).")
    var json = false

    struct Resolved: Equatable {
        var server: URL
        var token: String?
        var certificateSHA256: String? = nil
    }

    func resolve(environment: [String: String] = ProcessInfo.processInfo.environment,
                 configURL: URL? = nil,
                 localAdminTokenPath: String = Connection.localAdminTokenPath) throws -> Resolved {
        let explicitServer = nonEmpty(server) ?? nonEmpty(environment["SUPERSEMU_SERVER"])
        var resolvedToken = nonEmpty(token) ?? nonEmpty(environment["SUPERSEMU_TOKEN"])
        // The config file is only read when it can supply something, so a broken one never blocks explicit flags.
        let config = explicitServer != nil && resolvedToken != nil
            ? nil : try CLIConfigFile.load(from: configURL ?? CLIConfigFile.defaultURL(environment: environment))
        let serverString = explicitServer ?? config?.server ?? Self.defaultServer
        guard let url = URL(string: serverString), let scheme = url.scheme, ["http", "https"].contains(scheme), url.host != nil else {
            throw CLIError.usage("Invalid server URL: \(serverString)")
        }
        // Only reuse a saved or local token for the server it belongs to, so it is never sent elsewhere.
        if resolvedToken == nil, let config, Self.sameServer(config.server, serverString) {
            resolvedToken = nonEmpty(config.token)
        }
        if resolvedToken == nil, Self.isLocalDefaultServer(url) {
            resolvedToken = nonEmpty((try? String(contentsOfFile: localAdminTokenPath, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines))
        }
        // The local daemon's certificate is only a sensible default pin for the local daemon.
        // The saved pin still applies when server and token are both explicit; a broken config is ignored here.
        let pinConfig = config ?? (try? CLIConfigFile.load(from: configURL ?? CLIConfigFile.defaultURL(environment: environment))) ?? nil
        let savedPin = pinConfig.flatMap { Self.sameServer($0.server, serverString) ? nonEmpty($0.certificateSHA256) : nil }
        let pin = nonEmpty(certificateSHA256) ?? nonEmpty(environment["SUPERSEMU_CERT_SHA256"]) ?? savedPin
            ?? (Self.isLocalDefaultServer(url) ? FileManager.default.contents(atPath: Self.localCertificatePath).map(CertificatePin.sha256(ofDER:)) : nil)
        return Resolved(server: url, token: resolvedToken, certificateSHA256: pin)
    }

    func client() throws -> APIClient {
        let resolved = try resolve()
        return APIClient(baseURL: resolved.server, token: resolved.token, session: try Self.session(for: resolved))
    }

    /// Pins the server's self-signed certificate when a fingerprint is known, and refuses to send a
    /// token over plain HTTP anywhere but loopback (`--insecure-http` test servers).
    static func session(for resolved: Resolved) throws -> URLSession {
        if resolved.server.scheme == "http", resolved.token != nil, !isLoopback(resolved.server) {
            throw CLIError.usage("Refusing to send a token over plain HTTP to \(resolved.server.absoluteString); use https://")
        }
        // Always the pinning delegate: it also refuses redirects, so the bearer token can't be bounced to HTTP.
        return PinnedCertificateDelegate.session(certificateSHA256: resolved.certificateSHA256, timeout: 120)
    }

    static func isLoopback(_ url: URL) -> Bool {
        ["127.0.0.1", "localhost", "::1", "[::1]"].contains(url.host?.lowercased() ?? "")
    }

    /// Same scheme, host and port (case-insensitive) and the exact same path, ignoring a trailing slash.
    static func sameServer(_ a: String, _ b: String) -> Bool {
        guard let a = Origin(a), let b = Origin(b) else { return false }
        return a == b
    }

    /// The Mac mini's own server: a loopback host on the default port. Only then is `admin.token` used.
    static func isLocalDefaultServer(_ url: URL) -> Bool {
        guard let origin = Origin(url.absoluteString), let defaultOrigin = Origin(defaultServer) else { return false }
        return ["127.0.0.1", "localhost", "::1"].contains(origin.host) && ["http", "https"].contains(origin.scheme)
            && origin.port == defaultOrigin.port && origin.path.isEmpty
    }

    private struct Origin: Equatable {
        var scheme: String, host: String, port: Int, path: String

        init?(_ string: String) {
            guard let c = URLComponents(string: string), let scheme = c.scheme?.lowercased(), let host = c.host?.lowercased(),
                  c.query == nil, c.fragment == nil, c.user == nil else { return nil }
            self.scheme = scheme
            self.host = host.hasPrefix("[") ? String(host.dropFirst().dropLast()) : host
            self.port = c.port ?? (scheme == "https" ? 443 : 80)
            var path = c.path
            while path.hasSuffix("/") { path.removeLast() }
            self.path = path
        }
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}
