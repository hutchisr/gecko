import Foundation

// The Jingle (XEP-0166/0167/0176/0320) and Jingle Message Initiation
// (XEP-0353) XML for a one-to-one Opus audio call.

enum CallNS {
    static let client = "jabber:client"
    static let jingle = "urn:xmpp:jingle:1"
    static let rtp = "urn:xmpp:jingle:apps:rtp:1"
    static let rtpAudio = "urn:xmpp:jingle:apps:rtp:audio"
    static let rtpInfo = "urn:xmpp:jingle:apps:rtp:info:1"
    static let rtcpFeedback = "urn:xmpp:jingle:apps:rtp:rtcp-fb:0"
    static let ice = "urn:xmpp:jingle:transports:ice-udp:1"
    static let dtls = "urn:xmpp:jingle:apps:dtls:0"
    static let jmi = "urn:xmpp:jingle-message:0"
    static let externalServices = "urn:xmpp:extdisco:2"
    static let delay = "urn:xmpp:delay"

    /// What calls add to the features the XMPP core already advertises.
    static let features = [rtp, rtpAudio, ice, dtls]
}

/// The audio content of a session-initiate or session-accept.
struct JingleContent: Equatable {
    let name: String
    let transport: CallTransport
    let payload: CallPayload
    let rtcpMux: Bool
    var candidates: [CallCandidate]
}

enum Jingle {
    // MARK: Parsing

    /// The session's audio content, when it is one we can take part in:
    /// Opus over ICE-UDP with a DTLS fingerprint.
    static func content(of jingle: StanzaNode) -> JingleContent? {
        for content in jingle.children("content", CallNS.jingle) {
            guard let name = content["name"],
                  let description = content.child("description", CallNS.rtp),
                  description["media"] == "audio",
                  let transport = content.child("transport", CallNS.ice),
                  let ufrag = transport["ufrag"], let pwd = transport["pwd"],
                  let fingerprint = transport.child("fingerprint", CallNS.dtls),
                  let payload = opus(in: description) else { continue }
            return JingleContent(
                name: name,
                transport: CallTransport(
                    ufrag: ufrag, pwd: pwd,
                    fingerprint: fingerprint.text
                        .trimmingCharacters(in: .whitespacesAndNewlines).uppercased(),
                    hash: (fingerprint["hash"] ?? "sha-256").lowercased(),
                    setup: fingerprint["setup"] ?? "actpass"),
                payload: payload,
                rtcpMux: description.child("rtcp-mux", CallNS.rtp) != nil,
                candidates: candidates(in: transport))
        }
        return nil
    }

    /// The candidates of a transport-info.
    static func candidates(of jingle: StanzaNode) -> [CallCandidate] {
        jingle.children("content", CallNS.jingle)
            .compactMap { $0.child("transport", CallNS.ice) }
            .flatMap(candidates(in:))
    }

    /// More than one content means the peer also wants video.
    static func isAudioOnly(_ jingle: StanzaNode) -> Bool {
        jingle.children("content", CallNS.jingle).count == 1
    }

    static func terminationReason(of jingle: StanzaNode) -> String {
        jingle.child("reason", CallNS.jingle)?.children.first { $0.name != "text" }?.name ?? ""
    }

    /// STUN and TURN servers from an XEP-0215 `<services/>` result.
    static func iceServers(from services: StanzaNode) -> [CallIceServer] {
        services.children("service", CallNS.externalServices).compactMap { service in
            guard let type = service["type"], let host = service["host"],
                  let port = service["port"] else { return nil }
            let address = host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
            let transport = service["transport"] ?? "udp"
            switch type {
            case "stun" where transport == "udp":
                return CallIceServer(urls: "stun:\(address)", username: nil, credential: nil)
            case "turn", "turns":
                return CallIceServer(
                    urls: "\(type):\(address)?transport=\(transport)",
                    username: service["username"], credential: service["password"])
            default:
                return nil
            }
        }
    }

    private static func opus(in description: StanzaNode) -> CallPayload? {
        for node in description.children("payload-type", CallNS.rtp) {
            guard let id = node["id"].flatMap(Int.init),
                  node["name"]?.lowercased() == "opus",
                  node["clockrate"] == "48000" else { continue }
            var parameters: [String: String] = [:]
            for parameter in node.children("parameter", CallNS.rtp) {
                if let name = parameter["name"] { parameters[name] = parameter["value"] ?? "" }
            }
            let feedback = node.children("rtcp-fb", CallNS.rtcpFeedback).compactMap { fb in
                fb["type"].map { CallFeedback(type: $0, subtype: fb["subtype"] ?? "") }
            }
            // SDP always describes Opus as two channels, whatever the peer wrote.
            return CallPayload(id: id, name: "opus", clockrate: 48_000, channels: 2,
                               parameters: parameters, feedback: feedback)
        }
        return nil
    }

    private static func candidates(in transport: StanzaNode) -> [CallCandidate] {
        transport.children("candidate", CallNS.ice).compactMap { node in
            guard node["protocol"]?.lowercased() == "udp",
                  let ip = node["ip"], let type = node["type"],
                  let port = node["port"].flatMap(Int.init),
                  let priority = node["priority"].flatMap(UInt32.init) else { return nil }
            return CallCandidate(
                foundation: node["foundation"] ?? "0",
                component: node["component"].flatMap(Int.init) ?? 1,
                transport: "udp", priority: priority, ip: ip, port: port, type: type,
                relatedAddress: node["rel-addr"],
                relatedPort: node["rel-port"].flatMap(Int.init) ?? 0,
                generation: node["generation"].flatMap(Int.init) ?? 0)
        }
    }

    // MARK: Building

    static func iq(_ type: String, to: String, id: String, _ child: StanzaNode? = nil) -> StanzaNode {
        StanzaNode("iq", CallNS.client, ["type": type, "to": to, "id": id], child.map { [$0] } ?? [])
    }

    static func message(to: String, _ child: StanzaNode) -> StanzaNode {
        StanzaNode("message", CallNS.client, ["type": "chat", "to": to], [child])
    }

    static func jmi(_ name: String, sid: String, proposingAudio: Bool = false) -> StanzaNode {
        StanzaNode(name, CallNS.jmi, ["id": sid],
                proposingAudio ? [StanzaNode("description", CallNS.rtp, ["media": "audio"])] : [])
    }

    static func jingle(_ action: String, sid: String, _ children: [StanzaNode] = []) -> StanzaNode {
        StanzaNode("jingle", CallNS.jingle, ["action": action, "sid": sid], children)
    }

    static func terminate(sid: String, reason: String) -> StanzaNode {
        jingle("session-terminate", sid: sid,
               [StanzaNode("reason", CallNS.jingle, [:], [StanzaNode(reason, CallNS.jingle)])])
    }

    /// The content of a session-initiate or session-accept.
    static func content(name: String, _ local: CallLocalDescription,
                        candidates: [CallCandidate]) -> StanzaNode {
        let payload = local.payload
        let payloadNode = StanzaNode(
            "payload-type", CallNS.rtp,
            ["id": String(payload.id), "name": payload.name,
             "clockrate": String(payload.clockrate), "channels": String(payload.channels)],
            payload.parameters.sorted { $0.key < $1.key }.map {
                StanzaNode("parameter", CallNS.rtp, ["name": $0.key, "value": $0.value])
            } + payload.feedback.map {
                StanzaNode("rtcp-fb", CallNS.rtcpFeedback,
                        $0.subtype.isEmpty ? ["type": $0.type] : ["type": $0.type, "subtype": $0.subtype])
            })
        let fingerprint = StanzaNode(
            "fingerprint", CallNS.dtls,
            ["hash": local.transport.hash, "setup": local.transport.setup],
            text: local.transport.fingerprint)
        return StanzaNode(
            "content", CallNS.jingle, ["creator": "initiator", "name": name, "senders": "both"],
            [StanzaNode("description", CallNS.rtp, ["media": "audio"],
                     [payloadNode, StanzaNode("rtcp-mux", CallNS.rtp)]),
             transport(local.transport, [fingerprint] + candidates.map(candidate))])
    }

    /// The content of a transport-info carrying one more local candidate.
    static func content(name: String, _ transport: CallTransport, candidate: CallCandidate) -> StanzaNode {
        StanzaNode("content", CallNS.jingle, ["creator": "initiator", "name": name],
                [Jingle.transport(transport, [Jingle.candidate(candidate)])])
    }

    private static func transport(_ transport: CallTransport, _ children: [StanzaNode]) -> StanzaNode {
        StanzaNode("transport", CallNS.ice, ["ufrag": transport.ufrag, "pwd": transport.pwd], children)
    }

    private static func candidate(_ c: CallCandidate) -> StanzaNode {
        var attributes = [
            "component": String(c.component), "foundation": c.foundation,
            "generation": String(c.generation), "id": "\(c.foundation)-\(c.component)-\(c.port)",
            "ip": c.ip, "network": "0", "port": String(c.port), "priority": String(c.priority),
            "protocol": "udp", "type": c.type,
        ]
        if let related = c.relatedAddress {
            attributes["rel-addr"] = related
            attributes["rel-port"] = String(c.relatedPort)
        }
        return StanzaNode("candidate", CallNS.ice, attributes)
    }
}
