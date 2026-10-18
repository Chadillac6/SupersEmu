import Foundation
import SupersEmuKit
import XCTest

/// A reconnect used to `finishTasksAndInvalidate()` the session that save sync's `APIClient` was still using, and the
/// next upload crashed the app at launch with "Task created in a session that has been invalidated".
final class URLSessionLeaseTests: XCTestCase {
    func testClientKeepsWorkingAfterOwnerDropsLease() async throws {
        var lease: URLSessionLease? = URLSessionLease(Self.stubSession(delegate: nil))
        let client = APIClient(baseURL: URL(string: "https://server.test")!, token: "t", lease: lease!)
        lease = nil
        let first = try await client.raw("GET", "/v1/health")
        let second = try await client.raw("PUT", "/v1/saves", body: Data("x".utf8))
        XCTAssertEqual(String(decoding: first, as: UTF8.self), "ok")
        XCTAssertEqual(String(decoding: second, as: UTF8.self), "ok")
    }

    func testSessionInvalidatedOnceLastClientIsGone() async throws {
        let invalidated = expectation(description: "session invalidated")
        let delegate = InvalidationDelegate { invalidated.fulfill() }
        var lease: URLSessionLease? = URLSessionLease(Self.stubSession(delegate: delegate))
        var client: APIClient? = APIClient(baseURL: URL(string: "https://server.test")!, token: nil, lease: lease!)
        lease = nil
        _ = try await client?.raw("GET", "/v1/health")
        client = nil
        await fulfillment(of: [invalidated], timeout: 5)
    }

    private static func stubSession(delegate: URLSessionDelegate?) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OKProtocol.self]
        return URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }
}

private final class InvalidationDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    let onInvalid: () -> Void
    init(_ onInvalid: @escaping () -> Void) { self.onInvalid = onInvalid }
    func urlSession(_ session: URLSession, didBecomeInvalidWithError error: Error?) { onInvalid() }
}

private final class OKProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("ok".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
