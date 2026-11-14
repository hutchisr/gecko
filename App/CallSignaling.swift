import Foundation

struct CallSnapshot: Equatable {
    let id: Int32
    let conversation: Int32
    let jid: String
    let name: String
    let incoming: Bool
    /// ringing, establishing, in_progress, ended, declined, missed, failed or other_device.
    let state: String
    let reason: String
}

/// Runs the signalling of one call at a time (`CallSession`) over the XMPP
/// core's connection and drives the media engine with what was negotiated.
@MainActor
final class CallSignaling: CallMediaEvents {
    var onCall: ((CallSnapshot) -> Void)?
    var onError: ((String) -> Void)?
    /// Account, peer and display name of a one-to-one conversation.
    var conversation: ((Int32) -> (account: String, jid: String, name: String)?)?
    /// The open conversation with a peer, by bare JID.
    var conversationFor: ((String) -> (id: Int32, name: String)?)?

    private let engine: CallMedia
    private var session: CallSession?
    private var callID: Int32 = 0
    private var conversationID: Int32 = 0
    private var name = ""

    private var iceServers: [CallIceServer] = []
    /// The id of the server-list request the call is still waiting for.
    private var iceQuery: String?
    /// Engine commands held, in order, until the server list is known.
    private var heldCommands: [() -> Void] = []

    init(media: CallMedia) {
        engine = media
    }

    // MARK: The user

    func start(conversation id: Int32) {
        guard session == nil else { return }
        guard let chat = conversation?(id) else {
            onError?("This chat cannot be called.")
            return
        }
        begin(CallSession.outgoing(account: chat.account, peer: chat.jid, sid: UUID().uuidString.lowercased()),
              conversation: id, name: chat.name)
    }

    func accept(_ call: Int32) {
        guard call == callID else { return }
        update { $0.accept() }
    }

    func reject(_ call: Int32) {
        guard call == callID else { return }
        update { $0.reject() }
    }

    func end(_ call: Int32) {
        guard call == callID else { return }
        update { $0.hangUp() }
    }

    func setMuted(_ call: Int32, _ muted: Bool) {
        guard call == callID else { return }
        update { $0.muted(muted) }
    }

    func reset() {
        if session != nil { engine.close(media: callID) }
        session = nil
        iceQuery = nil
        heldCommands = []
    }

    // MARK: The media engine

    func media(_ media: Int32, localDescription: CallLocalDescription) {
        guard media == callID else { return }
        update { $0.localDescription(localDescription) }
    }

    func media(_ media: Int32, localCandidate: CallCandidate) {
        guard media == callID else { return }
        update { $0.localCandidate(localCandidate) }
    }

    func mediaConnected(_ media: Int32) {
        guard media == callID else { return }
        update {
            $0.mediaConnected()
            return []
        }
    }

    func media(_ media: Int32, failed reason: String) {
        guard media == callID else { return }
        update { $0.mediaFailed(reason) }
    }

    // MARK: The peer

    /// Stanza events from the bridge; true when the event was one.
    func handle(_ e: [String: Any]) -> Bool {
        guard e["type"] as? String == "stanza" else { return false }
        guard let account = e["account"] as? String, let me = e["me"] as? String,
              let xml = e["xml"] as? String, let stanza = StanzaNode.parse(xml) else { return true }
        let from = stanza["from"] ?? ""
        if stanza.name == "message" {
            message(stanza, account: account, from: from, me: me)
        } else if stanza.name == "iq" {
            iq(stanza, account: account, from: from)
        }
        return true
    }

    private func message(_ stanza: StanzaNode, account: String, from: String, me: String) {
        guard let jmi = stanza.children.first(where: { $0.ns == CallNS.jmi }),
              let sid = jmi["id"], !isStale(stanza) else { return }
        if jmi.name == "propose" {
            // ponytail: one call at a time, audio only. A second caller keeps
            // ringing our other devices, and proposals that include video are
            // left to them; lift both when video calls arrive.
            let wanted = jmi.children("description", CallNS.rtp).compactMap { $0["media"] }
            let peer = CallSession.bare(from)
            guard session == nil, peer != account, wanted == ["audio"] else { return }
            let chat = conversationFor?(peer)
            begin(CallSession.proposed(account: account, from: from, sid: sid),
                  conversation: chat?.id ?? 0, name: chat?.name ?? peer)
        } else if session?.sid == sid {
            update { $0.jmi(jmi.name, from: from, me: me) }
        }
    }

    private func iq(_ stanza: StanzaNode, account: String, from: String) {
        let id = stanza["id"] ?? ""
        switch stanza["type"] {
        case "result", "error":
            if id == iceQuery {
                let services = stanza.child("services", CallNS.externalServices)
                iceServersKnown(id, services.map(Jingle.iceServers(from:)) ?? [])
            } else if stanza["type"] == "error" {
                update { $0.requestFailed(id: id) }
            }
        case "set":
            guard let jingle = stanza.child("jingle", CallNS.jingle) else { return }
            send(Jingle.iq("result", to: from, id: id), account: account)
            if session?.sid == jingle["sid"] {
                update { $0.jingle(jingle, from: from) }
            } else if jingle["action"] == "session-initiate" {
                directCall(jingle, account: account, from: from)
            }
        default:
            break
        }
    }

    /// A call from a client that skips Jingle Message Initiation.
    private func directCall(_ jingle: StanzaNode, account: String, from: String) {
        guard session == nil else {
            let busy = Jingle.terminate(sid: jingle["sid"] ?? "", reason: "busy")
            send(Jingle.iq("set", to: from, id: UUID().uuidString, busy), account: account)
            return
        }
        let created = CallSession.initiated(account: account, from: from, jingle: jingle)
        guard !created.0.state.isTerminal else {
            // An offer we cannot take is refused without bothering the user.
            for case .send(let node) in created.1 { send(node, account: account) }
            return
        }
        let chat = conversationFor?(created.0.peer)
        begin(created, conversation: chat?.id ?? 0, name: chat?.name ?? created.0.peer)
    }

    /// Offline-stored announcements of calls that are long over.
    private func isStale(_ stanza: StanzaNode) -> Bool {
        guard let stamp = stanza.child("delay", CallNS.delay)?["stamp"] else { return false }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions.insert(.withFractionalSeconds)
        guard let sent = ISO8601DateFormatter().date(from: stamp) ?? fractional.date(from: stamp) else { return true }
        return Date().timeIntervalSince(sent) > 30
    }

    // MARK: Running a session

    private func begin(_ created: (CallSession, [CallSession.Effect]), conversation: Int32, name: String) {
        callID += 1
        session = created.0
        conversationID = conversation
        self.name = name
        requestIceServers(account: created.0.account)
        publish()
        run(created.1)
    }

    private func update(_ change: (inout CallSession) -> [CallSession.Effect]) {
        guard var current = session else { return }
        let before = current.state
        let effects = change(&current)
        session = current
        if current.state != before { publish() }
        run(effects)
        if current.state.isTerminal {
            session = nil
            iceQuery = nil
            heldCommands = []
        }
    }

    private func publish() {
        guard let session else { return }
        NSLog("gecko-call: signalling %@ %@ %@", session.incoming ? "in" : "out",
              session.state.rawValue, session.reason)
        onCall?(CallSnapshot(
            id: callID, conversation: conversationID, jid: session.peer, name: name,
            incoming: session.incoming, state: session.state.rawValue, reason: session.reason))
    }

    private func run(_ effects: [CallSession.Effect]) {
        guard let account = session?.account else { return }
        let id = callID
        for effect in effects {
            switch effect {
            case .send(let node):
                send(node, account: account)
            case .offerNeeded:
                command { $0.engine.offerNeeded(media: id, iceServers: $0.iceServers) }
            case .remote(let kind, let content):
                command {
                    $0.engine.remote(media: id, CallRemoteDescription(
                        kind: kind, mid: content.name, transport: content.transport,
                        payload: content.payload, rtcpMux: content.rtcpMux,
                        candidates: content.candidates, iceServers: $0.iceServers))
                }
            case .remoteCandidates(let candidates):
                command { $0.engine.remoteCandidates(media: id, candidates) }
            case .closeMedia:
                heldCommands = []
                engine.close(media: id)
            }
        }
    }

    private func send(_ node: StanzaNode, account: String) {
        GeckoCore.shared.sendStanza(account: account, xml: node.xml)
    }

    /// Runs an engine command now, or in order once the server list is known.
    private func command(_ body: @escaping (CallSignaling) -> Void) {
        if iceQuery == nil {
            body(self)
        } else {
            heldCommands.append { [unowned self] in body(self) }
        }
    }

    // MARK: STUN and TURN servers (XEP-0215)

    private func requestIceServers(account: String) {
        let id = "call-ice-\(callID)"
        iceQuery = id
        let domain = account.split(separator: "@").last.map(String.init) ?? account
        send(Jingle.iq("get", to: domain, id: id, StanzaNode("services", CallNS.externalServices)),
             account: account)
        // A server that never answers must not hold the call up.
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1500))
            self?.iceServersKnown(id, [])
        }
    }

    private func iceServersKnown(_ id: String, _ servers: [CallIceServer]) {
        guard iceQuery == id else { return }
        iceQuery = nil
        // The fallback Dino uses when the account's server offers none.
        iceServers = servers.isEmpty
            ? [CallIceServer(urls: "stun:stun.dino.im:7886", username: nil, credential: nil)]
            : servers
        let held = heldCommands
        heldCommands = []
        held.forEach { $0() }
    }
}
