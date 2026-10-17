import Foundation
import SystemConfiguration
import Darwin

/// The private addresses a device can use to reach this Mac: Bonjour `.local` name and LAN IPs.
public enum LocalNetwork {
    public struct InterfaceAddress: Sendable, Equatable {
        public var interface: String
        public var address: String
    }

    /// e.g. `Chads-Mac-mini` (no `.local`).
    public static func bonjourHostName() -> String? {
        SCDynamicStoreCopyLocalHostName(nil) as String?
    }

    public static func ipv4Addresses() -> [InterfaceAddress] {
        var result: [InterfaceAddress] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
        defer { freeifaddrs(ifaddr) }
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            let flags = Int32(entry.ifa_flags)
            guard let addr = entry.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            result.append(InterfaceAddress(interface: String(cString: entry.ifa_name), address: String(cString: host)))
        }
        return result
    }

    public static func isOverlayVPNAddress(_ address: String) -> Bool {
        let address = String(address.split(separator: "%", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
        let parts = address.split(separator: ".").compactMap { UInt8($0) }
        if parts.count == 4, parts[0] == 100, (64...127).contains(parts[1]) { return true }
        var ipv6 = in6_addr()
        guard address.withCString({ inet_pton(AF_INET6, $0, &ipv6) }) == 1 else { return false }
        return withUnsafeBytes(of: ipv6) { Array($0.prefix(6)) == [0xfd, 0x7a, 0x11, 0x5c, 0xa1, 0xe0] }
    }

    public static func isLinkLocal(_ ipv4: String) -> Bool { ipv4.hasPrefix("169.254.") }

    /// Ordered URLs for the pairing payload: Bonjour name, then LAN IPs.
    public static func advertisedURLs(scheme: String, port: Int,
                                      hostName: String? = bonjourHostName(), addresses: [InterfaceAddress] = ipv4Addresses()) -> [URL] {
        var hosts: [String] = []
        if let hostName, !hostName.isEmpty { hosts.append("\(hostName).local") }
        let usable = addresses.map(\.address).filter { !isLinkLocal($0) }
        hosts += usable.filter { !isOverlayVPNAddress($0) }
        var seen = Set<String>()
        return hosts.filter { seen.insert($0).inserted }.compactMap { URL(string: "\(scheme)://\($0):\(port)") }
    }
}
