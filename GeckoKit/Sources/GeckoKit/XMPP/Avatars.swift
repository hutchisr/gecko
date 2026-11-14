import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum AvatarNS {
    static let pubsub = "http://jabber.org/protocol/pubsub"
    static let metadata = "urn:xmpp:avatar:metadata"
    static let data = "urn:xmpp:avatar:data"
    static let vcard = "vcard-temp"
    static let blocking = "urn:xmpp:blocking"
    static let register = "jabber:iq:register"
}

/// User avatars: PEP (XEP-0084) first, vCard-temp (XEP-0153) as the fallback,
/// both keyed by the SHA-1 of the image bytes.
enum Avatars {
    static func sha1(_ data: Data) -> String {
        Insecure.SHA1.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// The id of the current avatar in a metadata items result; "" when the
    /// contact removed theirs; nil when there is no metadata.
    static func metadataID(_ iq: StanzaNode) -> String? {
        guard let item = iq.child("pubsub", AvatarNS.pubsub)?.child("items", AvatarNS.pubsub)?
            .children("item", AvatarNS.pubsub).last,
              let metadata = item.child("metadata", AvatarNS.metadata) else { return nil }
        return metadata.children("info", AvatarNS.metadata).first?["id"]?.lowercased() ?? ""
    }

    /// The image of a data items result, only when it hashes to `id`.
    static func data(_ iq: StanzaNode, id: String) -> Data? {
        guard let text = iq.child("pubsub", AvatarNS.pubsub)?.child("items", AvatarNS.pubsub)?
            .children("item", AvatarNS.pubsub).first(where: { $0["id"]?.lowercased() == id })?
            .child("data", AvatarNS.data)?.text,
              let image = Data(base64Encoded: text, options: .ignoreUnknownCharacters),
              sha1(image) == id else { return nil }
        return image
    }

    /// The photo of a vCard result.
    static func vcardPhoto(_ iq: StanzaNode) -> Data? {
        guard let text = iq.child("vCard", AvatarNS.vcard)?.child("PHOTO", AvatarNS.vcard)?
            .child("BINVAL", AvatarNS.vcard)?.text else { return nil }
        return Data(base64Encoded: text, options: .ignoreUnknownCharacters)
    }

    /// A square-bounded PNG of at most `side` pixels, for publishing.
    static func scaledPNG(_ file: URL, side: Int = 192) -> (png: Data, width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: side,
              ] as CFDictionary) else { return nil }
        let png = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(png, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return (png as Data, image.width, image.height)
    }

    /// The two PEP publishes for our own avatar: the image, then the
    /// metadata pointing at it (XEP-0084 §4.1).
    static func publish(png: Data, width: Int, height: Int) -> [StanzaNode] {
        let id = sha1(png)
        func publish(_ node: String, _ payload: StanzaNode) -> StanzaNode {
            StanzaNode("iq", XMPPNS.client, ["type": "set", "id": "avatar-\(node.suffix(4))-\(id.prefix(8))"], [
                StanzaNode("pubsub", AvatarNS.pubsub, [:], [
                    StanzaNode("publish", AvatarNS.pubsub, ["node": node], [
                        StanzaNode("item", AvatarNS.pubsub, ["id": id], [payload]),
                    ]),
                ]),
            ])
        }
        return [
            publish(AvatarNS.data, StanzaNode("data", AvatarNS.data, text: png.base64EncodedString())),
            publish(AvatarNS.metadata, StanzaNode("metadata", AvatarNS.metadata, [:], [
                StanzaNode("info", AvatarNS.metadata, ["id": id, "bytes": String(png.count), "type": "image/png",
                                                       "width": String(width), "height": String(height)]),
            ])),
        ]
    }

    static func itemsQuery(_ node: String, to jid: String, id: String, item: String? = nil) -> StanzaNode {
        let items = StanzaNode("items", AvatarNS.pubsub, item == nil ? ["node": node, "max_items": "1"] : ["node": node],
                               item.map { [StanzaNode("item", AvatarNS.pubsub, ["id": $0])] } ?? [])
        return StanzaNode("iq", XMPPNS.client, ["type": "get", "to": jid, "id": id],
                          [StanzaNode("pubsub", AvatarNS.pubsub, [:], [items])])
    }
}

/// An OMEMO identity key shown to people: hex without the key-type byte,
/// in groups of eight (the same form the Vala core showed).
func omemoFingerprint(_ publicKey: Data) -> String {
    let hex = publicKey.dropFirst().map { String(format: "%02x", $0) }.joined()
    return stride(from: 0, to: hex.count, by: 8).map {
        let start = hex.index(hex.startIndex, offsetBy: $0)
        return String(hex[start..<hex.index(start, offsetBy: min(8, hex.count - $0))])
    }.joined(separator: " ")
}
