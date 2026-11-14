import Foundation

/// The signalling state of one call: what to send and what to ask of the media
/// engine in response to the user, the peer and the engine. Pure, so the whole
/// negotiation is testable without a connection or audio.
struct CallSession {
    enum State: String {
        case ringing, establishing, inProgress = "in_progress"
        case ended, declined, missed, failed, otherDevice = "other_device"

        var isTerminal: Bool {
            switch self {
            case .ringing, .establishing, .inProgress: return false
            case .ended, .declined, .missed, .failed, .otherDevice: return true
            }
        }
    }

    enum Effect: Equatable {
        case send(StanzaNode)
        /// Create the offer for an outgoing call.
        case offerNeeded
        case remote(CallRemoteDescription.Kind, JingleContent)
        case remoteCandidates([CallCandidate])
        case closeMedia
    }

    /// Our bare JID.
    let account: String
    /// The peer's bare JID.
    let peer: String
    let sid: String
    let incoming: Bool
    private(set) var state = State.ringing
    private(set) var reason = ""

    /// The peer's device: the caller's, or the one that answered.
    private var peerFull: String?
    /// The user answered an incoming call.
    private var accepted = false
    /// A Jingle session exists (session-initiate sent or received).
    private var sessionOpen = false
    /// The peer's offer, until the user answers.
    private var offer: JingleContent?
    private var contentName = ""
    private var local: CallLocalDescription?
    /// Local candidates gathered before our description went out.
    private var queued: [CallCandidate] = []
    /// The request the call cannot survive an error reply to.
    private var criticalIQ: String?
    private var iqCount = 0

    // MARK: Creation

    static func outgoing(account: String, peer: String, sid: String) -> (CallSession, [Effect]) {
        let session = CallSession(account: account, peer: peer, sid: sid, incoming: false)
        return (session, [.send(Jingle.message(to: peer, Jingle.jmi("propose", sid: sid, proposingAudio: true)))])
    }

    /// A call announced with Jingle Message Initiation.
    static func proposed(account: String, from: String, sid: String) -> (CallSession, [Effect]) {
        var session = CallSession(account: account, peer: bare(from), sid: sid, incoming: true)
        session.peerFull = from
        return (session, [.send(Jingle.message(to: from, Jingle.jmi("ringing", sid: sid)))])
    }

    /// A call that starts directly with a session-initiate.
    static func initiated(account: String, from: String, jingle: StanzaNode) -> (CallSession, [Effect]) {
        var session = CallSession(account: account, peer: bare(from), sid: jingle["sid"] ?? "", incoming: true)
        session.peerFull = from
        let effects = session.jingle(jingle, from: from)
        return (session, effects)
    }

    // MARK: The user

    mutating func accept() -> [Effect] {
        guard incoming, state == .ringing, let peerFull else { return [] }
        accepted = true
        state = .establishing
        if let offer { return [.remote(.offer, offer)] }
        return [.send(Jingle.message(to: account, Jingle.jmi("accept", sid: sid))),
                .send(Jingle.message(to: peerFull, Jingle.jmi("proceed", sid: sid)))]
    }

    mutating func reject() -> [Effect] {
        guard incoming, state == .ringing, let peerFull else { return [] }
        let effects: [Effect] = sessionOpen
            ? [terminate("decline")]
            : [.send(Jingle.message(to: account, Jingle.jmi("reject", sid: sid))),
               .send(Jingle.message(to: peerFull, Jingle.jmi("reject", sid: sid)))]
        finish(.declined)
        return effects
    }

    mutating func hangUp() -> [Effect] {
        guard !state.isTerminal else { return [] }
        var effects: [Effect]
        if sessionOpen {
            effects = [terminate(state == .inProgress ? "success" : "cancel")]
        } else if incoming {
            effects = [.send(Jingle.message(to: peerFull ?? peer, Jingle.jmi("reject", sid: sid)))]
        } else {
            effects = [.send(Jingle.message(to: peerFull ?? peer, Jingle.jmi("retract", sid: sid)))]
        }
        effects.append(.closeMedia)
        finish(.ended)
        return effects
    }

    /// Tells the peer our microphone is muted; the engine does the muting.
    mutating func muted(_ muted: Bool) -> [Effect] {
        guard sessionOpen, !state.isTerminal, let peerFull, local != nil else { return [] }
        let info = StanzaNode(muted ? "mute" : "unmute", CallNS.rtpInfo,
                              ["creator": "initiator", "name": contentName])
        return [.send(request(to: peerFull, Jingle.jingle("session-info", sid: sid, [info])))]
    }

    // MARK: The peer

    /// A Jingle Message Initiation element about this call. `me` is our full JID.
    mutating func jmi(_ name: String, from: String, me: String) -> [Effect] {
        guard !state.isTerminal else { return [] }
        if incoming {
            if Self.bare(from) == account, from != me {
                // Another of our devices answered or declined.
                if name == "accept" { finish(.otherDevice) }
                if name == "reject" { finish(.declined) }
            } else if Self.bare(from) == peer, name == "retract", !sessionOpen {
                finish(.missed)
            }
            return state.isTerminal ? [.closeMedia] : []
        }
        guard Self.bare(from) == peer, state == .ringing else { return [] }
        switch name {
        case "proceed":
            peerFull = from
            state = .establishing
            return [.offerNeeded]
        case "reject":
            finish(.declined)
            return []
        default:
            return []
        }
    }

    /// A `<jingle/>` request for this call, already acknowledged by the caller.
    mutating func jingle(_ jingle: StanzaNode, from: String) -> [Effect] {
        guard !state.isTerminal, Self.bare(from) == peer else { return [] }
        switch jingle["action"] {
        case "session-initiate":
            guard incoming, !sessionOpen else { return [] }
            peerFull = from
            sessionOpen = true
            guard Jingle.isAudioOnly(jingle), let content = Jingle.content(of: jingle) else {
                let effects = [terminate("unsupported-applications")]
                finish(.failed, "unsupported call offer")
                return effects
            }
            contentName = content.name
            if accepted { return [.remote(.offer, content)] }
            offer = content
            return []
        case "session-accept":
            guard !incoming, sessionOpen else { return [] }
            guard let content = Jingle.content(of: jingle) else {
                let effects = [terminate("unsupported-applications"), Effect.closeMedia]
                finish(.failed, "unsupported call answer")
                return effects
            }
            return [.remote(.answer, content)]
        case "transport-info":
            let candidates = Jingle.candidates(of: jingle)
            guard !candidates.isEmpty else { return [] }
            if offer != nil {
                offer?.candidates += candidates
                return []
            }
            return [.remoteCandidates(candidates)]
        case "session-terminate":
            let why = Jingle.terminationReason(of: jingle)
            sessionOpen = false
            if state == .inProgress {
                finish(.ended)
            } else if why == "decline" || why == "busy" {
                finish(.declined, why == "busy" ? "busy" : "")
            } else if incoming, !accepted {
                finish(.missed)
            } else if why == "success" || why == "cancel" || why == "gone" {
                finish(.ended)
            } else {
                finish(.failed, why)
            }
            return [.closeMedia]
        default:
            // ponytail: content-add (the peer turning on video) is acknowledged
            // and ignored; reject it properly when video calls arrive.
            return []
        }
    }

    /// The peer answered one of our requests with an error.
    mutating func requestFailed(id: String) -> [Effect] {
        guard id == criticalIQ, !state.isTerminal else { return [] }
        sessionOpen = false
        finish(.failed, "the other device could not take the call")
        return [.closeMedia]
    }

    // MARK: The media engine

    mutating func localDescription(_ description: CallLocalDescription) -> [Effect] {
        guard !state.isTerminal, local == nil, let peerFull else { return [] }
        local = description
        if !incoming {
            contentName = description.mid
            sessionOpen = true
        }
        let content = Jingle.content(name: contentName, description, candidates: queued)
        queued = []
        let request = request(
            to: peerFull,
            Jingle.jingle(incoming ? "session-accept" : "session-initiate", sid: sid, [content]))
        criticalIQ = request["id"]
        return [.send(request)]
    }

    mutating func localCandidate(_ candidate: CallCandidate) -> [Effect] {
        guard !state.isTerminal else { return [] }
        guard let local, let peerFull else {
            queued.append(candidate)
            return []
        }
        let content = Jingle.content(name: contentName, local.transport, candidate: candidate)
        return [.send(request(to: peerFull, Jingle.jingle("transport-info", sid: sid, [content])))]
    }

    mutating func mediaConnected() {
        if state == .establishing { state = .inProgress }
    }

    mutating func mediaFailed(_ why: String) -> [Effect] {
        guard !state.isTerminal else { return [] }
        var effects: [Effect] = []
        if sessionOpen {
            effects = [terminate("connectivity-error")]
        } else if !incoming {
            effects = [.send(Jingle.message(to: peerFull ?? peer, Jingle.jmi("retract", sid: sid)))]
        }
        finish(.failed, why)
        return effects
    }

    // MARK: Helpers

    static func bare(_ jid: String) -> String {
        jid.split(separator: "/", maxSplits: 1).first.map(String.init) ?? jid
    }

    private mutating func request(to: String, _ jingle: StanzaNode) -> StanzaNode {
        iqCount += 1
        return Jingle.iq("set", to: to, id: "call-\(sid)-\(iqCount)", jingle)
    }

    private mutating func terminate(_ why: String) -> Effect {
        sessionOpen = false
        return .send(request(to: peerFull ?? peer, Jingle.terminate(sid: sid, reason: why)))
    }

    private mutating func finish(_ state: State, _ reason: String = "") {
        self.state = state
        self.reason = reason
    }
}
