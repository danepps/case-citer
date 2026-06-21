import XCTest
@testable import CourtListener

/// `URLProtocol` stub that records each request's `Authorization` header and replies
/// with a canned, non-empty search payload (so `searchOpinions` does a single fetch
/// rather than the empty-result full-text fallback).
final class RecordingURLProtocol: URLProtocol {
    /// Authorization header value seen on each handled request (nil when absent).
    static var authHeaders: [String?] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.authHeaders.append(request.value(forHTTPHeaderField: "Authorization"))
        let body = Data(#"{"results":[{"caseName":"X","citation":["1 U.S. 1"]}]}"#.utf8)
        let response = HTTPURLResponse(url: request.url!, statusCode: 200,
                                       httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class SearchClientTests: XCTestCase {

    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RecordingURLProtocol.self]
        return URLSession(configuration: config)
    }

    override func setUp() {
        super.setUp()
        RecordingURLProtocol.authHeaders = []
    }

    /// The token is read per request, so flipping the provider's return value changes
    /// the next request's `Authorization` header without rebuilding the client — the
    /// regression behind recommendation #1 (a token edited in Settings took no effect
    /// until relaunch).
    func testTokenProviderIsReadPerRequest() async throws {
        var token: String? = nil
        let client = SearchClient(apiKeyProvider: { token }, session: makeSession(), cache: nil)

        _ = try await client.searchOpinions("first")   // anonymous
        token = "SECRET"
        _ = try await client.searchOpinions("second")  // token now active

        XCTAssertEqual(RecordingURLProtocol.authHeaders.count, 2)
        XCTAssertNil(RecordingURLProtocol.authHeaders[0])
        XCTAssertEqual(RecordingURLProtocol.authHeaders[1], "Token SECRET")
    }
}
