import XCTest
@testable import GeckoKit

final class XMPPNegotiationTests: XCTestCase {
    private func features(_ children: StanzaNode...) -> StanzaNode {
        StanzaNode("features", XMPPNS.stream, [:], children)
    }

    private func mechanisms(_ names: String...) -> StanzaNode {
        StanzaNode("mechanisms", XMPPNS.sasl, [:], names.map { StanzaNode("mechanism", XMPPNS.sasl, text: $0) })
    }

    private func sent(_ actions: [XMPPNegotiation.Action]) -> StanzaNode? {
        for case .send(let node) in actions { return node }
        return nil
    }

    private func boundResult(_ jid: String) -> StanzaNode {
        StanzaNode("iq", XMPPNS.client, ["type": "result", "id": "bind"],
                   [StanzaNode("bind", XMPPNS.bind, [:], [StanzaNode("jid", XMPPNS.bind, text: jid)])])
    }

    /// STARTTLS, SCRAM-SHA-1 (RFC 5802's exchange), bind, stream management.
    func testStartTLSScramBindAndEnable() throws {
        var n = XMPPNegotiation(jid: "user@example.org", password: "pencil", resource: "gecko", encrypted: false)
        XCTAssertEqual(sent(n.received(features(StanzaNode("starttls", XMPPNS.tls), mechanisms("PLAIN")))),
                       StanzaNode("starttls", XMPPNS.tls))
        XCTAssertEqual(n.received(StanzaNode("proceed", XMPPNS.tls)), [.startTLS])
        XCTAssertEqual(n.tlsEstablished(), [.openStream])

        let auth = try XCTUnwrap(sent(n.received(features(mechanisms("PLAIN", "SCRAM-SHA-1")))))
        XCTAssertEqual(auth["mechanism"], "SCRAM-SHA-1", "SCRAM must win over PLAIN")
        let first = try XCTUnwrap(String(data: XCTUnwrap(Data(base64Encoded: auth.text)), encoding: .utf8))
        XCTAssertTrue(first.hasPrefix("n,,n=user,r="))
        let nonce = String(first.dropFirst("n,,n=user,r=".count))

        // A server-first for our nonce; the client answers with a proof.
        let serverFirst = "r=\(nonce)server,s=QSXCR+Q6sek8bf92,i=4096"
        let response = try XCTUnwrap(sent(n.received(StanzaNode(
            "challenge", XMPPNS.sasl, text: Data(serverFirst.utf8).base64EncodedString()))))
        XCTAssertEqual(response.name, "response")

        // A forged server signature must fail the login.
        let failure = n.received(StanzaNode("success", XMPPNS.sasl,
                                                 text: Data("v=AAAA".utf8).base64EncodedString()))
        guard case .failed(.authentication) = failure.first else {
            return XCTFail("accepted a wrong server signature: \(failure)")
        }
    }

    func testPlainOnlyOverTLSThenBindWithoutStreamManagement() {
        var n = XMPPNegotiation(jid: "a@example.org", password: "secret", resource: "r", encrypted: true)
        let auth = sent(n.received(features(mechanisms("PLAIN"))))
        XCTAssertEqual(auth?["mechanism"], "PLAIN")
        XCTAssertEqual(auth?.text, Data("\0a\0secret".utf8).base64EncodedString())
        XCTAssertEqual(n.received(StanzaNode("success", XMPPNS.sasl)), [.openStream])

        let bind = sent(n.received(features(StanzaNode("bind", XMPPNS.bind))))
        XCTAssertEqual(bind?.child("bind", XMPPNS.bind)?.child("resource", XMPPNS.bind)?.text, "r")
        XCTAssertEqual(n.received(boundResult("a@example.org/r")),
                       [.ready(jid: "a@example.org/r", sm: nil, resumedAt: nil)])
    }

    func testRefusesPlaintextWithoutStartTLSAndWrongPassword() {
        var plain = XMPPNegotiation(jid: "a@example.org", password: "x", resource: "r", encrypted: false)
        XCTAssertEqual(plain.received(features(mechanisms("PLAIN"))), [.failed(.tlsUnavailable)])

        var wrong = XMPPNegotiation(jid: "a@example.org", password: "x", resource: "r", encrypted: true)
        _ = wrong.received(features(mechanisms("PLAIN")))
        XCTAssertEqual(wrong.received(StanzaNode("failure", XMPPNS.sasl, [:], [StanzaNode("not-authorized", XMPPNS.sasl)])),
                       [.failed(.notAuthorized("not-authorized"))])
    }

    func testEnablesResumableStreamManagement() {
        var n = XMPPNegotiation(jid: "a@example.org", password: "x", resource: "r", encrypted: true)
        _ = n.received(features(mechanisms("PLAIN")))
        _ = n.received(StanzaNode("success", XMPPNS.sasl))
        _ = n.received(features(StanzaNode("bind", XMPPNS.bind), StanzaNode("sm", XMPPNS.sm),
                                StanzaNode("csi", XMPPNS.csi)))
        XCTAssertEqual(sent(n.received(boundResult("a@example.org/r"))), StanzaNode("enable", XMPPNS.sm, ["resume": "true"]))
        XCTAssertTrue(n.csiOffered)
        XCTAssertEqual(n.received(StanzaNode("enabled", XMPPNS.sm, ["id": "s1", "resume": "true", "max": "300"])),
                       [.ready(jid: "a@example.org/r",
                               sm: XMPPResumption(id: "s1", jid: "a@example.org/r", location: nil, max: 300),
                               resumedAt: nil)])
    }

    func testResumesOrFallsBackToANewSession() {
        let old = XMPPResumption(id: "s1", jid: "a@example.org/r", location: nil, max: 300)
        func authenticated() -> XMPPNegotiation {
            var n = XMPPNegotiation(jid: "a@example.org", password: "x", resource: "r", encrypted: true,
                                    resume: old, handled: 7)
            _ = n.received(features(mechanisms("PLAIN")))
            _ = n.received(StanzaNode("success", XMPPNS.sasl))
            return n
        }
        var resuming = authenticated()
        XCTAssertEqual(sent(resuming.received(features(StanzaNode("bind", XMPPNS.bind), StanzaNode("sm", XMPPNS.sm)))),
                       StanzaNode("resume", XMPPNS.sm, ["previd": "s1", "h": "7"]))
        XCTAssertEqual(resuming.received(StanzaNode("resumed", XMPPNS.sm, ["previd": "s1", "h": "3"])),
                       [.ready(jid: "a@example.org/r", sm: old, resumedAt: 3)])

        var expired = authenticated()
        _ = expired.received(features(StanzaNode("bind", XMPPNS.bind), StanzaNode("sm", XMPPNS.sm)))
        XCTAssertEqual(sent(expired.received(StanzaNode("failed", XMPPNS.sm)))?.name, "iq", "falls back to binding")
    }

    func testStreamErrorEndsNegotiation() {
        var n = XMPPNegotiation(jid: "a@example.org", password: "x", resource: "r", encrypted: true)
        let error = StanzaNode("error", XMPPNS.stream, [:], [StanzaNode("host-unknown", XMPPNS.streamErrors)])
        XCTAssertEqual(n.received(error), [.failed(.streamError("host-unknown"))])
    }
}

final class StreamManagementTests: XCTestCase {
    private func message(_ id: String) -> StanzaNode { StanzaNode("message", XMPPNS.client, ["id": id]) }

    func testCountsAndAnswersRequests() {
        var sm = StreamManagement()
        XCTAssertNil(sm.received(message("in1")))
        XCTAssertNil(sm.received(StanzaNode("presence", XMPPNS.client)))
        XCTAssertNil(sm.received(StanzaNode("a", XMPPNS.sm, ["h": "0"])), "acks are not counted")
        XCTAssertEqual(sm.received(StanzaNode("r", XMPPNS.sm)), StanzaNode("a", XMPPNS.sm, ["h": "2"]))
    }

    func testAcknowledgementDropsConfirmedStanzasAndResumeResendsTheRest() {
        var sm = StreamManagement()
        for id in ["1", "2", "3"] { sm.sent(message(id)) }
        sm.sent(StreamManagement.request)
        XCTAssertEqual(sm.unacked.count, 3, "an <r/> is not a stanza")
        _ = sm.received(StanzaNode("a", XMPPNS.sm, ["h": "1"]))
        XCTAssertEqual(sm.unacked.map { $0["id"] }, ["2", "3"])
        XCTAssertEqual(sm.resumed(at: 2).map { $0["id"] }, ["3"])
        XCTAssertTrue(sm.unacked.isEmpty)
    }

    func testCounterWrapsAt32Bits() {
        var sm = StreamManagement()
        sm.acknowledge(UInt32.max)
        sm.sent(message("a"))
        sm.sent(message("b"))
        sm.acknowledge(0)  // UInt32.max + 1 wraps to 0: one more stanza confirmed
        XCTAssertEqual(sm.unacked.map { $0["id"] }, ["b"])
    }
}
