import Foundation
import SystemConfiguration

/// The addresses a device can use to reach this Mac: Bonjour `.local` name and LAN IPs first, then Tailscale.
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

    /// Tailscale assigns addresses from the CGNAT range 100.64.0.0/10.
    public static func isTailscale(_ ipv4: String) -> Bool {
        let parts = ipv4.split(separator: ".").compactMap { Int($0) }
        return parts.count == 4 && parts[0] == 100 && (64...127).contains(parts[1])
    }

    public static func isLinkLocal(_ ipv4: String) -> Bool { ipv4.hasPrefix("169.254.") }

    /// Ordered URLs for the pairing payload: Bonjour name, LAN IPs, Tailscale MagicDNS name, Tailscale IPs.
    public static func advertisedURLs(scheme: String, port: Int, tailscaleHost: String? = nil,
                                      hostName: String? = bonjourHostName(), addresses: [InterfaceAddress] = ipv4Addresses()) -> [URL] {
        var hosts: [String] = []
        if let hostName, !hostName.isEmpty { hosts.append("\(hostName).local") }
        let usable = addresses.map(\.address).filter { !isLinkLocal($0) }
        hosts += usable.filter { !isTailscale($0) }
        if let tailscaleHost, !tailscaleHost.isEmpty { hosts.append(tailscaleHost) }
        hosts += usable.filter(isTailscale)
        var seen = Set<String>()
        return hosts.filter { seen.insert($0).inserted }.compactMap { URL(string: "\(scheme)://\($0):\(port)") }
    }
}
