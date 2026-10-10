import dnssd
import Foundation
import SupersEmuKit

/// Advertises `_supersemu._tcp` on the LAN for as long as the value is alive.
/// Uses dns_sd directly so it works in a launch daemon with no run loop.
public final class BonjourAdvertiser: @unchecked Sendable {
    private var ref: DNSServiceRef?

    public struct Failure: Error, CustomStringConvertible {
        public var code: DNSServiceErrorType
        public var description: String { "Bonjour registration failed (\(code))" }
    }

    public init(name: String, port: Int, txt: [String: String]) throws {
        let record = SupersEmuBonjour.encodeTXT(txt)
        let error = record.withUnsafeBytes { bytes in
            DNSServiceRegister(&ref, 0, 0, name, SupersEmuBonjour.serviceType, nil, nil,
                               UInt16(port).bigEndian, UInt16(record.count), bytes.baseAddress, nil, nil)
        }
        guard error == kDNSServiceErr_NoError else { throw Failure(code: error) }
    }

    public func stop() {
        if let ref { DNSServiceRefDeallocate(ref) }
        ref = nil
    }

    deinit { stop() }
}
