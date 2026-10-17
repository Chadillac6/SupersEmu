import Foundation

public enum RemoteAccessChecks {
    public enum OutsideCheck: Equatable, Sendable {
        case reachable
        case unverifiedFromInside
        case failed(String)
    }

    public static func dohAAnswers(from data: Data) -> [String] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let answers = object["Answer"] as? [[String: Any]] else { return [] }

        var addresses: [String] = []
        for answer in answers where (answer["type"] as? Int) == 1 {
            guard let address = answer["data"] as? String, isIPv4Address(address), !addresses.contains(address) else { continue }
            addresses.append(address)
        }
        return addresses
    }

    public static func classifyOutsideCheck(
        healthOK: Bool,
        dnsAddresses: [String],
        publicIP: String,
        certificatePresent: Bool
    ) -> OutsideCheck {
        if healthOK { return .reachable }
        guard let dnsAddress = dnsAddresses.first else {
            return .failed("No DNS A record was found for this host.")
        }
        guard dnsAddress == publicIP else {
            return .failed("DNS points at \(dnsAddress), this Mac's public IP is \(publicIP)")
        }
        guard certificatePresent else {
            return .failed("The HTTPS certificate isn't ready yet.")
        }
        return .unverifiedFromInside
    }

    public static func osascriptExitStatus(stderr: String) -> Int? {
        let pattern = #"\((-?[0-9]+)\)\s*$"#
        guard let range = stderr.range(of: pattern, options: .regularExpression) else { return nil }
        let match = String(stderr[range])
        guard let open = match.firstIndex(of: "("), let close = match.firstIndex(of: ")") else { return nil }
        return Int(match[match.index(after: open)..<close])
    }

    public static func isIPv4Address(_ address: String) -> Bool {
        let octets = address.split(separator: ".", omittingEmptySubsequences: false)
        return octets.count == 4 && octets.allSatisfy { octet in
            guard !octet.isEmpty, let value = UInt8(octet), String(value) == String(octet) else { return false }
            return true
        }
    }
}
