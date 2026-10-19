import CryptoKit
import Foundation
import NIOSSL
import SupersEmuKit
import SwiftASN1
import X509

/// The server's self-signed certificate and key, created on first run in `<data dir>/tls/`.
/// Apps pin the certificate's SHA-256 (from the pairing QR), so the certificate never needs a CA.
public struct TLSIdentity: Sendable {
    public var certificateDER: Data
    public var privateKeyPEM: String

    public var sha256: String { CertificatePin.sha256(ofDER: certificateDER) }

    public static func directory(_ paths: ServerPaths) -> URL { paths.root.appendingPathComponent("tls", isDirectory: true) }
    public static func certificateURL(_ paths: ServerPaths) -> URL { directory(paths).appendingPathComponent("server.cer") }
    public static func keyURL(_ paths: ServerPaths) -> URL { directory(paths).appendingPathComponent("server.key.pem") }

    /// Loads the identity, or generates one the first time.
    public static func loadOrCreate(paths: ServerPaths, commonName: String) throws -> TLSIdentity {
        if let existing = try load(paths: paths) { return existing }
        let identity = try generate(commonName: commonName, dnsNames: ["localhost", "\(LocalNetwork.bonjourHostName() ?? "supersemu").local"])
        try FileManager.default.createDirectory(at: directory(paths), withIntermediateDirectories: true)
        // The key goes first: `load` treats the certificate as the marker that the identity is complete.
        try write(identity.privateKeyPEM.utf8, to: keyURL(paths), permissions: 0o600)
        try write(identity.certificateDER, to: certificateURL(paths), permissions: 0o644)
        return identity
    }

    /// A silent failure here would hand out a new pin on every launch and break every paired device.
    private static func write(_ bytes: some Sequence<UInt8>, to url: URL, permissions: Int) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: Data(bytes), attributes: [.posixPermissions: permissions]) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
    }

    public static func load(paths: ServerPaths) throws -> TLSIdentity? {
        guard let der = FileManager.default.contents(atPath: certificateURL(paths).path),
              let key = FileManager.default.contents(atPath: keyURL(paths).path) else { return nil }
        return TLSIdentity(certificateDER: der, privateKeyPEM: String(decoding: key, as: UTF8.self))
    }

    /// SHA-256 of the stored certificate, if one exists. Used by Server mode and the pairing payload.
    public static func storedFingerprint(paths: ServerPaths) -> String? {
        FileManager.default.contents(atPath: certificateURL(paths).path).map(CertificatePin.sha256(ofDER:))
    }

    public static func generate(commonName: String, dnsNames: [String], validFor years: Int = 10, now: Date = Date()) throws -> TLSIdentity {
        let key = P256.Signing.PrivateKey()
        let certificateKey = Certificate.PrivateKey(key)
        let name = try DistinguishedName {
            CommonName(commonName)
            OrganizationName("SupersEmu Server")
        }
        let certificate = try Certificate(
            version: .v3,
            serialNumber: Certificate.SerialNumber(),
            publicKey: certificateKey.publicKey,
            notValidBefore: now.addingTimeInterval(-3600),
            notValidAfter: Calendar(identifier: .gregorian).date(byAdding: .year, value: years, to: now) ?? now.addingTimeInterval(315_360_000),
            issuer: name,
            subject: name,
            signatureAlgorithm: .ecdsaWithSHA256,
            extensions: try Certificate.Extensions {
                Critical(BasicConstraints.notCertificateAuthority)
                Critical(KeyUsage(digitalSignature: true, keyEncipherment: true))
                try ExtendedKeyUsage([.serverAuth])
                SubjectAlternativeNames(dnsNames.map { GeneralName.dnsName($0) } + [.ipAddress(ASN1OctetString(contentBytes: [127, 0, 0, 1]))])
            },
            issuerPrivateKey: certificateKey)
        var serializer = DER.Serializer()
        try serializer.serialize(certificate)
        return TLSIdentity(certificateDER: Data(serializer.serializedBytes), privateKeyPEM: key.pemRepresentation)
    }

    public func serverConfiguration() throws -> TLSConfiguration {
        let certificate = try NIOSSLCertificate(bytes: Array(certificateDER), format: .der)
        let key = try NIOSSLPrivateKey(bytes: Array(privateKeyPEM.utf8), format: .pem)
        var configuration = TLSConfiguration.makeServerConfiguration(certificateChain: [.certificate(certificate)], privateKey: .privateKey(key))
        configuration.minimumTLSVersion = .tlsv12
        return configuration
    }
}
