import CryptoKit
import Foundation

/// Files go through the server (HTTP File Upload, XEP-0363); in OMEMO chats
/// they are encrypted first and shared as an `aesgcm://` link whose fragment
/// holds the IV and key (the convention OMEMO clients share).
enum FileSharing {
    static let upload = "urn:xmpp:http:upload:0"

    /// The upload service's size limit, from its disco#info; nil when the
    /// reply is not an upload service's.
    static func maxSize(_ info: StanzaNode) -> Int64?? {
        guard let query = info.child("query", Disco.info),
              query.children("feature", Disco.info).contains(where: { $0["var"] == upload }) else { return nil }
        for form in query.children("x", "jabber:x:data") {
            let fields = form.children("field", "jabber:x:data")
            guard fields.contains(where: { $0["var"] == "FORM_TYPE" && $0.child("value", "jabber:x:data")?.text == upload })
            else { continue }
            let limit = fields.first { $0["var"] == "max-file-size" }?.child("value", "jabber:x:data")?.text
            return .some(limit.flatMap(Int64.init))
        }
        return .some(nil)
    }

    struct Slot: Equatable {
        let put: URL
        let get: URL
        /// The only headers XEP-0363 lets the service hand us.
        let headers: [String: String]
    }

    static func slotRequest(to service: String, name: String, size: Int64, type: String, id: String) -> StanzaNode {
        StanzaNode("iq", XMPPNS.client, ["type": "get", "to": service, "id": id], [
            StanzaNode("request", upload, ["filename": name, "size": String(size), "content-type": type]),
        ])
    }

    static func slot(_ reply: StanzaNode) -> Slot? {
        guard let slot = reply.child("slot", upload), let put = slot.child("put", upload),
              let putURL = put["url"].flatMap(URL.init(string:)), putURL.scheme == "https",
              let getURL = slot.child("get", upload)?["url"].flatMap(URL.init(string:)), getURL.scheme == "https"
        else { return nil }
        var headers: [String: String] = [:]
        for header in put.children("header", upload) {
            guard let name = header["name"], ["authorization", "cookie", "expires"].contains(name.lowercased()) else { continue }
            headers[name] = header.text.replacingOccurrences(of: "\n", with: "")
        }
        return Slot(put: putURL, get: getURL, headers: headers)
    }

    // MARK: Encrypted files

    struct Secret: Equatable {
        let key: Data
        let iv: Data
    }

    static func encrypt(_ data: Data) throws -> (sealed: Data, secret: Secret) {
        let key = SymmetricKey(size: .bits256)
        let nonce = AES.GCM.Nonce()
        let box = try AES.GCM.seal(data, using: key, nonce: nonce)
        // A fresh, zero-based copy: CryptoKit's ciphertext is a slice of its buffer.
        return (Data(box.ciphertext) + box.tag, Secret(key: key.withUnsafeBytes { Data($0) }, iv: Data(nonce)))
    }

    static func decrypt(_ sealed: Data, _ secret: Secret) throws -> Data {
        guard sealed.count >= 16 else { throw OMEMOError(code: -1, step: "file too short") }
        let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: secret.iv), ciphertext: sealed.dropLast(16),
                                        tag: sealed.suffix(16))
        return try AES.GCM.open(box, using: SymmetricKey(data: secret.key))
    }

    /// `aesgcm://host/path#<IV><key>` for an uploaded `https://host/path`.
    static func aesgcmLink(_ url: URL, _ secret: Secret) -> String {
        let link = url.absoluteString.replacingOccurrences(of: "https://", with: "aesgcm://", options: .anchored)
        return link + "#" + (secret.iv + secret.key).map { String(format: "%02x", $0) }.joined()
    }

    /// The https URL and secret of an `aesgcm://` link: a 12- or 16-byte IV
    /// followed by a 32-byte key.
    static func parseAesgcm(_ link: String) -> (url: URL, secret: Secret)? {
        guard link.hasPrefix("aesgcm://"), let hash = link.firstIndex(of: "#") else { return nil }
        let hex = String(link[link.index(after: hash)...])
        guard hex.count == 88 || hex.count == 96, let bytes = Data(hex: hex),
              let url = URL(string: "https://" + link.dropFirst("aesgcm://".count).prefix(upTo: hash).description)
        else { return nil }
        let ivLength = bytes.count - 32
        return (url, Secret(key: bytes.suffix(32), iv: bytes.prefix(ivLength)))
    }

    /// A message that only shares a file: its body is the link (and matches
    /// the out-of-band URL, when there is one).
    static func sharedLink(body: String?, oob: String?) -> String? {
        guard let body = body?.trimmingCharacters(in: .whitespacesAndNewlines), !body.contains(" "),
              !body.contains("\n") else { return nil }
        if body.hasPrefix("aesgcm://"), parseAesgcm(body) != nil { return body }
        if body.hasPrefix("https://"), oob == body { return body }
        return nil
    }

    /// The file name a link shows: its last path component, unescaped.
    static func name(of link: String) -> String {
        let path = link.split(separator: "#").first.map(String.init) ?? link
        let last = URL(string: path.replacingOccurrences(of: "aesgcm://", with: "https://"))?.lastPathComponent
        return last.flatMap { $0.isEmpty ? nil : $0 }?.removingPercentEncoding ?? "file"
    }
}

extension Data {
    init?(hex: String) {
        guard hex.count.isMultiple(of: 2) else { return nil }
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }
}
