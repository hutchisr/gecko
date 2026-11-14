import Foundation
import Network

/// A byte pipe to one XMPP server. TLS certificates are checked against the
/// XMPP domain, not the host an SRV record pointed at (RFC 7590 §3.2).
protocol XMPPTransport: AnyObject {
    /// Bytes as they arrive; finishes when the server closes, throws on failure.
    var incoming: AsyncThrowingStream<Data, Error> { get }
    func send(_ data: Data)
    /// Switches to TLS in place after `<proceed/>` (STARTTLS).
    func startTLS() async throws
    func close()
}

enum XMPPTransportError: Error, Equatable {
    case connectFailed(String)
    case tlsFailed(String)
    case closed
}

/// Opens the transport an endpoint asks for: Network.framework for direct TLS,
/// Foundation streams for STARTTLS (Network.framework cannot add TLS to an open
/// connection).
enum XMPPTransports {
    static func connect(_ endpoint: XMPPEndpoint, domain: String, timeout: TimeInterval = 15) async throws
        -> XMPPTransport {
        if endpoint.directTLS {
            return try await DirectTLSTransport.connect(endpoint, domain: domain, timeout: timeout)
        }
        return try await StartTLSTransport.connect(endpoint, domain: domain, timeout: timeout)
    }
}

// MARK: Direct TLS (XEP-0368)

final class DirectTLSTransport: XMPPTransport, @unchecked Sendable {
    let incoming: AsyncThrowingStream<Data, Error>
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "gecko.xmpp.tls")

    private init(_ connection: NWConnection) {
        self.connection = connection
        (incoming, continuation) = AsyncThrowingStream.makeStream()
    }

    static func connect(_ endpoint: XMPPEndpoint, domain: String, timeout: TimeInterval) async throws
        -> DirectTLSTransport {
        let tls = NWProtocolTLS.Options()
        let options = tls.securityProtocolOptions
        sec_protocol_options_set_tls_server_name(options, domain)
        sec_protocol_options_add_tls_application_protocol(options, "xmpp-client")
        sec_protocol_options_set_verify_block(options, { _, trust, complete in
            let trust = sec_trust_copy_ref(trust).takeRetainedValue()
            SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, domain as CFString))
            SecTrustEvaluateAsyncWithError(trust, .global()) { _, ok, _ in complete(ok) }
        }, .global())
        let parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        guard let port = NWEndpoint.Port(rawValue: endpoint.port) else {
            throw XMPPTransportError.connectFailed("bad port")
        }
        let transport = DirectTLSTransport(NWConnection(host: .init(endpoint.host), port: port, using: parameters))
        try await transport.start(timeout: timeout)
        return transport
    }

    private func start(timeout: TimeInterval) async throws {
        try await withCheckedThrowingContinuation { (started: CheckedContinuation<Void, Error>) in
            // Every handler below runs on `queue`, so the pending start is
            // only ever touched there.
            final class Pending: @unchecked Sendable { var start: CheckedContinuation<Void, Error>? }
            let pending = Pending()
            pending.start = started
            let finish: (Result<Void, Error>) -> Void = { result in
                pending.start?.resume(with: result)
                pending.start = nil
            }
            connection.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    finish(.success(()))
                    self?.receive()
                case .waiting(let error), .failed(let error):
                    if pending.start != nil {
                        let tls = if case .tls = error { true } else { false }
                        finish(.failure(tls ? XMPPTransportError.tlsFailed("\(error)")
                                            : XMPPTransportError.connectFailed("\(error)")))
                        self?.connection.cancel()
                    } else {
                        self?.continuation.finish(throwing: XMPPTransportError.connectFailed("\(error)"))
                    }
                case .cancelled:
                    finish(.failure(XMPPTransportError.closed))
                    self?.continuation.finish()
                default:
                    break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard pending.start != nil else { return }
                finish(.failure(XMPPTransportError.connectFailed("timed out")))
                self?.connection.cancel()
            }
        }
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, done, error in
            guard let self else { return }
            if let data, !data.isEmpty { continuation.yield(data) }
            if let error {
                continuation.finish(throwing: XMPPTransportError.connectFailed("\(error)"))
            } else if done {
                continuation.finish()
            } else {
                receive()
            }
        }
    }

    func send(_ data: Data) {
        connection.send(content: data, completion: .idempotent)
    }

    func startTLS() async throws {
        // Already encrypted; a server asking again is misbehaving.
        throw XMPPTransportError.tlsFailed("already TLS")
    }

    /// Ends the connection once what was sent before (a closing
    /// `</stream:stream>` above all) has gone out; cancelling at once can drop it.
    func close() {
        connection.send(content: nil, contentContext: .finalMessage, isComplete: true,
                        completion: .contentProcessed { [connection] _ in connection.cancel() })
    }
}

// MARK: STARTTLS

/// Foundation streams scheduled on a private queue; TLS is switched on in
/// place when negotiation reaches `<proceed/>`.
final class StartTLSTransport: NSObject, XMPPTransport, StreamDelegate, @unchecked Sendable {
    let incoming: AsyncThrowingStream<Data, Error>
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private let input: InputStream
    private let output: OutputStream
    private let domain: String
    private let queue = DispatchQueue(label: "gecko.xmpp.starttls")
    /// Touched on `queue` only.
    private var outbox = Data()
    private var opened: CheckedContinuation<Void, Error>?
    private var secured: CheckedContinuation<Void, Error>?
    private var tlsRequested = false

    private init(input: InputStream, output: OutputStream, domain: String) {
        self.input = input
        self.output = output
        self.domain = domain
        (incoming, continuation) = AsyncThrowingStream.makeStream()
    }

    static func connect(_ endpoint: XMPPEndpoint, domain: String, timeout: TimeInterval) async throws
        -> StartTLSTransport {
        var input: InputStream?
        var output: OutputStream?
        Stream.getStreamsToHost(withName: endpoint.host, port: Int(endpoint.port),
                                inputStream: &input, outputStream: &output)
        guard let input, let output else { throw XMPPTransportError.connectFailed("no streams") }
        let transport = StartTLSTransport(input: input, output: output, domain: domain)
        try await transport.open(timeout: timeout)
        return transport
    }

    private func open(timeout: TimeInterval) async throws {
        try await withCheckedThrowingContinuation { (started: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                opened = started
                for stream in [input, output] as [Stream] { stream.delegate = self }
                CFReadStreamSetDispatchQueue(input, queue)
                CFWriteStreamSetDispatchQueue(output, queue)
                input.open()
                output.open()
                queue.asyncAfter(deadline: .now() + timeout) { [self] in
                    guard let opened else { return }
                    self.opened = nil
                    opened.resume(throwing: XMPPTransportError.connectFailed("timed out"))
                    close()
                }
            }
        }
    }

    func send(_ data: Data) {
        queue.async { [self] in
            outbox.append(data)
            flush()
        }
    }

    func startTLS() async throws {
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                secured = done
                tlsRequested = true
                let settings: [String: Any] = [kCFStreamSSLPeerName as String: domain]
                let key = Stream.PropertyKey(kCFStreamPropertySSLSettings as String)
                input.setProperty(settings, forKey: key)
                output.setProperty(settings, forKey: key)
                // The handshake runs on the next read or write; the first
                // bytes after it are the new stream header we send.
                done.resume()
                secured = nil
            }
        }
    }

    func close() {
        queue.async { [self] in
            input.close()
            output.close()
            continuation.finish()
        }
    }

    private func flush() {
        while !outbox.isEmpty, output.hasSpaceAvailable {
            let written = outbox.withUnsafeBytes { buffer in
                output.write(buffer.bindMemory(to: UInt8.self).baseAddress!, maxLength: buffer.count)
            }
            guard written > 0 else { return }
            outbox.removeFirst(written)
        }
    }

    func stream(_ stream: Stream, handle event: Stream.Event) {
        switch event {
        case .openCompleted where stream === output:
            opened?.resume()
            opened = nil
        case .hasBytesAvailable:
            var buffer = [UInt8](repeating: 0, count: 65_536)
            while input.hasBytesAvailable {
                let count = input.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                continuation.yield(Data(buffer[0..<count]))
            }
        case .hasSpaceAvailable:
            flush()
        case .errorOccurred:
            let error = stream.streamError.map { "\($0)" } ?? "stream error"
            let failure = tlsRequested ? XMPPTransportError.tlsFailed(error) : XMPPTransportError.connectFailed(error)
            if let opened {
                self.opened = nil
                opened.resume(throwing: failure)
            }
            continuation.finish(throwing: failure)
        case .endEncountered:
            continuation.finish()
        default:
            break
        }
    }
}
