import XCTest
@testable import GeckoKit

/// Against xmpp.is with USERNAME2/PASSWORD2 from credentials.local.txt; only
/// with GECKO_NETWORK_TESTS=1.
final class XMPPClientLiveTests: XCTestCase {
    private func account() throws -> (jid: String, password: String) {
        guard ProcessInfo.processInfo.environment["GECKO_NETWORK_TESTS"] == "1" else {
            throw XCTSkip("set GECKO_NETWORK_TESTS=1 to run against xmpp.is")
        }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../../../credentials.local.txt").standardized
        let lines = try String(contentsOf: root, encoding: .utf8).split(separator: "\n")
        let values = Dictionary(lines.compactMap { line -> (String, String)? in
            let parts = line.split(separator: "=", maxSplits: 1)
            return parts.count == 2 ? (String(parts[0]), String(parts[1])) : nil
        }, uniquingKeysWith: { first, _ in first })
        return (try XCTUnwrap(values["USERNAME2"]), try XCTUnwrap(values["PASSWORD2"]))
    }

    private func next(_ events: inout AsyncStream<XMPPClient.Event>.Iterator, timeout: TimeInterval = 30,
                      where match: (XMPPClient.Event) -> Bool) async throws -> XMPPClient.Event {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            guard let event = await events.next() else { break }
            if match(event) { return event }
        }
        XCTFail("timed out waiting for an event")
        throw CancellationError()
    }

    private func connected(_ event: XMPPClient.Event) -> Bool {
        if case .connected = event { return true }
        return false
    }

    /// Direct TLS from SRV, a message to ourselves, then a dropped connection
    /// that resumes the same session.
    func testConnectsExchangesAndResumes() async throws {
        let (jid, password) = try account()
        let client = XMPPClient(jid: jid, password: password, resource: "gecko-test-\(Int.random(in: 0...9999))")
        var events = client.events.makeAsyncIterator()
        await client.start()
        defer { Task { await client.stop() } }

        let first = try await next(&events, where: connected)
        guard case .connected(let full, let resumed) = first else { return XCTFail("\(first)") }
        XCTAssertTrue(full.hasPrefix(jid + "/"))
        XCTAssertFalse(resumed)

        await client.send(StanzaNode("presence", XMPPNS.client))
        let body = "selftest-\(UUID().uuidString)"
        await client.send(StanzaNode("message", XMPPNS.client, ["to": full, "type": "chat", "id": body],
                                     [StanzaNode("body", XMPPNS.client, text: body)]))
        let echo = try await next(&events) {
            if case .stanza(let node) = $0 { return node.child("body", XMPPNS.client)?.text == body }
            return false
        }
        XCTAssertNotNil(echo)

        await client.dropConnection()
        let again = try await next(&events, timeout: 60, where: connected)
        XCTAssertEqual(again, .connected(jid: full, resumed: true), "the session was not resumed")
    }

    func testConnectsWithStartTLS() async throws {
        let (jid, password) = try account()
        let client = XMPPClient(jid: jid, password: password, resource: "gecko-test-starttls",
                                endpoints: [XMPPEndpoint(host: "prosody.xmpp.is", port: 5222, directTLS: false)])
        var events = client.events.makeAsyncIterator()
        await client.start()
        defer { Task { await client.stop() } }
        let event = try await next(&events) { self.connected($0) || { if case .failed = $0 { return true }; return false }($0) }
        guard case .connected = event else { return XCTFail("STARTTLS login failed: \(event)") }
    }
}
