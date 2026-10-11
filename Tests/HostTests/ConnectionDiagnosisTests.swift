import Darwin
import Network
import XCTest
import SupersEmuKit

final class ConnectionDiagnosisTests: XCTestCase {
    func testURLAndHTTPFailuresMapToSpecificDiagnoses() {
        XCTAssertEqual(ConnectionDiagnosis.from(error: URLError(.cannotFindHost)), .notFound)
        XCTAssertEqual(ConnectionDiagnosis.from(error: URLError(.cannotConnectToHost)), .refused)
        XCTAssertEqual(ConnectionDiagnosis.from(error: URLError(.networkConnectionLost)), .resetDuringTLS)
        XCTAssertEqual(ConnectionDiagnosis.from(error: URLError(.secureConnectionFailed)), .certificateMismatch)
        XCTAssertEqual(ConnectionDiagnosis.from(error: URLError(.timedOut)), .timeout)
        XCTAssertEqual(ConnectionDiagnosis.from(error: APIClientError.http(status: 403, message: nil)), .codeInvalidOrExpired)
        XCTAssertEqual(ConnectionDiagnosis.from(error: APIClientError.http(status: 429, message: nil)), .rateLimited)
    }

    func testConnectionResetDuringTLSMapsToFirewallDiagnosis() {
        let error = NSError(domain: NSPOSIXErrorDomain, code: Int(ECONNRESET))
        let diagnosis = ConnectionDiagnosis.from(error: error)

        XCTAssertEqual(diagnosis, .resetDuringTLS)
        XCTAssertTrue(diagnosis.message.contains("firewall"))
        XCTAssertTrue(diagnosis.message.contains("menu bar"))
        XCTAssertEqual(ConnectionDiagnosis.from(error: NWError.posix(.ECONNRESET)), .resetDuringTLS)
    }
}
