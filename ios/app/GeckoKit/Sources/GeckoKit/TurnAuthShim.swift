import CryptoKit
import Foundation

/// Sits between WebRTC's TURN client and one TURN server, for servers that
/// grant requests without authenticating (coturn's `no-auth`, as on
/// turn.xmpp.is). WebRTC discards such grants, so no relay candidate is ever
/// gathered. The shim plays the missing half of the long-term credential
/// exchange (RFC 8489 §9.2): it answers the client's first Allocate with a 401
/// challenge and signs every later response with the key the client derives
/// from that challenge. A server that challenges by itself is passed through
/// untouched.
///
/// The server's replies are trusted as they arrive; that is all such a server
/// offers. Call media is still DTLS-SRTP end to end.
struct TurnAuthShim {
    enum Output: Equatable {
        case toClient(Data)
        case toServer(Data)
    }

    static let realm = "gecko"

    private enum Mode { case undecided, passthrough, signing }
    private var mode = Mode.undecided
    /// MD5(username:realm:password), the long-term credential key.
    private let key: SymmetricKey
    /// The transaction the server granted without a challenge.
    private var unchallenged = Data()
    // ponytail: replayed as received, which holds for IPv4 addresses only (an
    // IPv6 one is masked with the transaction ID); re-mask if such a server
    // is ever reachable over IPv6.
    /// What it granted, replayed when the client repeats the Allocate signed.
    private var grant = Data()

    init(username: String, password: String) {
        key = SymmetricKey(data: Insecure.MD5.hash(data: Data("\(username):\(Self.realm):\(password)".utf8)))
    }

    mutating func fromClient(_ packet: Data) -> Output {
        guard mode == .signing, let m = Message(packet), m.type == Message.allocate,
              m.has(Message.integrity) else { return .toServer(packet) }
        // The server already holds this allocation; a second request for it
        // would be refused as a mismatch.
        return .toClient(Message.build(Message.allocate | Message.success, m.transaction, grant, signedWith: key))
    }

    mutating func fromServer(_ packet: Data) -> Output {
        // Channel data and indications carry no credentials either way.
        guard let m = Message(packet), m.type & Message.success != 0 else { return .toClient(packet) }
        if mode == .undecided, m.type & ~Message.error == Message.allocate {
            if m.type == Message.allocate | Message.success, !m.has(Message.integrity) {
                mode = .signing
                unchallenged = m.transaction
                grant = m.unsignedAttributes
            } else {
                mode = .passthrough
            }
        }
        guard mode == .signing, !m.has(Message.integrity) else { return .toClient(packet) }
        if m.transaction == unchallenged {
            return .toClient(Message.build(Message.allocate | Message.error, m.transaction, Self.challenge))
        }
        return .toClient(Message.build(m.type, m.transaction, m.unsignedAttributes, signedWith: key))
    }

    private static let challenge =
        Message.attribute(0x0009, Data([0, 0, 4, 1]) + Data("Unauthorized".utf8))
        + Message.attribute(0x0014, Data(realm.utf8))
        + Message.attribute(0x0015, Data("gecko-shim".utf8))

    /// A STUN message (RFC 8489 §5), as far as the shim reads one.
    private struct Message {
        static let allocate: UInt16 = 0x0003
        /// Class bits: success is 0x0100, error 0x0110, indication 0x0010.
        static let success: UInt16 = 0x0100
        static let error: UInt16 = 0x0110
        static let integrity: UInt16 = 0x0008
        static let fingerprint: UInt16 = 0x8028
        private static let cookie: [UInt8] = [0x21, 0x12, 0xA4, 0x42]

        let type: UInt16
        let transaction: Data
        private let attributes: [(type: UInt16, bytes: Data)]

        /// nil for channel data and anything else that is not one whole message.
        init?(_ packet: Data) {
            let p = [UInt8](packet)
            guard p.count >= 20, p[0] & 0xC0 == 0, Array(p[4..<8]) == Self.cookie,
                  20 + (Int(p[2]) << 8 | Int(p[3])) == p.count else { return nil }
            type = UInt16(p[0]) << 8 | UInt16(p[1])
            transaction = Data(p[8..<20])
            var found: [(UInt16, Data)] = []
            var i = 20
            while i + 4 <= p.count {
                let length = Int(p[i + 2]) << 8 | Int(p[i + 3])
                let end = i + 4 + (length + 3) / 4 * 4
                guard end <= p.count else { return nil }
                found.append((UInt16(p[i]) << 8 | UInt16(p[i + 1]), Data(p[i..<end])))
                i = end
            }
            attributes = found
        }

        func has(_ attribute: UInt16) -> Bool {
            attributes.contains { $0.type == attribute }
        }

        /// The attributes a signature is appended to: a fingerprint has to
        /// come after it and would no longer match, so it is dropped.
        var unsignedAttributes: Data {
            attributes.filter { $0.type != Self.fingerprint }.reduce(Data()) { $0 + $1.bytes }
        }

        static func attribute(_ type: UInt16, _ value: Data) -> Data {
            Data([UInt8(type >> 8), UInt8(type & 0xFF), UInt8(value.count >> 8), UInt8(value.count & 0xFF)])
                + value + Data(count: (4 - value.count % 4) % 4)
        }

        /// MESSAGE-INTEGRITY is an HMAC-SHA1 over the message up to itself,
        /// with the header already counting it (RFC 8489 §14.5).
        static func build(_ type: UInt16, _ transaction: Data, _ attributes: Data,
                          signedWith key: SymmetricKey? = nil) -> Data {
            let length = attributes.count + (key == nil ? 0 : 24)
            var message = Data([UInt8(type >> 8), UInt8(type & 0xFF), UInt8(length >> 8), UInt8(length & 0xFF)]
                + cookie) + transaction + attributes
            if let key {
                message += attribute(integrity, Data(HMAC<Insecure.SHA1>.authenticationCode(for: message, using: key)))
            }
            return message
        }
    }
}

extension CallIceServer {
    /// Host and port of a `turn:` server reached over UDP, the kind `TurnAuthShim` can front.
    var udpTurn: (host: String, port: UInt16)? {
        guard urls.hasPrefix("turn:"), urls.hasSuffix("?transport=udp") else { return nil }
        let address = urls.dropFirst("turn:".count).dropLast("?transport=udp".count)
        guard let colon = address.lastIndex(of: ":"), let port = UInt16(address[address.index(after: colon)...]) else {
            return nil
        }
        return (address[..<colon].trimmingCharacters(in: CharacterSet(charactersIn: "[]")), port)
    }
}
