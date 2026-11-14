import Foundation
import Network

/// One account's connection: finds the server, negotiates, carries stanzas
/// with stream-management acknowledgement, notices a dead connection and
/// reconnects (resuming the session when the server still holds it) until
/// `stop()`.
actor XMPPClient {
    enum Event: Equatable {
        /// Usable. `resumed`: the previous session continues, nothing was lost.
        case connected(jid: String, resumed: Bool)
        case stanza(StanzaNode)
        /// The connection is gone; another attempt follows unless `stop()`ped.
        case disconnected(String)
        /// Retrying cannot help (wrong password, account gone); stopped.
        case failed(XMPPNegotiation.Failure)
    }

    nonisolated let events: AsyncStream<Event>
    private let emit: AsyncStream<Event>.Continuation

    let bare: String
    private let domain: String
    private let password: String
    private let resource: String

    private var transport: XMPPTransport?
    private var ready = false
    private var sm: StreamManagement?
    private var resumption: XMPPResumption?
    private var csi = false
    private var active = true
    private var lastHeard = Date()
    private var runner: Task<Void, Never>?
    private var wake: CheckedContinuation<Void, Never>?
    /// New for every start: a cancelled monitor cannot be started again.
    private var paths = NWPathMonitor()

    /// Seconds without a word from the server before it is asked for one,
    /// and how long it then has to answer.
    /// `DINO_LOG_XMPP` (any value): every stanza in and out on the console.
    /// Authentication is logged by element name only.
    private static let logsStanzas = ProcessInfo.processInfo.environment["DINO_LOG_XMPP"] != nil

    static let idle: TimeInterval = 60
    static let answer: TimeInterval = 20

    /// Where to connect instead of looking the domain up (tests).
    private let endpoints: [XMPPEndpoint]?

    private let streamManagement: Bool

    init(jid bare: String, password: String, resource: String, endpoints: [XMPPEndpoint]? = nil,
         streamManagement: Bool = true) {
        self.streamManagement = streamManagement
        self.endpoints = endpoints
        self.bare = bare
        domain = bare.split(separator: "@").last.map(String.init) ?? bare
        self.password = password
        self.resource = resource
        (events, emit) = AsyncStream.makeStream()
    }

    // MARK: API

    func start() {
        guard runner == nil else { return }
        paths = NWPathMonitor()
        paths.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            Task { await self?.retryNow() }
        }
        paths.start(queue: DispatchQueue(label: "gecko.xmpp.paths"))
        runner = Task { await run() }
    }

    /// Closes the stream cleanly (acknowledging what arrived) and stops.
    func stop() {
        runner?.cancel()
        runner = nil
        paths.cancel()
        if let transport, ready {
            if let sm { write(StanzaNode("a", XMPPNS.sm, ["h": String(sm.handled)]), transport) }
            transport.send(Data("</stream:stream>".utf8))
        }
        transport?.close()
        transport = nil
        ready = false
        resumption = nil
        retryNow()
    }

    func send(_ stanza: StanzaNode) {
        guard let transport, ready else {
            // ponytail: offline sends are dropped here; the store above keeps
            // them pending and sends again on `.connected`.
            return
        }
        write(stanza, transport)
        if sm != nil { write(StreamManagement.request, transport) }
    }

    /// Drops the connection without closing the stream, as a dead network
    /// would (tests).
    func dropConnection() {
        transport?.close()
    }

    /// Client state indication (XEP-0352): the user is (not) looking.
    func setActive(_ active: Bool) {
        self.active = active
        if let transport, ready, csi { write(StanzaNode(active ? "active" : "inactive", XMPPNS.csi), transport) }
    }

    // MARK: Connection loop

    private func run() async {
        var delay: TimeInterval = 1
        while !Task.isCancelled {
            do {
                try await connectOnce()
                delay = 1
            } catch let failure as XMPPNegotiation.Failure where Self.isFinal(failure) {
                emit.yield(.failed(failure))
                runner = nil
                return
            } catch {
                emit.yield(.disconnected("\(error)"))
            }
            guard !Task.isCancelled else { return }
            await pause(delay)
            delay = min(delay * 2, 60)
        }
    }

    private static func isFinal(_ failure: XMPPNegotiation.Failure) -> Bool {
        switch failure {
        // A server that is only refusing for now (rate limits) is retried.
        case .notAuthorized(let condition): return condition != "temporary-auth-failure" && condition != "aborted"
        case .noUsableMechanism, .authentication, .tlsUnavailable: return true
        case .bind, .streamError, .unexpected: return false
        }
    }

    /// Waits `seconds`, or less when the network comes back.
    private func pause(_ seconds: TimeInterval) async {
        await withCheckedContinuation { (woken: CheckedContinuation<Void, Never>) in
            wake = woken
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(seconds))
                await self?.retryNow()
            }
        }
    }

    private func retryNow() {
        wake?.resume()
        wake = nil
    }

    private func connectOnce() async throws {
        var lastError: Error = XMPPTransportError.connectFailed("no XMPP service for \(domain)")
        let candidates: [XMPPEndpoint]
        if let endpoints {
            candidates = endpoints
        } else {
            candidates = await XMPPEndpoints.resolve(domain: domain)
        }
        for endpoint in candidates {
            let transport: XMPPTransport
            do {
                transport = try await XMPPTransports.connect(endpoint, domain: domain)
            } catch {
                lastError = error
                continue
            }
            try await session(over: transport, encrypted: endpoint.directTLS)
            return
        }
        throw lastError
    }

    /// Negotiates and then carries stanzas until the connection ends.
    private func session(over transport: XMPPTransport, encrypted: Bool) async throws {
        self.transport = transport
        defer {
            transport.close()
            if self.transport === transport { self.transport = nil }
            ready = false
        }
        var negotiation = XMPPNegotiation(jid: bare, password: password, resource: resource,
                                          encrypted: encrypted, resume: resumption, handled: sm?.handled ?? 0,
                                          streamManagement: streamManagement)
        var parser = XMLStreamParser()
        openStream(transport)
        lastHeard = Date()
        let watchdog = Task { [weak self] in await self?.watch(transport) }
        defer { watchdog.cancel() }

        for try await bytes in transport.incoming {
            lastHeard = Date()
            for event in try parser.feed(bytes) {
                if Self.logsStanzas, case .element(let node) = event { log("IN", node) }
                guard case .element(let node) = event else {
                    if event == .closed { return }
                    continue
                }
                if ready {
                    receive(node, transport)
                    continue
                }
                for action in negotiation.received(node) {
                    switch action {
                    case .openStream:
                        parser = XMLStreamParser()
                        openStream(transport)
                    case .startTLS:
                        try await transport.startTLS()
                        for _ in negotiation.tlsEstablished() {
                            parser = XMLStreamParser()
                            openStream(transport)
                        }
                    case .send(let node):
                        write(node, transport)
                    case .ready(let jid, let managed, let resumedAt):
                        established(jid: jid, managed: managed, resumedAt: resumedAt,
                                    csi: negotiation.csiOffered, transport)
                    case .failed(let failure):
                        throw failure
                    }
                }
            }
        }
        throw XMPPTransportError.closed
    }

    private func established(jid: String, managed: XMPPResumption?, resumedAt: UInt32?, csi: Bool,
                             _ transport: XMPPTransport) {
        ready = true
        self.csi = csi
        let resend: [StanzaNode]
        if let resumedAt, var sm {
            resend = sm.resumed(at: resumedAt)
            self.sm = sm
        } else {
            // A new session: what the old one never confirmed may be lost.
            // Messages go again (a duplicate beats a loss); requests do not,
            // their callers start over on `.connected`.
            resend = (sm?.unacked ?? []).filter { $0.name == "message" }
            sm = managed == nil ? nil : StreamManagement()
        }
        resumption = managed
        emit.yield(.connected(jid: jid, resumed: resumedAt != nil))
        if csi, !active { write(StanzaNode("inactive", XMPPNS.csi), transport) }
        for stanza in resend { write(stanza, transport) }
        if sm != nil, !resend.isEmpty { write(StreamManagement.request, transport) }
    }

    private func receive(_ node: StanzaNode, _ transport: XMPPTransport) {
        if var sm {
            let answer = sm.received(node)
            self.sm = sm
            if let answer { write(answer, transport) }
        }
        if node.ns == XMPPNS.stream, node.name == "error" {
            transport.close()
            return
        }
        if node.name == "iq", node["type"] == "get", node.child("ping", XMPPNS.ping) != nil {
            write(StanzaNode("iq", XMPPNS.client, ["type": "result", "id": node["id"] ?? "", "to": node["from"] ?? domain]),
                  transport)
            return
        }
        if StreamManagement.isStanza(node) { emit.yield(.stanza(node)) }
    }

    /// Asks a quiet server for a sign of life and drops the connection when
    /// none comes, so the loop reconnects instead of waiting on a dead socket.
    private func watch(_ transport: XMPPTransport) async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(Self.idle))
            guard !Task.isCancelled, self.transport === transport else { return }
            guard Date().timeIntervalSince(lastHeard) >= Self.idle else { continue }
            if ready {
                write(sm != nil ? StreamManagement.request
                                : StanzaNode("iq", XMPPNS.client, ["type": "get", "id": "keepalive", "to": domain],
                                             [StanzaNode("ping", XMPPNS.ping)]), transport)
            }
            try? await Task.sleep(for: .seconds(Self.answer))
            if Date().timeIntervalSince(lastHeard) >= Self.idle + Self.answer {
                transport.close()
                return
            }
        }
    }

    // MARK: Writing

    private func log(_ direction: String, _ node: StanzaNode) {
        let secret = node.ns == XMPPNS.sasl
        var text = secret ? "<\(node.name) xmlns='\(node.ns)'/>" : node.xml
        // Avatars and files make stanzas of hundreds of kilobytes.
        if text.count > 4000 { text = text.prefix(4000) + "… (\(text.count) characters)" }
        NSLog("XMPP %@ [%@] %@", direction, bare, text)
    }

    private func openStream(_ transport: XMPPTransport) {
        transport.send(Data(("<?xml version='1.0'?><stream:stream xmlns='jabber:client' "
            + "xmlns:stream='http://etherx.jabber.org/streams' version='1.0' "
            + "from='\(bare)' to='\(domain)'>").utf8))
    }

    private func write(_ node: StanzaNode, _ transport: XMPPTransport) {
        if Self.logsStanzas { log("OUT", node) }
        sm?.sent(node)
        transport.send(Data(node.xml.utf8))
    }
}
