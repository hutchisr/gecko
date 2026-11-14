import AVFAudio
import Foundation
import Network
// WebRTC's Objective-C API predates Sendable; its objects proxy to WebRTC's own threads.
@preconcurrency import WebRTC

/// Driven by signalling.
@MainActor protocol CallMedia: AnyObject {
    func offerNeeded(media: Int32, iceServers: [CallIceServer])
    func remote(media: Int32, _ remote: CallRemoteDescription)
    func remoteCandidates(media: Int32, _ candidates: [CallCandidate])
    func close(media: Int32)
}

/// Reported by the media engine.
@MainActor protocol CallMediaEvents: AnyObject {
    func media(_ media: Int32, localDescription: CallLocalDescription)
    func media(_ media: Int32, localCandidate: CallCandidate)
    func mediaConnected(_ media: Int32)
    func media(_ media: Int32, failed reason: String)
}

/// The WebRTC side of a call: at most one audio-only peer connection.
/// Signalling drives it through `CallMedia` and hears back through `events`.
@MainActor
final class CallEngine: NSObject, CallMedia {
    private final class Session {
        let media: Int32
        let pc: RTCPeerConnection
        let track: RTCAudioTrack
        /// From our offer, or the peer's offer when we answer.
        var mid = ""
        var bundle = true
        var localSet = false
        var remoteSet = false
        /// Remote candidates waiting for the remote description.
        var queued: [CallCandidate]
        var connected = false
        var stats: Task<Void, Never>?
        let shims: [TurnShimProxy]

        init(media: Int32, pc: RTCPeerConnection, track: RTCAudioTrack, queued: [CallCandidate],
             shims: [TurnShimProxy]) {
            self.media = media
            self.pc = pc
            self.track = track
            self.queued = queued
            self.shims = shims
        }
    }

    weak var events: CallMediaEvents?
    /// Problems the user has to act on themselves (microphone access).
    var onError: ((String) -> Void)?
    var isMuted = false {
        didSet { session?.track.isEnabled = !isMuted }
    }

    /// Created on the first call: the factory starts WebRTC's threads.
    private lazy var factory: RTCPeerConnectionFactory = {
#if !targetEnvironment(macCatalyst)
        // WebRTC activates the audio session itself when media starts and
        // deactivates it when media stops; this is what it configures then.
        let audio = RTCAudioSessionConfiguration.webRTC()
        audio.category = AVAudioSession.Category.playAndRecord.rawValue
        audio.mode = AVAudioSession.Mode.voiceChat.rawValue
        audio.categoryOptions = [.allowBluetoothHFP]
        RTCAudioSessionConfiguration.setWebRTC(audio)
#endif
        // Audio only: no video codec factories.
        return RTCPeerConnectionFactory(encoderFactory: nil, decoderFactory: nil)
    }()
    private var session: Session?
    /// Remote candidates that arrived before their media session was opened
    /// (a caller trickles while the call is still ringing here).
    private var early: [Int32: [CallCandidate]] = [:]
#if !targetEnvironment(macCatalyst)
    private var speaker = false
#endif

    // MARK: CallMedia

    func offerNeeded(media: Int32, iceServers: [CallIceServer]) {
        guard let s = open(media, iceServers) else { return }
        withMicrophone(s.pc) { me, s in
            me.createLocal(s.pc, type: .offer)
        }
    }

    func remote(media: Int32, _ remote: CallRemoteDescription) {
        switch remote.kind {
        case .answer:
            guard let s = session, s.media == media, s.localSet, !s.remoteSet else {
                NSLog("gecko-call: media %d: answer without a pending offer", media)
                return
            }
            let sdp = CallSDP.remoteSDP(remote, mid: s.mid, bundle: s.bundle)
            setRemote(s.pc, RTCSessionDescription(type: .answer, sdp: sdp))
        case .offer:
            guard let s = open(media, remote.iceServers) else { return }
            s.mid = remote.mid
            let sdp = CallSDP.remoteSDP(remote, mid: remote.mid, bundle: true)
            withMicrophone(s.pc) { me, s in
                me.setRemote(s.pc, RTCSessionDescription(type: .offer, sdp: sdp)) { me, s in
                    me.createLocal(s.pc, type: .answer)
                }
            }
        }
    }

    func remoteCandidates(media: Int32, _ candidates: [CallCandidate]) {
        guard let s = session, s.media == media else {
            early[media, default: []] += candidates
            return
        }
        if s.remoteSet {
            Self.add(candidates, mid: s.mid, to: s.pc)
        } else {
            s.queued += candidates
        }
    }

    func close(media: Int32) {
        early[media] = nil
        guard let s = session, s.media == media else { return }
        session = nil
        s.stats?.cancel()
        s.pc.delegate = nil
        s.pc.close()
        s.shims.forEach { $0.stop() }
        NSLog("gecko-call: media %d closed", media)
#if !targetEnvironment(macCatalyst)
        restoreAudio()
#endif
    }

    func closeAll() {
        early = [:]
        if let s = session { close(media: s.media) }
    }

    // MARK: Audio route

#if !targetEnvironment(macCatalyst)
    func setSpeaker(_ on: Bool) {
        speaker = on
        applySpeaker()
    }

    /// The override only holds once WebRTC has put the session into
    /// play-and-record, so it is applied again when the call connects.
    private func applySpeaker() {
        guard session != nil else { return }
        let audio = RTCAudioSession.sharedInstance()
        guard audio.category == AVAudioSession.Category.playAndRecord.rawValue else { return }
        audio.lockForConfiguration()
        defer { audio.unlockForConfiguration() }
        do {
            try audio.overrideOutputAudioPort(speaker ? .speaker : .none)
        } catch {
            NSLog("gecko-call: speaker route failed: %@", error.localizedDescription)
        }
    }

    /// Hand the session back the way launch left it (`AppDelegate`): media
    /// playback, not activated.
    private func restoreAudio() {
        let audio = RTCAudioSession.sharedInstance()
        audio.lockForConfiguration()
        defer { audio.unlockForConfiguration() }
        do {
            try audio.setCategory(.playback, mode: .default, options: [])
        } catch {
            NSLog("gecko-call: audio session restore failed: %@", error.localizedDescription)
        }
    }
#endif

    // MARK: Session

    private func open(_ media: Int32, _ iceServers: [CallIceServer]) -> Session? {
        if let old = session {
            NSLog("gecko-call: media %d replaces media %d", media, old.media)
            close(media: old.media)
        }
        let config = RTCConfiguration()
        config.sdpSemantics = .unifiedPlan
        config.bundlePolicy = .maxBundle
        config.rtcpMuxPolicy = .require
        config.continualGatheringPolicy = .gatherContinually
        if ProcessInfo.processInfo.environment["DINO_CALL_RELAY_ONLY"] != nil {
            config.iceTransportPolicy = .relay
        }
        // UDP TURN goes through a loopback hop that covers for servers which
        // do not authenticate (`TurnAuthShim`); WebRTC would ignore those.
        var shims: [TurnShimProxy] = []
        config.iceServers = iceServers.map { server in
            var urls = [server.urls]
            if let turn = server.udpTurn, let username = server.username, let password = server.credential,
               let shim = TurnShimProxy(host: turn.host, port: turn.port, username: username, password: password) {
                shims.append(shim)
                urls = ["turn:127.0.0.1:\(shim.port)?transport=udp", "turn:[::1]:\(shim.port)?transport=udp"]
            }
            return RTCIceServer(urlStrings: urls, username: server.username, credential: server.credential)
        }
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let pc = factory.peerConnection(with: config, constraints: constraints, delegate: self) else {
            NSLog("gecko-call: media %d: no peer connection", media)
            shims.forEach { $0.stop() }
            events?.media(media, failed: "peer connection unavailable")
            return nil
        }
        let track = factory.audioTrack(with: factory.audioSource(with: nil), trackId: "audio")
        track.isEnabled = !isMuted
        guard pc.add(track, streamIds: ["gecko"]) != nil else {
            NSLog("gecko-call: media %d: audio track rejected", media)
            pc.close()
            shims.forEach { $0.stop() }
            events?.media(media, failed: "audio track unavailable")
            return nil
        }
        let s = Session(media: media, pc: pc, track: track, queued: early.removeValue(forKey: media) ?? [],
                        shims: shims)
        session = s
        NSLog("gecko-call: media %d opened, %ld ice server(s), %ld shimmed", media, iceServers.count, shims.count)
        return s
    }

    private func fail(_ s: Session, _ reason: String, _ error: Error? = nil) {
        NSLog("gecko-call: media %d failed: %@ (%@)", s.media, reason, error?.localizedDescription ?? "-")
        close(media: s.media)
        events?.media(s.media, failed: reason)
    }

    private func changed(_ s: Session, _ state: RTCPeerConnectionState) {
        NSLog("gecko-call: media %d connection %@", s.media, Self.name(state))
        switch state {
        case .connected:
            guard !s.connected else { return }
            s.connected = true
#if !targetEnvironment(macCatalyst)
            applySpeaker()
#endif
            logStats(s)
            events?.mediaConnected(s.media)
        case .failed:
            fail(s, "connection failed")
        default:
            break
        }
    }

    private static func name(_ state: RTCPeerConnectionState) -> String {
        switch state {
        case .new: return "new"
        case .connecting: return "connecting"
        case .connected: return "connected"
        case .disconnected: return "disconnected"
        case .failed: return "failed"
        case .closed: return "closed"
        @unknown default: return "unknown"
        }
    }

    /// Headless verification: packet counters every 2 s for the first 10 s
    /// of a connected call.
    private func logStats(_ s: Session) {
        s.stats = Task { [weak self] in
            for _ in 0..<5 {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled, self?.session === s else { return }
                Self.logPackets(of: s.pc)
            }
        }
    }

    // MARK: WebRTC calls
    //
    // WebRTC runs completion handlers and delegate methods on its signalling
    // thread. Everything below is nonisolated so those closures are too, and
    // each one comes back through `live`.

    /// Continue on the main actor, in arrival order, and only while `pc` still
    /// belongs to the live session: it may have been closed or replaced since.
    private nonisolated func live(_ pc: RTCPeerConnection, _ body: @escaping @MainActor (CallEngine, Session) -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let s = self.session, s.pc === pc else { return }
            body(self, s)
        }
    }

    /// Asks before any SDP exists, so a refused microphone never reaches the
    /// peer as a half-negotiated call.
    private nonisolated func withMicrophone(
        _ pc: RTCPeerConnection, _ body: @escaping @MainActor (CallEngine, Session) -> Void
    ) {
        AVAudioApplication.requestRecordPermission { [weak self] granted in
            self?.live(pc) { me, s in
                guard granted else {
                    me.fail(s, "microphone access denied")
                    me.onError?("Gecko can't use the microphone. Allow microphone access in Settings to make calls.")
                    return
                }
                body(me, s)
            }
        }
    }

    private nonisolated func createLocal(_ pc: RTCPeerConnection, type: RTCSdpType) {
        let kind = type == .offer ? "offer" : "answer"
        let created: RTCCreateSessionDescriptionCompletionHandler = { [weak self] desc, error in
            self?.live(pc) { me, s in
                guard let desc else {
                    me.fail(s, "could not create \(kind)", error)
                    return
                }
                NSLog("gecko-call: media %d %@ created", s.media, kind)
                me.setLocal(pc, desc)
            }
        }
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        if type == .offer {
            pc.offer(for: constraints, completionHandler: created)
        } else {
            pc.answer(for: constraints, completionHandler: created)
        }
    }

    private nonisolated func setLocal(_ pc: RTCPeerConnection, _ desc: RTCSessionDescription) {
        let sdp = desc.sdp
        pc.setLocalDescription(desc) { [weak self] error in
            self?.live(pc) { me, s in
                if let error {
                    me.fail(s, "local description rejected", error)
                    return
                }
                guard let local = CallSDP.localDescription(sdp: sdp) else {
                    me.fail(s, "no opus audio in local description")
                    return
                }
                s.mid = local.mid
                s.bundle = local.bundle
                s.localSet = true
                NSLog("gecko-call: media %d local description set, mid %@", s.media, local.mid)
                me.events?.media(s.media, localDescription: local)
            }
        }
    }

    private nonisolated func setRemote(
        _ pc: RTCPeerConnection, _ desc: RTCSessionDescription,
        then: (@MainActor (CallEngine, Session) -> Void)? = nil
    ) {
        pc.setRemoteDescription(desc) { [weak self] error in
            self?.live(pc) { me, s in
                if let error {
                    me.fail(s, "remote description rejected", error)
                    return
                }
                NSLog("gecko-call: media %d remote description set", s.media)
                s.remoteSet = true
                Self.add(s.queued, mid: s.mid, to: pc)
                s.queued = []
                then?(me, s)
            }
        }
    }

    private nonisolated static func add(_ candidates: [CallCandidate], mid: String, to pc: RTCPeerConnection) {
        for c in candidates {
            let ice = RTCIceCandidate(sdp: CallSDP.sdpAttribute(for: c), sdpMLineIndex: 0, sdpMid: mid)
            pc.add(ice) { error in
                if let error {
                    NSLog("gecko-call: remote candidate rejected: %@", error.localizedDescription)
                }
            }
        }
    }

    private nonisolated static func logPackets(of pc: RTCPeerConnection) {
        pc.statistics { report in
            var received = 0
            var sent = 0
            for stat in report.statistics.values {
                switch stat.type {
                case "inbound-rtp":
                    received += (stat.values["packetsReceived"] as? NSNumber)?.intValue ?? 0
                case "outbound-rtp":
                    sent += (stat.values["packetsSent"] as? NSNumber)?.intValue ?? 0
                default:
                    break
                }
            }
            NSLog("gecko-call: stats in=%ld out=%ld", received, sent)
        }
    }
}

extension CallEngine: RTCPeerConnectionDelegate {
    nonisolated func peerConnection(_ pc: RTCPeerConnection, didChange newState: RTCPeerConnectionState) {
        live(pc) { me, s in
            me.changed(s, newState)
        }
    }

    nonisolated func peerConnection(_ pc: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        let sdp = candidate.sdp
        live(pc) { me, s in
            // nil for TCP candidates, which the ICE-UDP transport cannot carry.
            guard let c = CallSDP.candidate(sdpAttribute: sdp) else { return }
            me.events?.media(s.media, localCandidate: c)
        }
    }

    // Required by the protocol; nothing here is used by an audio-only call.
    nonisolated func peerConnection(_ pc: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    nonisolated func peerConnection(_ pc: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    nonisolated func peerConnection(_ pc: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    nonisolated func peerConnectionShouldNegotiate(_ pc: RTCPeerConnection) {}
    nonisolated func peerConnection(_ pc: RTCPeerConnection, didChange newState: RTCIceConnectionState) {}
    nonisolated func peerConnection(_ pc: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    nonisolated func peerConnection(_ pc: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    nonisolated func peerConnection(_ pc: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
}

/// A loopback UDP hop in front of one TURN server, running a `TurnAuthShim`
/// for each socket WebRTC allocates from.
final class TurnShimProxy: @unchecked Sendable {
    private final class Flow: @unchecked Sendable {
        private let client: NWConnection
        private let server: NWConnection
        /// Touched on the proxy's queue only.
        private var shim: TurnAuthShim

        init(client: NWConnection, server: NWConnection, shim: TurnAuthShim) {
            self.client = client
            self.server = server
            self.shim = shim
        }

        func start(on queue: DispatchQueue) {
            client.start(queue: queue)
            server.start(queue: queue)
            pump(client, fromClient: true)
            pump(server, fromClient: false)
        }

        func cancel() {
            client.cancel()
            server.cancel()
        }

        private func pump(_ from: NWConnection, fromClient: Bool) {
            from.receiveMessage { [weak self] data, _, _, error in
                guard let self else { return }
                if let data, !data.isEmpty {
                    switch fromClient ? shim.fromClient(data) : shim.fromServer(data) {
                    case .toClient(let reply): client.send(content: reply, completion: .idempotent)
                    case .toServer(let request): server.send(content: request, completion: .idempotent)
                    }
                }
                if error == nil { pump(from, fromClient: fromClient) }
            }
        }
    }

    private(set) var port: UInt16 = 0
    private let listener: NWListener
    private let queue = DispatchQueue(label: "gecko.turn-shim")
    /// Touched on `queue` only.
    private var flows: [Flow] = []

    /// nil when the loopback port cannot be opened; the call then uses the
    /// server directly.
    init?(host: String, port serverPort: UInt16, username: String, password: String) {
        let local = NWParameters.udp
        local.requiredInterfaceType = .loopback
        guard let listener = try? NWListener(using: local),
              let serverPort = NWEndpoint.Port(rawValue: serverPort) else { return nil }
        self.listener = listener
        let opened = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready, .failed, .cancelled: opened.signal()
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] client in
            guard let self else { return client.cancel() }
            let flow = Flow(
                client: client,
                server: NWConnection(host: NWEndpoint.Host(host), port: serverPort, using: .udp),
                shim: TurnAuthShim(username: username, password: password))
            flows.append(flow)
            flow.start(on: queue)
        }
        listener.start(queue: queue)
        // ponytail: the port is known a moment after start, and WebRTC's
        // configuration wants it now, so the caller waits for it.
        guard opened.wait(timeout: .now() + 1) == .success, let port = listener.port?.rawValue else {
            listener.cancel()
            return nil
        }
        self.port = port
    }

    func stop() {
        queue.async { [self] in
            listener.cancel()
            flows.forEach { $0.cancel() }
            flows = []
        }
    }
}
