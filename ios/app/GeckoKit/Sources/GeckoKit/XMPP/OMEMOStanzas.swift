import CryptoKit
import Foundation

/// Legacy OMEMO's stanzas (XEP-0384 v0.3, eu.siacs.conversations.axolotl):
/// device lists, bundles and encrypted messages.
enum OMEMOStanzas {
    static let ns = ChatNS.omemo
    static let deviceList = "\(ns).devicelist"
    static func bundleNode(_ device: UInt32) -> String { "\(ns).bundles:\(device)" }

    static let fallback = "I sent you an OMEMO encrypted message but your client doesn’t seem to support that."

    // MARK: Device lists and bundles

    /// The device ids of a device-list items result or notification.
    static func devices(_ node: StanzaNode) -> [UInt32]? {
        let items = node.child("pubsub", AvatarNS.pubsub)?.child("items", AvatarNS.pubsub)
            ?? node.child("event", "\(AvatarNS.pubsub)#event")?.child("items", "\(AvatarNS.pubsub)#event")
        guard let list = items?.children.last?.child("list", ns) else { return nil }
        return list.children("device", ns).compactMap { $0["id"].flatMap(UInt32.init) }.filter { $0 != 0 }
    }

    static func bundle(_ node: StanzaNode) -> OMEMOSession.Bundle? {
        guard let bundle = node.child("pubsub", AvatarNS.pubsub)?.child("items", AvatarNS.pubsub)?
            .children.last?.child("bundle", ns),
              let signed = bundle.child("signedPreKeyPublic", ns),
              let signedID = signed["signedPreKeyId"].flatMap(UInt32.init),
              let signedKey = base64(signed.text),
              let signature = bundle.child("signedPreKeySignature", ns).flatMap({ base64($0.text) }),
              let identity = bundle.child("identityKey", ns).flatMap({ base64($0.text) }) else { return nil }
        var preKeys: [UInt32: Data] = [:]
        for preKey in bundle.child("prekeys", ns)?.children("preKeyPublic", ns) ?? [] {
            if let id = preKey["preKeyId"].flatMap(UInt32.init), let key = base64(preKey.text) { preKeys[id] = key }
        }
        return OMEMOSession.Bundle(identityKey: identity, signedPreKeyID: signedID, signedPreKey: signedKey,
                                   signature: signature, preKeys: preKeys)
    }

    /// Publishing a node others must be able to read without being our
    /// contact (Conversations refuses closed bundles): access model open.
    static func publish(_ node: String, item: String, _ payload: StanzaNode, id: String) -> StanzaNode {
        let form = StanzaNode("x", "jabber:x:data", ["type": "submit"], [
            StanzaNode("field", "jabber:x:data", ["var": "FORM_TYPE", "type": "hidden"],
                       [StanzaNode("value", "jabber:x:data", text: "\(AvatarNS.pubsub)#publish-options")]),
            StanzaNode("field", "jabber:x:data", ["var": "pubsub#access_model"],
                       [StanzaNode("value", "jabber:x:data", text: "open")]),
        ])
        return StanzaNode("iq", XMPPNS.client, ["type": "set", "id": id], [
            StanzaNode("pubsub", AvatarNS.pubsub, [:], [
                StanzaNode("publish", AvatarNS.pubsub, ["node": node],
                           [StanzaNode("item", AvatarNS.pubsub, ["id": item], [payload])]),
                StanzaNode("publish-options", AvatarNS.pubsub, [:], [form]),
            ]),
        ])
    }

    static func deviceListPayload(_ devices: [UInt32]) -> StanzaNode {
        StanzaNode("list", ns, [:], devices.map { StanzaNode("device", ns, ["id": String($0)]) })
    }

    static func bundlePayload(_ bundle: OMEMOSession.Bundle) -> StanzaNode {
        StanzaNode("bundle", ns, [:], [
            StanzaNode("signedPreKeyPublic", ns, ["signedPreKeyId": String(bundle.signedPreKeyID)],
                       text: bundle.signedPreKey.base64EncodedString()),
            StanzaNode("signedPreKeySignature", ns, text: bundle.signature.base64EncodedString()),
            StanzaNode("identityKey", ns, text: bundle.identityKey.base64EncodedString()),
            StanzaNode("prekeys", ns, [:], bundle.preKeys.sorted { $0.key < $1.key }.map {
                StanzaNode("preKeyPublic", ns, ["preKeyId": String($0.key)], text: $0.value.base64EncodedString())
            }),
        ])
    }

    // MARK: Messages

    /// A body sealed for sending: the payload and the 32 bytes (AES key and
    /// GCM tag) each recipient device gets through its Signal session.
    struct Sealed {
        let payload: Data
        let iv: Data
        let keyMaterial: Data
    }

    static func seal(_ body: String) throws -> Sealed {
        let key = SymmetricKey(size: .bits128)
        let nonce = AES.GCM.Nonce()
        let box = try AES.GCM.seal(Data(body.utf8), using: key, nonce: nonce)
        return Sealed(payload: Data(box.ciphertext), iv: Data(nonce),
                      keyMaterial: key.withUnsafeBytes { Data($0) } + box.tag)
    }

    /// The `<encrypted/>` element, with an EME hint and the fallback body
    /// for clients without OMEMO.
    static func encrypted(from device: UInt32, iv: Data, payload: Data?,
                          keys: [(device: UInt32, data: Data, preKey: Bool)]) -> [StanzaNode] {
        var header = keys.map { key in
            var attributes = ["rid": String(key.device)]
            if key.preKey { attributes["prekey"] = "true" }
            return StanzaNode("key", ns, attributes, text: key.data.base64EncodedString())
        }
        header.append(StanzaNode("iv", ns, text: iv.base64EncodedString()))
        var encrypted = [StanzaNode("header", ns, ["sid": String(device)], header)]
        if let payload { encrypted.append(StanzaNode("payload", ns, text: payload.base64EncodedString())) }
        var nodes = [StanzaNode("encrypted", ns, [:], encrypted), StanzaNode("store", ChatNS.hints)]
        if payload != nil {
            nodes.append(StanzaNode("encryption", "urn:xmpp:eme:0", ["namespace": ns, "name": "OMEMO"]))
            nodes.append(StanzaNode("body", XMPPNS.client, text: fallback))
        }
        return nodes
    }

    /// What a received `<encrypted/>` holds for one of our devices.
    struct Received: Equatable {
        let sender: UInt32
        let key: Data
        let preKey: Bool
        let iv: Data
        let payload: Data?
    }

    /// `encrypted`: the `<encrypted/>` element of the (unwrapped) message.
    static func received(_ encrypted: StanzaNode, for device: UInt32) -> Received? {
        guard encrypted.name == "encrypted", encrypted.ns == ns, let header = encrypted.child("header", ns),
              let sender = header["sid"].flatMap(UInt32.init),
              let iv = header.child("iv", ns).flatMap({ base64($0.text) }),
              let key = header.children("key", ns).first(where: { $0["rid"].flatMap(UInt32.init) == device }),
              let keyData = base64(key.text) else { return nil }
        let preKey = key["prekey"] == "true" || key["prekey"] == "1"
        return Received(sender: sender, key: keyData, preKey: preKey, iv: iv,
                        payload: encrypted.child("payload", ns).flatMap { base64($0.text) })
    }

    /// Opens a payload with the decrypted key material: 16 bytes of key and
    /// the 16-byte tag (as sent now), or the key alone with the tag at the
    /// payload's end (as some older clients did).
    static func open(_ payload: Data, iv: Data, keyMaterial: Data) throws -> String {
        let key: Data, sealed: Data
        if keyMaterial.count >= 32 {
            key = keyMaterial.prefix(16)
            sealed = payload + keyMaterial.dropFirst(16).prefix(16)
        } else {
            key = keyMaterial.prefix(16)
            sealed = payload
        }
        guard sealed.count >= 16 else { throw OMEMOError(code: -1, step: "payload too short") }
        let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: iv), ciphertext: sealed.dropLast(16),
                                        tag: sealed.suffix(16))
        let plain = try AES.GCM.open(box, using: SymmetricKey(data: key))
        guard let text = String(data: plain, encoding: .utf8) else { throw OMEMOError(code: -1, step: "not UTF-8") }
        return text
    }

    private static func base64(_ text: String) -> Data? {
        Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines), options: .ignoreUnknownCharacters)
    }
}
