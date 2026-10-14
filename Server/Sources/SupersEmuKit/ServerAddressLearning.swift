import Darwin
import Foundation

public enum ServerAddressLearning {
    /// Addresses to keep for a paired server after its health listed `advertised`. nil means keep the current list.
    public static func merged(current: [URL], advertised: [URL]?, reachedAt: URL) -> [URL]? {
        guard let advertised else { return nil }

        var merged: [URL] = []
        for url in advertised where isAdvertisedAddress(url) {
            if !merged.contains(url) {
                merged.append(url)
            }
        }
        guard !merged.isEmpty else { return nil }
        if !merged.contains(reachedAt) {
            merged.append(reachedAt)
        }
        return merged == current ? nil : merged
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
