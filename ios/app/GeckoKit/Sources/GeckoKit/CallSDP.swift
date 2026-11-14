import Foundation

// Translation between the SDP that WebRTC speaks and the handful of values
// Jingle signalling carries for a one-to-one Opus audio call.

struct CallFeedback: Equatable {
    let type: String
    /// "" when absent.
    let subtype: String
}

struct CallPayload: Equatable {
    let id: Int
    let name: String
    let clockrate: Int
    let channels: Int
    let parameters: [String: String]
    let feedback: [CallFeedback]
}

struct CallCandidate: Equatable {
    let foundation: String
    let component: Int
    /// Lower-case, always "udp".
    let transport: String
    let priority: UInt32
    let ip: String
    let port: Int
    let type: String
    let relatedAddress: String?
    let relatedPort: Int
    let generation: Int
}

struct CallIceServer: Equatable {
    let urls: String
    let username: String?
    let credential: String?
}

struct CallTransport: Equatable {
    let ufrag: String
    let pwd: String
    /// Colon-separated upper-case hex.
    let fingerprint: String
    /// Lower-case hash name, e.g. "sha-256".
    let hash: String
    let setup: String
}

struct CallLocalDescription: Equatable {
    let mid: String
    let bundle: Bool
    let transport: CallTransport
    let payload: CallPayload
}

struct CallRemoteDescription: Equatable {
    enum Kind: String { case offer, answer }

    let kind: Kind
    let mid: String
    let transport: CallTransport
    let payload: CallPayload
    let rtcpMux: Bool
    let candidates: [CallCandidate]
    let iceServers: [CallIceServer]
}

enum CallSDP {
    /// First `m=audio` section of a WebRTC-generated SDP: its mid, whether the session has `a=group:BUNDLE`,
    /// ICE credentials, DTLS fingerprint/setup (session-level values apply when the section has none), and the Opus payload
    /// (rtpmap `opus/48000/2`, its `a=fmtp` parameters and `a=rtcp-fb` entries). nil if there is no Opus audio section.
    static func localDescription(sdp: String) -> CallLocalDescription? {
        // "\r\n" is a single Character, so split on newline-ness rather than on "\n".
        let lines = sdp.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        let start = lines.firstIndex { $0.hasPrefix("m=") } ?? lines.endIndex
        guard let first = lines[start...].firstIndex(where: { $0.hasPrefix("m=audio ") }) else { return nil }
        let end = lines[(first + 1)...].firstIndex { $0.hasPrefix("m=") } ?? lines.endIndex
        let session = Array(lines[..<start])
        let media = Array(lines[first..<end])
        func value(_ name: String) -> String? {
            values(name, in: media).first ?? values(name, in: session).first
        }

        var opus: (id: Int, name: String)?
        for v in values("rtpmap", in: media) {
            let (pt, encoding) = head(v)
            guard encoding.lowercased() == "opus/48000/2", let id = Int(pt) else { continue }
            opus = (id, String(encoding.prefix { $0 != "/" }))
            break
        }
        guard let opus,
              let mid = value("mid"),
              let ufrag = value("ice-ufrag"),
              let pwd = value("ice-pwd"),
              let setup = value("setup"),
              let fp = value("fingerprint").map(head), !fp.1.isEmpty else { return nil }

        var parameters: [String: String] = [:]
        for v in values("fmtp", in: media) {
            let (pt, rest) = head(v)
            guard Int(pt) == opus.id else { continue }
            for item in rest.split(separator: ";") {
                let kv = item.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard kv.count == 2 else { continue }
                let key = kv[0].trimmingCharacters(in: .whitespaces)
                if !key.isEmpty { parameters[key] = kv[1].trimmingCharacters(in: .whitespaces) }
            }
        }
        var feedback: [CallFeedback] = []
        for v in values("rtcp-fb", in: media) {
            let (pt, rest) = head(v)
            guard Int(pt) == opus.id else { continue }
            let (type, subtype) = head(rest)
            if !type.isEmpty { feedback.append(CallFeedback(type: type, subtype: subtype)) }
        }

        return CallLocalDescription(
            mid: mid,
            bundle: session.contains { $0.hasPrefix("a=group:BUNDLE") },
            transport: CallTransport(
                ufrag: ufrag,
                pwd: pwd,
                fingerprint: fp.1.uppercased(),
                hash: fp.0.lowercased(),
                setup: setup
            ),
            payload: CallPayload(
                id: opus.id,
                name: opus.name,
                clockrate: 48000,
                channels: 2,
                parameters: parameters,
                feedback: feedback
            )
        )
    }

    /// A complete SDP for `RTCSessionDescription` describing the peer: one audio section with only `remote.payload`,
    /// `UDP/TLS/RTP/SAVPF`, `c=IN IP4 0.0.0.0`, `a=rtcp:9 IN IP4 0.0.0.0`, ICE ufrag/pwd, `a=ice-options:trickle`,
    /// fingerprint, setup, `a=mid:<mid>`, `a=sendrecv`, `a=rtcp-mux` (when `remote.rtcpMux`), rtpmap/fmtp/rtcp-fb,
    /// one `a=candidate:` line per candidate, and `a=group:BUNDLE <mid>` when `bundle`. CRLF line endings, trailing CRLF.
    /// No `a=extmap`, `a=ssrc` or `a=msid` lines.
    static func remoteSDP(_ remote: CallRemoteDescription, mid: String, bundle: Bool) -> String {
        let t = remote.transport
        let p = remote.payload
        var lines = [
            "v=0",
            "o=- 4611731400430051336 2 IN IP4 127.0.0.1",
            "s=-",
            "t=0 0",
        ]
        if bundle { lines.append("a=group:BUNDLE \(mid)") }
        lines += [
            "a=msid-semantic: WMS",
            "m=audio 9 UDP/TLS/RTP/SAVPF \(p.id)",
            "c=IN IP4 0.0.0.0",
            "a=rtcp:9 IN IP4 0.0.0.0",
            "a=ice-ufrag:\(t.ufrag)",
            "a=ice-pwd:\(t.pwd)",
            "a=ice-options:trickle",
            "a=fingerprint:\(t.hash.isEmpty ? "sha-256" : t.hash) \(t.fingerprint)",
            "a=setup:\(t.setup)",
            "a=mid:\(mid)",
            "a=sendrecv",
        ]
        if remote.rtcpMux { lines.append("a=rtcp-mux") }
        lines.append("a=rtpmap:\(p.id) \(p.name)/\(p.clockrate)" + (p.channels > 1 ? "/\(p.channels)" : ""))
        if !p.parameters.isEmpty { lines.append("a=fmtp:\(p.id) \(fmtp(p.parameters))") }
        for fb in p.feedback {
            lines.append("a=rtcp-fb:\(p.id) \(fb.type)" + (fb.subtype.isEmpty ? "" : " \(fb.subtype)"))
        }
        for c in remote.candidates { lines.append("a=" + sdpAttribute(for: c)) }
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    /// Parses `candidate:...` (with or without a leading `a=`). nil for anything that is not UDP.
    static func candidate(sdpAttribute: String) -> CallCandidate? {
        var s = sdpAttribute.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("a=") { s.removeFirst(2) }
        guard s.hasPrefix("candidate:") else { return nil }
        let t = s.dropFirst("candidate:".count).split(separator: " ")
        guard t.count >= 8, t[6] == "typ", t[2].lowercased() == "udp",
              let component = Int(t[1]), let priority = UInt32(t[3]), let port = Int(t[5]) else { return nil }
        var relatedAddress: String?
        var relatedPort = 0
        var generation = 0
        // RFC 5245 extension pairs; unknown names (ufrag, network-id, network-cost, ...) are skipped.
        var i = 8
        while i + 1 < t.count {
            switch t[i] {
            case "raddr": relatedAddress = String(t[i + 1])
            case "rport": relatedPort = Int(t[i + 1]) ?? 0
            case "generation": generation = Int(t[i + 1]) ?? 0
            default: break
            }
            i += 2
        }
        return CallCandidate(
            foundation: String(t[0]),
            component: component,
            transport: "udp",
            priority: priority,
            ip: String(t[4]),
            port: port,
            type: String(t[7]),
            relatedAddress: relatedAddress,
            relatedPort: relatedPort,
            generation: generation
        )
    }

    /// `candidate:<foundation> <component> udp <priority> <ip> <port> typ <type>[ raddr <a> rport <p>] generation <g>`
    static func sdpAttribute(for candidate: CallCandidate) -> String {
        let c = candidate
        var s = "candidate:\(c.foundation) \(c.component) \(c.transport) \(c.priority) \(c.ip) \(c.port) typ \(c.type)"
        if let raddr = c.relatedAddress { s += " raddr \(raddr) rport \(c.relatedPort)" }
        return s + " generation \(c.generation)"
    }

    /// "k=v;k=v", keys sorted.
    static func fmtp(_ parameters: [String: String]) -> String {
        parameters.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ";")
    }

    /// "transport-cc,nack pli"
    static func feedbackList(_ feedback: [CallFeedback]) -> String {
        feedback.map { $0.subtype.isEmpty ? $0.type : "\($0.type) \($0.subtype)" }.joined(separator: ",")
    }

    /// Values of every `a=<name>:` line, in order.
    private static func values(_ name: String, in lines: [String]) -> [String] {
        let prefix = "a=\(name):"
        return lines.compactMap {
            $0.hasPrefix(prefix) ? $0.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces) : nil
        }
    }

    /// Splits "111 minptime=10" into its first token and the (trimmed) remainder.
    private static func head(_ s: String) -> (String, String) {
        guard let space = s.firstIndex(of: " ") else { return (s, "") }
        return (String(s[..<space]), s[space...].trimmingCharacters(in: .whitespaces))
    }
}
