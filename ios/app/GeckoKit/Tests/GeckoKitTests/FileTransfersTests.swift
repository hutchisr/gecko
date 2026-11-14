import XCTest
@testable import GeckoKit

/// Serves whatever the current test's handler says, then finishes, drops, or
/// hangs until cancelled.
private final class StubHTTP: URLProtocol {
    enum End { case finish, drop, hang }
    nonisolated(unsafe) static var handler: ((URLRequest) -> (status: Int, headers: [String: String], body: Data,
                                                               end: End))?
    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        // A type, as real servers send: without one URLSession holds the
        // response back to sniff the first 512 bytes.
        guard let answer = Self.handler?(request), let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: answer.status, httpVersion: "HTTP/1.1",
                                             headerFields: answer.headers.merging(
                                                 ["Content-Type": "application/octet-stream"]) { $1 }) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: answer.body)
        switch answer.end {
        case .finish: client?.urlProtocolDidFinishLoading(self)
        case .hang: break
        case .drop:
            // Later, as a real network drop would be.
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) {
                self.client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
            }
        }
    }
}

final class FileTransfersTests: XCTestCase {
    private let file = Data((0..<1000).map { UInt8($0 % 251) })
    private let url = URL(string: "https://up.example.org/f.bin")!
    private var partial: URL!
    private var transfers: FileTransfers!

    override func setUp() {
        partial = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubHTTP.self]
        transfers = FileTransfers(configuration: configuration)
    }

    override func tearDown() {
        StubHTTP.handler = nil
        try? FileManager.default.removeItem(at: partial)
    }

    private func download() async -> Bool {
        await transfers.download(url, to: partial, key: 1) { _, _ in }
    }

    func testADroppedDownloadResumesFromWhereItStopped() async throws {
        StubHTTP.handler = { [file] request in
            XCTAssertNil(request.value(forHTTPHeaderField: "Range"))
            return (200, ["Content-Length": "1000"], file.prefix(400), .drop)
        }
        let first = await download()
        XCTAssertFalse(first)
        XCTAssertEqual(try Data(contentsOf: partial), file.prefix(400), "what arrived is kept")

        StubHTTP.handler = { [file] request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Range"), "bytes=400-")
            return (206, ["Content-Range": "bytes 400-999/1000"], file.suffix(600), .finish)
        }
        let second = await download()
        XCTAssertTrue(second)
        XCTAssertEqual(try Data(contentsOf: partial), file)
    }

    func testAServerIgnoringTheRangeStartsTheFileOver() async throws {
        try Data(repeating: 0xEE, count: 300).write(to: partial)
        StubHTTP.handler = { [file] _ in (200, ["Content-Length": "1000"], file, .finish) }
        let done = await download()
        XCTAssertTrue(done)
        XCTAssertEqual(try Data(contentsOf: partial), file, "not appended to the stale bytes")
    }

    func testACancelledDownloadStopsAndKeepsWhatArrived() async throws {
        StubHTTP.handler = { [file] _ in (200, ["Content-Length": "1000"], file.prefix(600), .hang) }
        Task {
            try await Task.sleep(nanoseconds: 300_000_000)
            transfers.cancel(1)
        }
        let done = await download()
        XCTAssertFalse(done)
        XCTAssertEqual(try Data(contentsOf: partial), file.prefix(600))
    }
}
