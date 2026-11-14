import XCTest
@testable import GeckoKit

final class XMPPEndpointsTests: XCTestCase {
    private func srv(_ priority: UInt16, _ weight: UInt16, _ port: UInt16, _ target: String) -> SRVRecord {
        SRVRecord(priority: priority, weight: weight, port: port, target: target)
    }

    /// Always picks the first entry of a priority group (draw 0).
    private let first: (UInt32) -> UInt32 = { _ in 0 }

    func testParsesHandBuiltRdata() {
        // priority 10, weight 5, port 5223, "prosody.xmpp.is" in label format.
        var bytes: [UInt8] = [0, 10, 0, 5, 0x14, 0x67]
        for label in ["prosody", "xmpp", "is"] {
            bytes.append(UInt8(label.utf8.count))
            bytes += label.utf8
        }
        bytes.append(0)
        XCTAssertEqual(XMPPEndpoints.record(rdata: Data(bytes)), srv(10, 5, 5223, "prosody.xmpp.is"))
        XCTAssertEqual(XMPPEndpoints.record(rdata: Data([0, 0, 0, 0, 0, 0, 0])), srv(0, 0, 0, "."))
    }

    func testMalformedRdataIsNil() {
        let header: [UInt8] = [0, 10, 0, 5, 0x14, 0x66]
        XCTAssertNil(XMPPEndpoints.record(rdata: Data()))
        XCTAssertNil(XMPPEndpoints.record(rdata: Data(header)), "missing target")
        XCTAssertNil(XMPPEndpoints.record(rdata: Data(header + [4, 0x61, 0x62])), "label overruns rdata")
        XCTAssertNil(XMPPEndpoints.record(rdata: Data(header + [1, 0x61])), "no root label")
        XCTAssertNil(XMPPEndpoints.record(rdata: Data(header + [0xC0, 0x0C])), "compression pointer")
        XCTAssertNil(XMPPEndpoints.record(rdata: Data(header + [0, 0])), "trailing bytes")
    }

    func testRFC2782Ordering() {
        let records = [srv(10, 10, 1, "b"), srv(10, 0, 1, "a"), srv(10, 20, 1, "c"), srv(5, 0, 1, "d")]
        var draws: [UInt32] = [0, 15, 0, 10]
        var totals: [UInt32] = []
        let ordered = XMPPEndpoints.ordered(records) { n in
            totals.append(n)
            return draws.removeFirst()
        }
        // Priority 5 first; then in 10: zero-weight "a" leads the running sums (a=0, b=10, c=30),
        // so 15 picks c, 0 picks a, 10 picks b.
        XCTAssertEqual(ordered.map(\.target), ["d", "c", "a", "b"])
        XCTAssertEqual(totals, [0, 30, 10, 10])
    }

    func testMergesByPriorityDirectTLSFirstOnTies() {
        let result = XMPPEndpoints.candidates(
            domain: "example.org",
            xmpps: [srv(20, 0, 5223, "tls2"), srv(10, 0, 5223, "tls1")],
            xmpp: [srv(10, 0, 5222, "plain1"), srv(5, 0, 5222, "plain0")],
            random: first)
        XCTAssertEqual(result, [
            XMPPEndpoint(host: "plain0", port: 5222, directTLS: false),
            XMPPEndpoint(host: "tls1", port: 5223, directTLS: true),
            XMPPEndpoint(host: "plain1", port: 5222, directTLS: false),
            XMPPEndpoint(host: "tls2", port: 5223, directTLS: true),
        ])
    }

    func testDotTargetDropsOnlyThatList() {
        let result = XMPPEndpoints.candidates(
            domain: "example.org",
            xmpps: [srv(0, 0, 0, ".")],
            xmpp: [srv(10, 0, 5222, "xmpp.example.org")],
            random: first)
        XCTAssertEqual(result, [XMPPEndpoint(host: "xmpp.example.org", port: 5222, directTLS: false)])
    }

    func testFallsBackToDomainOnlyWhenNoRecordsArePublished() {
        let fallback = [XMPPEndpoint(host: "example.org", port: 5222, directTLS: false)]
        XCTAssertEqual(XMPPEndpoints.candidates(domain: "example.org", xmpps: [], xmpp: [], random: first), fallback)
        // "." means no service: the domain itself must not be tried.
        XCTAssertEqual(XMPPEndpoints.candidates(
            domain: "example.org", xmpps: [srv(0, 0, 0, ".")], xmpp: [], random: first), [])
    }

    func testStripsTrailingDots() {
        let result = XMPPEndpoints.candidates(
            domain: "example.org", xmpps: [srv(1, 0, 5223, "tls.example.org.")], xmpp: [], random: first)
        XCTAssertEqual(result, [XMPPEndpoint(host: "tls.example.org", port: 5223, directTLS: true)])
    }

    func testLiveResolveXmppIs() async throws {
        guard ProcessInfo.processInfo.environment["GECKO_NETWORK_TESTS"] == "1" else {
            throw XCTSkip("set GECKO_NETWORK_TESTS=1 to run live DNS tests")
        }
        let result = await XMPPEndpoints.resolve(domain: "xmpp.is")
        let tls = try XCTUnwrap(result.firstIndex { $0.directTLS && $0.port == 5223 })
        let plain = try XCTUnwrap(result.firstIndex { !$0.directTLS && $0.port == 5222 })
        XCTAssertLessThan(tls, plain)
        XCTAssertEqual(result[tls].host, "prosody.xmpp.is")
    }
}
