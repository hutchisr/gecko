import XCTest
@testable import GeckoKit

final class CallSessionTests: XCTestCase {
    private let me = "me@example.org"
    private let meFull = "me@example.org/gecko.1"
    private let peer = "peer@example.net"
    private let peerFull = "peer@example.net/phone"

    private let local = CallLocalDescription(
        mid: "0", bundle: true,
        transport: CallTransport(ufrag: "lu", pwd: "lp", fingerprint: "AA:BB", hash: "sha-256", setup: "actpass"),
        payload: CallPayload(id: 111, name: "opus", clockrate: 48_000, channels: 2,
                             parameters: ["minptime": "10", "useinbandfec": "1"],
                             feedback: [CallFeedback(type: "transport-cc", subtype: "")]))

    private func candidate(_ port: Int) -> CallCandidate {
        CallCandidate(foundation: "1", component: 1, transport: "udp", priority: 2_130_706_431,
                      ip: "192.0.2.1", port: port, type: "host",
                      relatedAddress: nil, relatedPort: 0, generation: 0)
    }

    /// What another client's session-initiate or session-accept looks like on the wire.
    private func peerJingle(_ action: String, sid: String, setup: String, extraContent: String = "") -> StanzaNode {
        StanzaNode.parse("""
        <jingle xmlns='urn:xmpp:jingle:1' action='\(action)' sid='\(sid)'>\
        <content creator='initiator' name='audio' senders='both'>\
        <description xmlns='urn:xmpp:jingle:apps:rtp:1' media='audio'>\
        <payload-type id='9' name='G722' clockrate='8000'/>\
        <payload-type id='96' name='OPUS' clockrate='48000' channels='1'>\
        <parameter name='useinbandfec' value='1'/>\
        <rtcp-fb xmlns='urn:xmpp:jingle:apps:rtp:rtcp-fb:0' type='nack' subtype='pli'/>\
        </payload-type><rtcp-mux/></description>\
        <transport xmlns='urn:xmpp:jingle:transports:ice-udp:1' ufrag='ru' pwd='rp'>\
        <fingerprint xmlns='urn:xmpp:jingle:apps:dtls:0' hash='sha-256' setup='\(setup)'>cc:dd</fingerprint>\
        <candidate component='1' foundation='7' generation='0' id='x' ip='198.51.100.2' network='0' \
        port='4000' priority='100' protocol='udp' type='srflx' rel-addr='10.0.0.2' rel-port='4001'/>\
        <candidate component='1' foundation='8' generation='0' id='y' ip='198.51.100.2' network='0' \
        port='4002' priority='90' protocol='tcp' type='host'/>\
        </transport></content>\(extraContent)</jingle>
        """)!
    }

    private func sent(_ effects: [CallSession.Effect]) -> [StanzaNode] {
        effects.compactMap { if case .send(let node) = $0 { return node } else { return nil } }
    }

    func testStanzaNodeSurvivesSerialisation() {
        let node = StanzaNode("iq", CallNS.client, ["to": "a@b/\"c\"", "type": "set"], [
            StanzaNode("jingle", CallNS.jingle, ["sid": "s<1>"], [
                StanzaNode("reason", CallNS.jingle, [:], [StanzaNode("text", CallNS.jingle, text: "a & b")]),
            ]),
        ])
        XCTAssertEqual(StanzaNode.parse(node.xml), node)
        XCTAssertNil(StanzaNode.parse("<iq><unclosed></iq>"))
    }

    func testReadsAnotherClientsOfferAsOpusOnly() throws {
        let content = try XCTUnwrap(Jingle.content(of: peerJingle("session-initiate", sid: "s", setup: "actpass")))
        XCTAssertEqual(content.name, "audio")
        XCTAssertEqual(content.transport, CallTransport(
            ufrag: "ru", pwd: "rp", fingerprint: "CC:DD", hash: "sha-256", setup: "actpass"))
        XCTAssertEqual(content.payload, CallPayload(
            id: 96, name: "opus", clockrate: 48_000, channels: 2,
            parameters: ["useinbandfec": "1"], feedback: [CallFeedback(type: "nack", subtype: "pli")]))
        XCTAssertTrue(content.rtcpMux)
        // The TCP candidate is dropped.
        XCTAssertEqual(content.candidates.map(\.port), [4000])
        XCTAssertEqual(content.candidates.first?.relatedAddress, "10.0.0.2")
    }

    func testOfferWithoutFingerprintIsNotUsable() {
        var jingle = peerJingle("session-initiate", sid: "s", setup: "actpass")
        jingle.children[0].children[1].children.removeFirst()
        XCTAssertNil(Jingle.content(of: jingle))
    }

    func testOutgoingCallNegotiatesThroughToHangUp() throws {
        var (call, effects) = CallSession.outgoing(account: me, peer: peer, sid: "sid1")
        var propose = try XCTUnwrap(sent(effects).first)
        XCTAssertEqual(propose["to"], peer)
        XCTAssertNotNil(propose.child("propose", CallNS.jmi)?.child("description", CallNS.rtp))

        // A candidate gathered before the offer is ready must not be lost.
        XCTAssertEqual(call.jmi("proceed", from: peerFull, me: meFull), [.offerNeeded])
        XCTAssertEqual(call.state, .establishing)
        XCTAssertEqual(call.localCandidate(candidate(5000)), [])

        let initiate = try XCTUnwrap(sent(call.localDescription(local)).first)
        XCTAssertEqual(initiate["to"], peerFull)
        let jingle = try XCTUnwrap(initiate.child("jingle", CallNS.jingle))
        XCTAssertEqual(jingle["action"], "session-initiate")
        let ours = try XCTUnwrap(Jingle.content(of: jingle))
        XCTAssertEqual(ours.name, "0")
        XCTAssertEqual(ours.transport, local.transport)
        XCTAssertEqual(ours.payload, local.payload)
        XCTAssertEqual(ours.candidates, [candidate(5000)])

        let info = try XCTUnwrap(sent(call.localCandidate(candidate(5001))).first?.child("jingle", CallNS.jingle))
        XCTAssertEqual(info["action"], "transport-info")
        XCTAssertEqual(Jingle.candidates(of: info), [candidate(5001)])
        XCTAssertNil(info.children[0].children[0].child("fingerprint", CallNS.dtls))

        let answer = call.jingle(peerJingle("session-accept", sid: "sid1", setup: "active"), from: peerFull)
        guard case .remote(.answer, let content)? = answer.first else { return XCTFail("no answer: \(answer)") }
        XCTAssertEqual(content.transport.setup, "active")

        call.mediaConnected()
        XCTAssertEqual(call.state, .inProgress)

        effects = call.hangUp()
        propose = try XCTUnwrap(sent(effects).first)
        XCTAssertEqual(Jingle.terminationReason(of: try XCTUnwrap(propose.child("jingle", CallNS.jingle))), "success")
        XCTAssertTrue(effects.contains(.closeMedia))
        XCTAssertEqual(call.state, .ended)
        XCTAssertEqual(call.hangUp(), [])
    }

    func testUnansweredOutgoingCallIsRetractedAndDeclineEndsIt() throws {
        var (call, _) = CallSession.outgoing(account: me, peer: peer, sid: "sid1")
        let retract = try XCTUnwrap(sent(call.hangUp()).first)
        XCTAssertNotNil(retract.child("retract", CallNS.jmi))
        XCTAssertEqual(retract["to"], peer)

        var (declined, _) = CallSession.outgoing(account: me, peer: peer, sid: "sid2")
        XCTAssertEqual(declined.jmi("reject", from: peerFull, me: meFull), [])
        XCTAssertEqual(declined.state, .declined)
    }

    func testIncomingProposedCallIsAnsweredOnThisDevice() throws {
        var (call, effects) = CallSession.proposed(account: me, from: peerFull, sid: "sid1")
        XCTAssertNotNil(sent(effects).first?.child("ringing", CallNS.jmi))
        XCTAssertEqual(call.state, .ringing)

        let accept = sent(call.accept())
        XCTAssertEqual(accept.map { $0["to"] }, [me, peerFull])
        XCTAssertNotNil(accept[0].child("accept", CallNS.jmi))
        XCTAssertNotNil(accept[1].child("proceed", CallNS.jmi))
        // The server echoes our own accept back to us.
        XCTAssertEqual(call.jmi("accept", from: meFull, me: meFull), [])
        XCTAssertEqual(call.state, .establishing)

        let offer = call.jingle(peerJingle("session-initiate", sid: "sid1", setup: "actpass"), from: peerFull)
        guard case .remote(.offer, let content)? = offer.first else { return XCTFail("no offer: \(offer)") }
        XCTAssertEqual(content.payload.id, 96)

        let accepted = try XCTUnwrap(sent(call.localDescription(local)).first?.child("jingle", CallNS.jingle))
        XCTAssertEqual(accepted["action"], "session-accept")
        // The answer names the caller's content, not our SDP mid.
        XCTAssertEqual(Jingle.content(of: accepted)?.name, "audio")

        call.mediaConnected()
        let ended = call.jingle(Jingle.terminate(sid: "sid1", reason: "success"), from: peerFull)
        XCTAssertEqual(ended, [.closeMedia])
        XCTAssertEqual(call.state, .ended)
    }

    func testIncomingCallTakenElsewhereOrWithdrawn() {
        var (elsewhere, _) = CallSession.proposed(account: me, from: peerFull, sid: "a")
        XCTAssertEqual(elsewhere.jmi("accept", from: "me@example.org/tablet", me: meFull), [.closeMedia])
        XCTAssertEqual(elsewhere.state, .otherDevice)

        var (withdrawn, _) = CallSession.proposed(account: me, from: peerFull, sid: "b")
        _ = withdrawn.jmi("retract", from: peerFull, me: meFull)
        XCTAssertEqual(withdrawn.state, .missed)
        XCTAssertEqual(withdrawn.accept(), [])

        // Somebody else cannot cancel the call.
        var (spoofed, _) = CallSession.proposed(account: me, from: peerFull, sid: "c")
        _ = spoofed.jmi("retract", from: "mallory@example.com/x", me: meFull)
        XCTAssertEqual(spoofed.state, .ringing)
    }

    func testDirectCallRingsAndKeepsEarlyCandidatesForTheAnswer() {
        var (call, effects) = CallSession.initiated(
            account: me, from: peerFull, jingle: peerJingle("session-initiate", sid: "d", setup: "actpass"))
        XCTAssertEqual(effects, [])
        XCTAssertEqual(call.state, .ringing)

        let more = Jingle.jingle("transport-info", sid: "d", [
            Jingle.content(name: "audio", local.transport, candidate: candidate(6000)),
        ])
        XCTAssertEqual(call.jingle(more, from: peerFull), [])

        guard case .remote(.offer, let content)? = call.accept().first else { return XCTFail("no offer") }
        XCTAssertEqual(content.candidates.map(\.port), [4000, 6000])
    }

    func testDirectCallDeclinedOrWithVideoIsTerminated() throws {
        var (call, _) = CallSession.initiated(
            account: me, from: peerFull, jingle: peerJingle("session-initiate", sid: "d", setup: "actpass"))
        let decline = try XCTUnwrap(sent(call.reject()).first?.child("jingle", CallNS.jingle))
        XCTAssertEqual(Jingle.terminationReason(of: decline), "decline")
        XCTAssertEqual(call.state, .declined)

        let video = "<content xmlns='urn:xmpp:jingle:1' creator='initiator' name='video'/>"
        let (withVideo, effects) = CallSession.initiated(
            account: me, from: peerFull,
            jingle: peerJingle("session-initiate", sid: "v", setup: "actpass", extraContent: video))
        XCTAssertEqual(withVideo.state, .failed)
        let refusal = try XCTUnwrap(sent(effects).first?.child("jingle", CallNS.jingle))
        XCTAssertEqual(Jingle.terminationReason(of: refusal), "unsupported-applications")
    }

    func testErrorReplyToTheOfferFailsTheCallButOthersDoNot() throws {
        var (call, _) = CallSession.outgoing(account: me, peer: peer, sid: "sid1")
        _ = call.jmi("proceed", from: peerFull, me: meFull)
        let initiate = try XCTUnwrap(sent(call.localDescription(local)).first)
        let info = try XCTUnwrap(sent(call.localCandidate(candidate(5001))).first)

        XCTAssertEqual(call.requestFailed(id: try XCTUnwrap(info["id"])), [])
        XCTAssertEqual(call.state, .establishing)
        XCTAssertEqual(call.requestFailed(id: try XCTUnwrap(initiate["id"])), [.closeMedia])
        XCTAssertEqual(call.state, .failed)
    }

    func testMediaFailureTellsThePeer() throws {
        var (call, _) = CallSession.outgoing(account: me, peer: peer, sid: "sid1")
        _ = call.jmi("proceed", from: peerFull, me: meFull)
        // Before any Jingle session exists the proposal is withdrawn instead.
        let retract = try XCTUnwrap(sent(call.mediaFailed("microphone access denied")).first)
        XCTAssertNotNil(retract.child("retract", CallNS.jmi))
        XCTAssertEqual(retract["to"], peerFull)
        XCTAssertEqual(call.state, .failed)
        XCTAssertEqual(call.reason, "microphone access denied")
    }

    func testExternalServicesBecomeIceServers() throws {
        let services = try XCTUnwrap(StanzaNode.parse("""
        <services xmlns='urn:xmpp:extdisco:2'>\
        <service type='stun' host='stun.example.org' port='3478' transport='udp'/>\
        <service type='stun' host='stun.example.org' port='3478' transport='tcp'/>\
        <service type='turn' host='2001:db8::1' port='3478' transport='udp' username='u' password='p'/>\
        <service type='turns' host='turn.example.org' port='5349' transport='tcp' username='u' password='p'/>\
        <service type='ftp' host='x' port='21'/>\
        </services>
        """))
        XCTAssertEqual(Jingle.iceServers(from: services), [
            CallIceServer(urls: "stun:stun.example.org:3478", username: nil, credential: nil),
            CallIceServer(urls: "turn:[2001:db8::1]:3478?transport=udp", username: "u", credential: "p"),
            CallIceServer(urls: "turns:turn.example.org:5349?transport=tcp", username: "u", credential: "p"),
        ])
    }
}
