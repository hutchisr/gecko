import CryptoKit
import XCTest
@testable import GeckoKit

final class TurnAuthShimTests: XCTestCase {
    private let cookie: [UInt8] = [0x21, 0x12, 0xA4, 0x42]

    private func attribute(_ type: UInt16, _ value: [UInt8]) -> [UInt8] {
        [UInt8(type >> 8), UInt8(type & 0xFF), 0, UInt8(value.count)] + value
            + [UInt8](repeating: 0, count: (4 - value.count % 4) % 4)
    }

    private func message(_ type: UInt16, transaction: UInt8, _ attributes: [UInt8] = []) -> Data {
        Data([UInt8(type >> 8), UInt8(type & 0xFF), 0, UInt8(attributes.count)] + cookie
            + [UInt8](repeating: transaction, count: 12) + attributes)
    }

    /// The check WebRTC makes: the last attribute is an HMAC-SHA1, keyed with
    /// MD5(user:realm:password), over everything before it.
    private func isSigned(_ message: Data, user: String, password: String) -> Bool {
        let bytes = [UInt8](message)
        guard bytes.count >= 44, Array(bytes[(bytes.count - 24)..<(bytes.count - 20)]) == [0, 8, 0, 20],
              Int(bytes[2]) << 8 | Int(bytes[3]) == bytes.count - 20 else { return false }
        let key = SymmetricKey(data: Insecure.MD5.hash(data: Data("\(user):\(TurnAuthShim.realm):\(password)".utf8)))
        return HMAC<Insecure.SHA1>.isValidAuthenticationCode(
            Data(bytes.suffix(20)), authenticating: Data(bytes.dropLast(24)), using: key)
    }

    func testServerThatGrantsWithoutAChallengeIsMadeToLookAuthenticated() {
        var shim = TurnAuthShim(username: "1794624827", password: "secret")
        let relayed = attribute(0x0016, [0, 1, 0xFE, 0x12, 0x36, 0xAD, 0x6D, 0x0A])
        let fingerprint = attribute(0x8028, [1, 2, 3, 4])

        // The first Allocate goes out as it is; the server grants it outright.
        let allocate = message(0x0003, transaction: 1, attribute(0x0019, [17, 0, 0, 0]))
        XCTAssertEqual(shim.fromClient(allocate), .toServer(allocate))
        guard case .toClient(let challenge) = shim.fromServer(message(0x0103, transaction: 1, relayed + fingerprint))
        else { return XCTFail("the grant must not reach the server") }
        XCTAssertEqual([UInt8](challenge.prefix(2)), [0x01, 0x13])
        XCTAssertEqual([UInt8](challenge[8..<20]), [UInt8](repeating: 1, count: 12))
        XCTAssertNotNil(challenge.range(of: Data([0, 0, 4, 1])), "401")
        XCTAssertNotNil(challenge.range(of: Data(TurnAuthShim.realm.utf8)))

        // The signed repeat is answered with that grant; the server never sees it.
        let signed = message(0x0003, transaction: 2, attribute(0x0008, [UInt8](repeating: 9, count: 20)))
        guard case .toClient(let granted) = shim.fromClient(signed) else { return XCTFail("a second Allocate reached the server") }
        XCTAssertEqual([UInt8](granted.prefix(2)), [0x01, 0x03])
        XCTAssertEqual([UInt8](granted[8..<20]), [UInt8](repeating: 2, count: 12))
        XCTAssertEqual([UInt8](granted[20..<32]), relayed)
        XCTAssertTrue(isSigned(granted, user: "1794624827", password: "secret"))
        XCTAssertFalse(isSigned(granted, user: "1794624827", password: "other"))

        // Later responses are signed; requests, indications and channel data pass.
        let permission = message(0x0008, transaction: 3, attribute(0x0008, [UInt8](repeating: 9, count: 20)))
        XCTAssertEqual(shim.fromClient(permission), .toServer(permission))
        guard case .toClient(let permitted) = shim.fromServer(message(0x0108, transaction: 3))
        else { return XCTFail("a response went to the server") }
        XCTAssertTrue(isSigned(permitted, user: "1794624827", password: "secret"))
        let indication = message(0x0017, transaction: 4, relayed)
        XCTAssertEqual(shim.fromServer(indication), .toClient(indication))
        let channelData = Data([0x40, 0x00, 0x00, 0x02, 0xAB, 0xCD])
        XCTAssertEqual(shim.fromServer(channelData), .toClient(channelData))
        XCTAssertEqual(shim.fromClient(channelData), .toServer(channelData))
    }

    func testServerThatChallengesIsLeftAlone() {
        var shim = TurnAuthShim(username: "user", password: "secret")
        let allocate = message(0x0003, transaction: 1)
        XCTAssertEqual(shim.fromClient(allocate), .toServer(allocate))
        let challenge = message(0x0113, transaction: 1, attribute(0x0009, [0, 0, 4, 1]))
        XCTAssertEqual(shim.fromServer(challenge), .toClient(challenge))

        let signed = message(0x0003, transaction: 2, attribute(0x0008, [UInt8](repeating: 9, count: 20)))
        XCTAssertEqual(shim.fromClient(signed), .toServer(signed))
        let success = message(0x0103, transaction: 2, attribute(0x0008, [UInt8](repeating: 7, count: 20)))
        XCTAssertEqual(shim.fromServer(success), .toClient(success))
        let unsigned = message(0x0108, transaction: 3)
        XCTAssertEqual(shim.fromServer(unsigned), .toClient(unsigned))
    }

    func testUdpTurnAddress() {
        let v4 = CallIceServer(urls: "turn:turn.example.org:3478?transport=udp", username: "u", credential: "p")
        XCTAssertEqual(v4.udpTurn?.host, "turn.example.org")
        XCTAssertEqual(v4.udpTurn?.port, 3478)
        XCTAssertEqual(CallIceServer(urls: "turn:[2001:db8::1]:3479?transport=udp", username: nil, credential: nil)
            .udpTurn?.host, "2001:db8::1")
        XCTAssertNil(CallIceServer(urls: "turn:turn.example.org:3478?transport=tcp", username: nil, credential: nil).udpTurn)
        XCTAssertNil(CallIceServer(urls: "stun:turn.example.org:3478", username: nil, credential: nil).udpTurn)
    }
}
