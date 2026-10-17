import Darwin
import Foundation

public enum ServerAddressLearning {
    public static func withoutLegacyOverlayAddresses(_ urls: [URL]) -> [URL] {
        urls.filter { url in
            guard let host = url.host?.lowercased() else { return true }
            return !isLegacyOverlayAddress(host)
        }
    }

    /// Addresses to keep for a paired server after its health listed `advertised`. nil means keep the current list.
    public static func merged(current: [URL], advertised: [URL]?, reachedAt: URL) -> [URL]? {
        let cleanedCurrent = withoutLegacyOverlayAddresses(current)
        guard let advertised else { return cleanedCurrent == current ? nil : cleanedCurrent }

        var merged: [URL] = []
        for url in withoutLegacyOverlayAddresses(advertised) where isAdvertisedAddress(url) {
            if !merged.contains(url) {
                merged.append(url)
            }
        }
        guard !merged.isEmpty else { return cleanedCurrent == current ? nil : cleanedCurrent }
        if !isLegacyOverlayAddress(reachedAt.host?.lowercased() ?? ""), !merged.contains(reachedAt) {
            merged.append(reachedAt)
        }
        return merged == current ? nil : merged
    }

    private static func isLegacyOverlayAddress(_ host: String) -> Bool {
        if host.hasSuffix(".ts.net") { return true }
        let addressHost = String(host.split(separator: "%", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
        let octets = addressHost.split(separator: ".").compactMap { UInt8($0) }
        if octets.count == 4, octets[0] == 100, (64...127).contains(octets[1]) { return true }

        var ipv6 = in6_addr()
        guard addressHost.withCString({ inet_pton(AF_INET6, $0, &ipv6) }) == 1 else { return false }
        return withUnsafeBytes(of: ipv6) { Array($0.prefix(6)) == [0xfd, 0x7a, 0x11, 0x5c, 0xa1, 0xe0] }
    }

    private static func isAdvertisedAddress(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil else { return false }
        return !isLoopback(host)
    }

    private static func isLoopback(_ host: String) -> Bool {
        let host = host.lowercased()
        if host == "localhost" || host == "localhost." { return true }
        let addressHost = String(host.split(separator: "%", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")

        var ipv4 = in_addr()
        if addressHost.withCString({ inet_pton(AF_INET, $0, &ipv4) }) == 1 {
            return withUnsafeBytes(of: ipv4.s_addr) { $0.first == 127 }
        }

        var ipv6 = in6_addr()
        guard addressHost.withCString({ inet_pton(AF_INET6, $0, &ipv6) }) == 1 else { return false }
        return withUnsafeBytes(of: ipv6) { bytes in
            guard bytes.count == 16 else { return false }
            let isIPv4Mapped = bytes.prefix(10).allSatisfy { $0 == 0 } && bytes[10] == 0xff && bytes[11] == 0xff
            if isIPv4Mapped { return bytes[12] == 127 }
            return bytes.prefix(15).allSatisfy { $0 == 0 } && bytes[15] == 1
        }
    }
}
