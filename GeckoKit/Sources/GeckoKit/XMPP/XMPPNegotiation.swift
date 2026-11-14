import Foundation

enum XMPPNS {
    static let client = "jabber:client"
    static let stream = "http://etherx.jabber.org/streams"
    static let tls = "urn:ietf:params:xml:ns:xmpp-tls"
    static let sasl = "urn:ietf:params:xml:ns:xmpp-sasl"
    static let bind = "urn:ietf:params:xml:ns:xmpp-bind"
    static let session = "urn:ietf:params:xml:ns:xmpp-session"
    static let sm = "urn:xmpp:sm:3"
    static let streamErrors = "urn:ietf:params:xml:ns:xmpp-streams"
    static let csi = "urn:xmpp:csi:0"
    static let ping = "urn:xmpp:ping"
}

/// What a stream-management session needs to be resumed (XEP-0198).
struct XMPPResumption: Equatable {
    let id: String
    /// The full JID the session was bound to.
    let jid: String
    /// Where the server said it can be reached for resumption, if it said.
    let location: String?
    /// Seconds the server keeps the session after the connection drops.
    let max: Int?
}

/// Everything from the first stream header to a usable session: STARTTLS,
/// SASL (SCRAM, or PLAIN over TLS), resource binding, then stream management
/// (resuming the previous session when possible, enabling it otherwise). Pure:
/// the caller feeds it parsed stream events and performs what it returns.
struct XMPPNegotiation {
    enum Action: Equatable {
        /// Write a fresh stream header and parse with a new parser.
        case openStream
        /// Upgrade the transport to TLS, then `.openStream`.
        case startTLS
        case send(StanzaNode)
        /// The session is usable. `sm`: stream management is on and the
        /// session can be resumed later with this. `resumedAt`: the previous
        /// session continues, and the server had received this many of our
        /// stanzas (resend the rest); nil for a new session.
        case ready(jid: String, sm: XMPPResumption?, resumedAt: UInt32?)
        case failed(Failure)
    }

    enum Failure: Error, Equatable {
        /// The server offers no TLS and the transport is not encrypted.
        case tlsUnavailable
        case notAuthorized(String)
        case noUsableMechanism
        case authentication(SCRAM.Failure)
        case bind(String)
        case streamError(String)
        case unexpected(String)
    }

    private enum Phase: Equatable {
        case features, tls, auth, bind, session, resume, enable, ready, failed
    }

    let bare: String
    private let password: String
    private let resource: String
    private var encrypted: Bool
    private var previous: XMPPResumption?
    /// Stanzas received in the previous session, for `<resume h=>`.
    private let handled: UInt32
    private var phase = Phase.features
    private var authenticated = false
    private var scram: SCRAM?
    private var jid = ""
    private var smOffered = false
    /// Off for short sessions (the notification extension): no session is
    /// left for the server to hold and push for after we go.
    private let streamManagement: Bool
    /// The server takes client state indications (XEP-0352).
    private(set) var csiOffered = false

    /// `encrypted`: the transport is already TLS (XEP-0368 direct TLS).
    /// `resume`: the session to resume, from an earlier `.ready`, and how
    /// many stanzas we had received in it.
    init(jid bare: String, password: String, resource: String, encrypted: Bool,
         resume: XMPPResumption? = nil, handled: UInt32 = 0, streamManagement: Bool = true) {
        self.streamManagement = streamManagement
        self.bare = bare
        self.password = password
        self.resource = resource
        self.encrypted = encrypted
        previous = resume
        self.handled = handled
    }

    private var localpart: String { bare.split(separator: "@", maxSplits: 1).first.map(String.init) ?? bare }

    /// The transport finished its TLS handshake after `.startTLS`.
    mutating func tlsEstablished() -> [Action] {
        guard phase == .tls else { return [] }
        encrypted = true
        phase = .features
        return [.openStream]
    }

    /// One first-level element of the server's stream.
    mutating func received(_ node: StanzaNode) -> [Action] {
        if node.ns == XMPPNS.stream, node.name == "error" {
            let condition = node.children.first { $0.ns == XMPPNS.streamErrors && $0.name != "text" }?.name
            return fail(.streamError(condition ?? "undefined-condition"))
        }
        switch phase {
        case .features:
            guard node.ns == XMPPNS.stream, node.name == "features" else { return unexpected(node) }
            return features(node)
        case .tls:
            guard node.ns == XMPPNS.tls, node.name == "proceed" else { return fail(.tlsUnavailable) }
            return [.startTLS]
        case .auth:
            return sasl(node)
        case .bind:
            return bound(node)
        case .session:
            guard node.name == "iq", node["id"] == "session" else { return unexpected(node) }
            return node["type"] == "result" ? afterBind() : fail(.bind("session establishment refused"))
        case .resume:
            return resumed(node)
        case .enable:
            return enabled(node)
        case .ready, .failed:
            return []
        }
    }

    // MARK: Steps

    private mutating func features(_ features: StanzaNode) -> [Action] {
        if !encrypted {
            guard features.child("starttls", XMPPNS.tls) != nil else { return fail(.tlsUnavailable) }
            phase = .tls
            return [.send(StanzaNode("starttls", XMPPNS.tls))]
        }
        if !authenticated {
            let offered = features.child("mechanisms", XMPPNS.sasl)?.children("mechanism", XMPPNS.sasl).map(\.text) ?? []
            phase = .auth
            if let hash = SCRAM.best(offered: offered) {
                return authenticate(hash)
            }
            if offered.contains("PLAIN") {
                let plain = Data("\0\(localpart)\0\(password)".utf8)
                return [.send(StanzaNode("auth", XMPPNS.sasl, ["mechanism": "PLAIN"], text: plain.base64EncodedString()))]
            }
            return fail(.noUsableMechanism)
        }
        smOffered = features.child("sm", XMPPNS.sm) != nil
        csiOffered = features.child("csi", XMPPNS.csi) != nil
        if smOffered, let previous {
            phase = .resume
            return [.send(StanzaNode("resume", XMPPNS.sm, ["previd": previous.id, "h": String(handled)]))]
        }
        return bind(sessionRequired: sessionRequired(features))
    }

    private var sessionNeeded = false

    private mutating func authenticate(_ hash: SCRAM.Hash) -> [Action] {
        let scram = SCRAM(hash: hash, username: localpart, password: password)
        self.scram = scram
        return [.send(StanzaNode("auth", XMPPNS.sasl, ["mechanism": hash.rawValue],
                                 text: scram.clientFirst.base64EncodedString()))]
    }

    private func sessionRequired(_ features: StanzaNode) -> Bool {
        guard let session = features.child("session", XMPPNS.session) else { return false }
        return session.child("optional", XMPPNS.session) == nil
    }

    private mutating func bind(sessionRequired: Bool) -> [Action] {
        sessionNeeded = sessionRequired
        phase = .bind
        let bind = StanzaNode("bind", XMPPNS.bind, [:], [StanzaNode("resource", XMPPNS.bind, text: resource)])
        return [.send(StanzaNode("iq", XMPPNS.client, ["type": "set", "id": "bind"], [bind]))]
    }

    private mutating func sasl(_ node: StanzaNode) -> [Action] {
        guard node.ns == XMPPNS.sasl else { return unexpected(node) }
        switch node.name {
        case "challenge":
            guard var scram, let data = Data(base64Encoded: node.text) else { return fail(.unexpected("challenge")) }
            do {
                let final = try scram.clientFinal(serverFirst: data)
                self.scram = scram
                return [.send(StanzaNode("response", XMPPNS.sasl, text: final.base64EncodedString()))]
            } catch let failure as SCRAM.Failure {
                return fail(.authentication(failure))
            } catch {
                return fail(.unexpected("\(error)"))
            }
        case "success":
            if let scram {
                guard let final = Data(base64Encoded: node.text) else { return fail(.authentication(.malformedChallenge)) }
                do {
                    try scram.verify(serverFinal: final)
                } catch let failure as SCRAM.Failure {
                    return fail(.authentication(failure))
                } catch {
                    return fail(.unexpected("\(error)"))
                }
            }
            authenticated = true
            phase = .features
            return [.openStream]
        case "failure":
            let condition = node.children.first { $0.name != "text" }?.name ?? "not-authorized"
            return fail(.notAuthorized(condition))
        default:
            return unexpected(node)
        }
    }

    private mutating func bound(_ node: StanzaNode) -> [Action] {
        guard node.name == "iq", node["id"] == "bind" else { return unexpected(node) }
        guard node["type"] == "result", let full = node.child("bind", XMPPNS.bind)?.child("jid", XMPPNS.bind)?.text,
              !full.isEmpty else {
            let condition = node.child("error", XMPPNS.client)?.children.first?.name ?? "bind failed"
            return fail(.bind(condition))
        }
        jid = full
        if sessionNeeded {
            phase = .session
            return [.send(StanzaNode("iq", XMPPNS.client, ["type": "set", "id": "session"],
                                     [StanzaNode("session", XMPPNS.session)]))]
        }
        return afterBind()
    }

    private mutating func afterBind() -> [Action] {
        guard smOffered, streamManagement else {
            phase = .ready
            return [.ready(jid: jid, sm: nil, resumedAt: nil)]
        }
        phase = .enable
        return [.send(StanzaNode("enable", XMPPNS.sm, ["resume": "true"]))]
    }

    private mutating func resumed(_ node: StanzaNode) -> [Action] {
        guard node.ns == XMPPNS.sm else { return unexpected(node) }
        switch node.name {
        case "resumed":
            phase = .ready
            guard let previous, let acked = node["h"].flatMap(UInt32.init) else { return fail(.unexpected("resumed")) }
            return [.ready(jid: previous.jid, sm: previous, resumedAt: acked)]
        case "failed":
            // The old session is gone; start a new one on this stream.
            previous = nil
            return bind(sessionRequired: false)
        default:
            return unexpected(node)
        }
    }

    private mutating func enabled(_ node: StanzaNode) -> [Action] {
        guard node.ns == XMPPNS.sm else { return unexpected(node) }
        phase = .ready
        if node.name == "enabled", node["resume"] == "true" || node["resume"] == "1", let id = node["id"] {
            let resumption = XMPPResumption(id: id, jid: jid, location: node["location"],
                                            max: node["max"].flatMap(Int.init))
            return [.ready(jid: jid, sm: resumption, resumedAt: nil)]
        }
        // Enabled without resumption, or refused: carry on without it.
        return [.ready(jid: jid, sm: nil, resumedAt: nil)]
    }

    private mutating func unexpected(_ node: StanzaNode) -> [Action] {
        fail(.unexpected("<\(node.name) xmlns='\(node.ns)'>"))
    }

    private mutating func fail(_ failure: Failure) -> [Action] {
        phase = .failed
        return [.failed(failure)]
    }
}
