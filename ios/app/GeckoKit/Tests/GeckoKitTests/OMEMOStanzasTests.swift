import CryptoKit
import XCTest
@testable import GeckoKit

final class OMEMOStanzasTests: XCTestCase {
    func testEncryptedMessageRoundTripsBetweenTwoAccounts() throws {
        func open(_ account: String) throws -> OMEMOSession {
            let store = try GeckoStore(path: nil)
            try store.addAccount(account, resource: "r")
            return try OMEMOSession(store: store, account: account) { _, _, _ in true }
        }
        let alice = try open("alice@example.org"), bob = try open("bob@example.org")
        // Bob's bundle goes over the wire as XML and comes back intact.
        let published = OMEMOStanzas.publish(OMEMOStanzas.bundleNode(bob.deviceID), item: "current",
                                             OMEMOStanzas.bundlePayload(try bob.bundle()), id: "b")
        let result = StanzaNode("iq", XMPPNS.client, ["type": "result"], [
            StanzaNode("pubsub", AvatarNS.pubsub, [:], [
                StanzaNode("items", AvatarNS.pubsub, [:], published.child("pubsub", AvatarNS.pubsub)!
                    .child("publish", AvatarNS.pubsub)!.children),
            ]),
        ])
        let bundle = try XCTUnwrap(OMEMOStanzas.bundle(try XCTUnwrap(StanzaNode.parse(result.xml))))
        XCTAssertEqual(bundle, try bob.bundle())
        try alice.startSession("bob@example.org", bob.deviceID, bundle: bundle)

        let sealed = try OMEMOStanzas.seal("hej 👋")
        let key = try alice.encrypt(sealed.keyMaterial, for: "bob@example.org", bob.deviceID)
        let message = StanzaNode("message", XMPPNS.client, ["to": "bob@example.org"], OMEMOStanzas.encrypted(
            from: alice.deviceID, iv: sealed.iv, payload: sealed.payload,
            keys: [(bob.deviceID, key.data, key.preKey), (12345, Data([1, 2, 3]), false)]))
        let wire = try XCTUnwrap(StanzaNode.parse(message.xml))
        XCTAssertEqual(wire.child("body", XMPPNS.client)?.text, OMEMOStanzas.fallback)
        XCTAssertFalse(message.xml.contains("hej"), "the text must not be on the wire")

        let received = try XCTUnwrap(OMEMOStanzas.received(try XCTUnwrap(wire.child("encrypted", OMEMOStanzas.ns)), for: bob.deviceID))
        XCTAssertEqual(received.sender, alice.deviceID)
        XCTAssertTrue(received.preKey)
        let material = try bob.decrypt(received.key, preKey: received.preKey, from: "alice@example.org", received.sender)
        XCTAssertEqual(try OMEMOStanzas.open(try XCTUnwrap(received.payload), iv: received.iv, keyMaterial: material),
                       "hej 👋")
        XCTAssertNil(OMEMOStanzas.received(wire.child("encrypted", OMEMOStanzas.ns)!, for: 999), "no key for this device")
    }

    func testOpensTheOlderLayoutWithTheTagOnThePayload() throws {
        let key = SymmetricKey(size: .bits128)
        let nonce = AES.GCM.Nonce()
        let box = try AES.GCM.seal(Data("old".utf8), using: key, nonce: nonce)
        let keyData = key.withUnsafeBytes { Data($0) }
        XCTAssertEqual(try OMEMOStanzas.open(box.ciphertext + box.tag, iv: Data(nonce), keyMaterial: keyData), "old")
        XCTAssertThrowsError(try OMEMOStanzas.open(box.ciphertext + box.tag, iv: Data(nonce),
                                                   keyMaterial: Data(count: 16)), "a wrong key must fail, not garble")
    }

    func testReadsDeviceListsFromResultsAndNotifications() {
        let list = OMEMOStanzas.deviceListPayload([7, 42])
        let result = StanzaNode("iq", XMPPNS.client, [:], [StanzaNode("pubsub", AvatarNS.pubsub, [:], [
            StanzaNode("items", AvatarNS.pubsub, [:], [StanzaNode("item", AvatarNS.pubsub, ["id": "current"], [list])]),
        ])])
        XCTAssertEqual(OMEMOStanzas.devices(result), [7, 42])
        let event = StanzaNode("message", XMPPNS.client, [:], [StanzaNode("event", "\(AvatarNS.pubsub)#event", [:], [
            StanzaNode("items", "\(AvatarNS.pubsub)#event", [:],
                       [StanzaNode("item", "\(AvatarNS.pubsub)#event", [:], [list])]),
        ])])
        XCTAssertEqual(OMEMOStanzas.devices(event), [7, 42])
    }
}
