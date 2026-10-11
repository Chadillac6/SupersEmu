import Foundation
import Darwin
import Network

public enum ConnectionDiagnosis: Equatable, Sendable {
    case notFound
    case refused
    case resetDuringTLS
    case certificateMismatch
    case codeInvalidOrExpired
    case rateLimited
    case timeout
    case other(domain: String, code: Int)

    public var message: String {
        switch self {
        case .notFound:
            return "Server not found. Check the address or choose a server on your network."
        case .refused:
            return "The server refused the connection. Make sure SupersEmu Server is running."
        case .resetDuringTLS:
            return "The connection reset during TLS. The server's firewall may be blocking SupersEmu; check the server Mac's menu bar."
        case .certificateMismatch:
            return "The server's certificate changed or doesn't match its saved pin. Verify it with the server owner."
        case .codeInvalidOrExpired:
            return "The request was denied or expired. Start a new Request to Connect."
        case .rateLimited:
            return "Too many connection attempts. Wait a minute, then try again."
        case .timeout:
            return "The server took too long to respond. Check that both devices are on the network."
        case .other(let domain, let code):
            return "Couldn't connect (\(domain) \(code)). Check the server address and try again."
        }
    }

    public static func from(error: Error) -> ConnectionDiagnosis {
        if let clientError = error as? APIClientError {
            switch clientError {
            case .http(let status, _):
                return diagnosis(forHTTPStatus: status)
            case .invalidResponse:
                return .other(domain: "SupersEmuKit.APIClientError", code: 0)
            }
        }
        if let networkError = error as? NWError {
            switch networkError {
            case .dns:
                return .notFound
            case .posix(let code):
                return diagnosis(forPOSIXCode: Int(code.rawValue))
            case .tls:
                return .certificateMismatch
            @unknown default:
                break
            }
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .cannotFindHost, .dnsLookupFailed, .badURL, .unsupportedURL:
                return .notFound
            case .cannotConnectToHost:
                return .refused
            case .networkConnectionLost:
                return .resetDuringTLS
            case .secureConnectionFailed, .serverCertificateHasBadDate, .serverCertificateUntrusted,
                 .serverCertificateHasUnknownRoot, .clientCertificateRejected:
                return .certificateMismatch
            case .timedOut:
                return .timeout
            default:
                break
            }
        }
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain {
            return diagnosis(forPOSIXCode: nsError.code)
        }
        if nsError.domain == NSURLErrorDomain {
            switch URLError.Code(rawValue: nsError.code) {
            case .cannotFindHost, .dnsLookupFailed:
                return .notFound
            case .cannotConnectToHost:
                return .refused
            case .networkConnectionLost:
                return .resetDuringTLS
            case .secureConnectionFailed, .serverCertificateHasBadDate, .serverCertificateUntrusted,
                 .serverCertificateHasUnknownRoot, .clientCertificateRejected:
                return .certificateMismatch
            case .timedOut:
                return .timeout
            default:
                break
            }
        }
        return .other(domain: nsError.domain, code: nsError.code)
    }

    private static func diagnosis(forHTTPStatus status: Int) -> ConnectionDiagnosis {
        switch status {
        case 400, 401, 403, 410:
            return .codeInvalidOrExpired
        case 404:
            return .notFound
        case 429:
            return .rateLimited
        case 408, 504:
            return .timeout
        case 502, 503:
            return .refused
        default:
            return .other(domain: "HTTP", code: status)
        }
    }

    private static func diagnosis(forPOSIXCode code: Int) -> ConnectionDiagnosis {
        switch code {
        case Int(ECONNREFUSED):
            return .refused
        case Int(ECONNRESET), Int(EPIPE):
            return .resetDuringTLS
        case Int(ETIMEDOUT):
            return .timeout
        case Int(ENOENT), Int(EHOSTUNREACH), Int(ENETUNREACH):
            return .notFound
        default:
            return .other(domain: NSPOSIXErrorDomain, code: code)
        }
    }
}
