import XCTest
@testable import GeckoKit

final class CallSDPTests: XCTestCase {
    private let fingerprint =
        "4A:AD:B9:B1:3F:82:18:3B:54:02:12:DF:3E:5D:49:6B:19:E5:7C:AB:7B:8F:2C:1D:9E:60:A4:C3:5F:71:D8:02"

    private func sdp(_ lines: [String], ending: String = "\r\n") -> String {
        lines.joined(separator: ending) + ending
    }

    private func lines(_ sdp: String) -> [String] {
        sdp.split(whereSeparator: \.isNewline).map(String.init)
    }

    private func remote(
        hash: String = "sha-256",
        channels: Int = 2,
        parameters: [String: String] = ["minptime": "10", "useinbandfec": "1"],
        feedback: [CallFeedback] = [
            CallFeedback(type: "transport-cc", subtype: ""),
            CallFeedback(type: "nack", subtype: "pli"),
        ],
        rtcpMux: Bool = true,
        candidates: [CallCandidate] = []
    ) -> CallRemoteDescription {
        CallRemoteDescription(
            kind: .answer,
            mid: "audio",
            transport: CallTransport(
                ufrag: "p8Qz",
                pwd: "0sVnC2eXk1JtR7uLw9aBd3Fh",
                fingerprint: fingerprint,
                hash: hash,
                setup: "active"
            ),
            payload: CallPayload(
                id: 111,
                name: "opus",
                clockrate: 48000,
                channels: channels,
                parameters: parameters,
                feedback: feedback
            ),
            rtcpMux: rtcpMux,
            candidates: candidates,
            iceServers: []
        )
    }

    func testParsesMultiCodecOfferWithSessionLevelFingerprint() {
        let offer = sdp([
            "v=0",
            "o=- 4215775240449105457 2 IN IP4 127.0.0.1",
            "s=-",
            "t=0 0",
            "a=group:BUNDLE 0",
            "a=extmap-allow-mixed",
            "a=msid-semantic: WMS",
            "a=fingerprint:SHA-256 \(fingerprint.lowercased())",
            "m=audio 9 UDP/TLS/RTP/SAVPF 111 63 9 0 8 13 110 126",
            "c=IN IP4 0.0.0.0",
            "a=rtcp:9 IN IP4 0.0.0.0",
            "a=ice-ufrag:Yx3K",
            "a=ice-pwd:hQ0b3dG7m2bJxJ0sQy1c2n4E",
            "a=ice-options:trickle",
            "a=setup:actpass",
            "a=mid:0",
            "a=extmap:1 urn:ietf:params:rtp-hdrext:ssrc-audio-level",
            "a=extmap:2 http://www.webrtc.org/experiments/rtp-hdrext/abs-send-time",
            "a=sendrecv",
            "a=msid:- 6a1f0c1e-7d7b-4f0e-9f47-0f3a2f1f6f0d",
            "a=rtcp-mux",
            "a=rtcp-rsize",
            "a=rtpmap:111 opus/48000/2",
            "a=rtcp-fb:111 transport-cc",
            "a=fmtp:111 minptime=10;useinbandfec=1",
            "a=rtpmap:63 red/48000/2",
            "a=fmtp:63 111/111",
            "a=rtpmap:9 G722/8000",
            "a=rtpmap:0 PCMU/8000",
            "a=rtpmap:8 PCMA/8000",
            "a=rtpmap:13 CN/8000",
            "a=rtpmap:110 telephone-event/48000",
            "a=rtpmap:126 telephone-event/8000",
            "a=ssrc:3570614608 cname:4TOk42mSjXCkVIa6",
        ])

        XCTAssertEqual(CallSDP.localDescription(sdp: offer), CallLocalDescription(
            mid: "0",
            bundle: true,
            transport: CallTransport(
                ufrag: "Yx3K",
                pwd: "hQ0b3dG7m2bJxJ0sQy1c2n4E",
                fingerprint: fingerprint,
                hash: "sha-256",
                setup: "actpass"
            ),
            payload: CallPayload(
                id: 111,
                name: "opus",
                clockrate: 48000,
                channels: 2,
                parameters: ["minptime": "10", "useinbandfec": "1"],
                feedback: [CallFeedback(type: "transport-cc", subtype: "")]
            )
        ))
    }

    func testParsesAnswerWithMediaLevelFingerprintAndIgnoresOtherSections() {
        let other = fingerprint.replacingOccurrences(of: "4A", with: "00")
        let answer = sdp([
            "v=0",
            "o=- 831926435099276128 2 IN IP4 127.0.0.1",
            "s=-",
            "t=0 0",
            "a=msid-semantic: WMS",
            "m=audio 9 UDP/TLS/RTP/SAVPF 0 96",
            "c=IN IP4 0.0.0.0",
            "a=ice-ufrag:p8Qz",
            "a=ice-pwd:0sVnC2eXk1JtR7uLw9aBd3Fh",
            "a=fingerprint:sha-256 \(fingerprint)",
            "a=setup:active",
            "a=mid:audio",
            "a=recvonly",
            "a=rtcp-mux",
            "a=rtpmap:0 PCMU/8000",
            "a=rtpmap:96 OPUS/48000/2",
            "a=fmtp:96 minptime=10; useinbandfec=1 ;stereo=0",
            "a=rtcp-fb:96 transport-cc",
            "a=rtcp-fb:96 nack pli",
            "a=rtcp-fb:0 goog-remb",
            "m=video 9 UDP/TLS/RTP/SAVPF 97",
            "c=IN IP4 0.0.0.0",
            "a=ice-ufrag:vvvv",
            "a=ice-pwd:videovideovideovideovideo",
            "a=fingerprint:sha-256 \(other)",
            "a=setup:passive",
            "a=mid:video",
            "a=rtpmap:97 VP8/90000",
            "a=fmtp:97 max-fs=12288",
            "a=rtcp-fb:97 nack",
            "m=application 9 UDP/DTLS/SCTP webrtc-datachannel",
            "a=mid:data",
        ], ending: "\n")

        XCTAssertEqual(CallSDP.localDescription(sdp: answer), CallLocalDescription(
            mid: "audio",
            bundle: false,
            transport: CallTransport(
                ufrag: "p8Qz",
                pwd: "0sVnC2eXk1JtR7uLw9aBd3Fh",
                fingerprint: fingerprint,
                hash: "sha-256",
                setup: "active"
            ),
            payload: CallPayload(
                id: 96,
                name: "OPUS",
                clockrate: 48000,
                channels: 2,
                parameters: ["minptime": "10", "useinbandfec": "1", "stereo": "0"],
                feedback: [
                    CallFeedback(type: "transport-cc", subtype: ""),
                    CallFeedback(type: "nack", subtype: "pli"),
                ]
            )
        ))
    }

    func testNoOpusAudioSectionIsNil() {
        let transport = [
            "a=ice-ufrag:p8Qz",
            "a=ice-pwd:0sVnC2eXk1JtR7uLw9aBd3Fh",
            "a=fingerprint:sha-256 \(fingerprint)",
            "a=setup:active",
        ]
        let pcmu = ["v=0", "s=-", "t=0 0", "m=audio 9 UDP/TLS/RTP/SAVPF 0"] + transport
            + ["a=mid:0", "a=rtpmap:0 PCMU/8000", "a=rtpmap:107 opus/16000"]
        let video = ["v=0", "s=-", "t=0 0", "m=video 9 UDP/TLS/RTP/SAVPF 111"] + transport
            + ["a=mid:0", "a=rtpmap:111 opus/48000/2"]

        XCTAssertNil(CallSDP.localDescription(sdp: sdp(pcmu)))
        XCTAssertNil(CallSDP.localDescription(sdp: sdp(video)))
        XCTAssertNil(CallSDP.localDescription(sdp: ""))
    }

    func testRemoteAnswerRoundTripsThroughLocalDescription() {
        let host = CallCandidate(
            foundation: "1", component: 1, transport: "udp", priority: 2130706431,
            ip: "192.0.2.1", port: 5000, type: "host",
            relatedAddress: nil, relatedPort: 0, generation: 0
        )
        let r = remote(candidates: [host])
        let out = CallSDP.remoteSDP(r, mid: "0", bundle: true)

        XCTAssertEqual(CallSDP.localDescription(sdp: out), CallLocalDescription(
            mid: "0",
            bundle: true,
            transport: r.transport,
            payload: r.payload
        ))
        XCTAssertTrue(out.hasSuffix("\r\n"))
        XCTAssertEqual(out.components(separatedBy: "\r\n").count, lines(out).count + 1)
        let l = lines(out)
        XCTAssertFalse(l.contains { $0.hasPrefix("a=extmap") || $0.hasPrefix("a=ssrc") || $0.hasPrefix("a=msid:") })
        XCTAssertTrue(l.contains("a=rtcp-mux"))
        XCTAssertEqual(
            l.filter { $0.hasPrefix("a=candidate:") },
            ["a=candidate:1 1 udp 2130706431 192.0.2.1 5000 typ host generation 0"]
        )
    }

    func testRemoteSDPLayout() {
        let r = remote(hash: "", channels: 1, parameters: [:], feedback: [], rtcpMux: false)

        XCTAssertEqual(lines(CallSDP.remoteSDP(r, mid: "audio", bundle: false)).dropFirst(2), [
            "s=-",
            "t=0 0",
            "a=msid-semantic: WMS",
            "m=audio 9 UDP/TLS/RTP/SAVPF 111",
            "c=IN IP4 0.0.0.0",
            "a=rtcp:9 IN IP4 0.0.0.0",
            "a=ice-ufrag:p8Qz",
            "a=ice-pwd:0sVnC2eXk1JtR7uLw9aBd3Fh",
            "a=ice-options:trickle",
            "a=fingerprint:sha-256 \(fingerprint)",
            "a=setup:active",
            "a=mid:audio",
            "a=sendrecv",
            "a=rtpmap:111 opus/48000",
        ])

        let bundled = lines(CallSDP.remoteSDP(remote(), mid: "7", bundle: true))
        XCTAssertEqual(bundled[0], "v=0")
        XCTAssertTrue(bundled[1].hasPrefix("o=- "))
        XCTAssertTrue(bundled[1].hasSuffix(" 2 IN IP4 127.0.0.1"))
        XCTAssertEqual(Array(bundled[4...6]), [
            "a=group:BUNDLE 7",
            "a=msid-semantic: WMS",
            "m=audio 9 UDP/TLS/RTP/SAVPF 111",
        ])
        XCTAssertEqual(Array(bundled.suffix(5)), [
            "a=rtcp-mux",
            "a=rtpmap:111 opus/48000/2",
            "a=fmtp:111 minptime=10;useinbandfec=1",
            "a=rtcp-fb:111 transport-cc",
            "a=rtcp-fb:111 nack pli",
        ])
    }

    func testHostCandidateRoundTrip() {
        let line = "candidate:3288789175 1 udp 2122260223 192.168.1.23 54321 typ host generation 0"
        let c = CallSDP.candidate(sdpAttribute: line)

        XCTAssertEqual(c, CallCandidate(
            foundation: "3288789175", component: 1, transport: "udp", priority: 2122260223,
            ip: "192.168.1.23", port: 54321, type: "host",
            relatedAddress: nil, relatedPort: 0, generation: 0
        ))
        XCTAssertEqual(c.map(CallSDP.sdpAttribute), line)
    }

    func testServerReflexiveCandidateRoundTripAndExtensions() {
        let line = "candidate:842163049 1 udp 4294967295 203.0.113.7 61234 typ srflx"
            + " raddr 192.168.1.23 rport 54321 generation 2"
        let c = CallSDP.candidate(sdpAttribute: line)

        XCTAssertEqual(c, CallCandidate(
            foundation: "842163049", component: 1, transport: "udp", priority: 4294967295,
            ip: "203.0.113.7", port: 61234, type: "srflx",
            relatedAddress: "192.168.1.23", relatedPort: 54321, generation: 2
        ))
        XCTAssertEqual(c.map(CallSDP.sdpAttribute), line)
        XCTAssertEqual(
            CallSDP.candidate(sdpAttribute: "a=\(line) ufrag Yx3K network-id 1 network-cost 10\r\n"),
            c
        )
    }

    func testIPv6CandidateDefaultsGenerationAndLowercasesTransport() {
        let c = CallSDP.candidate(
            sdpAttribute: "candidate:7 1 UDP 2122197247 2001:db8::1c2f:3aff:fe4b:5d6e 50000 typ host network-id 2"
        )

        XCTAssertEqual(c, CallCandidate(
            foundation: "7", component: 1, transport: "udp", priority: 2122197247,
            ip: "2001:db8::1c2f:3aff:fe4b:5d6e", port: 50000, type: "host",
            relatedAddress: nil, relatedPort: 0, generation: 0
        ))
        XCTAssertEqual(
            c.map(CallSDP.sdpAttribute),
            "candidate:7 1 udp 2122197247 2001:db8::1c2f:3aff:fe4b:5d6e 50000 typ host generation 0"
        )
    }

    func testNonUDPAndMalformedCandidatesAreRejected() {
        XCTAssertNil(CallSDP.candidate(
            sdpAttribute: "candidate:1052940351 1 tcp 1518280447 192.168.1.23 9 typ host tcptype active generation 0"
        ))
        XCTAssertNil(CallSDP.candidate(
            sdpAttribute: "a=candidate:1052940351 1 TCP 1518280447 192.168.1.23 9 typ host tcptype active"
        ))
        XCTAssertNil(CallSDP.candidate(sdpAttribute: "candidate:1 1 udp 2122260223 192.168.1.23 54321"))
        XCTAssertNil(CallSDP.candidate(sdpAttribute: "candidate:1 1 udp high 192.168.1.23 54321 typ host"))
        XCTAssertNil(CallSDP.candidate(sdpAttribute: "a=end-of-candidates"))
    }

    func testFmtpSortsKeysAndFeedbackListJoinsSubtypes() {
        XCTAssertEqual(CallSDP.fmtp(["useinbandfec": "1", "minptime": "10", "stereo": "0"]),
                       "minptime=10;stereo=0;useinbandfec=1")
        XCTAssertEqual(CallSDP.fmtp([:]), "")
        XCTAssertEqual(CallSDP.feedbackList([
            CallFeedback(type: "transport-cc", subtype: ""),
            CallFeedback(type: "nack", subtype: "pli"),
        ]), "transport-cc,nack pli")
        XCTAssertEqual(CallSDP.feedbackList([]), "")
    }
}
