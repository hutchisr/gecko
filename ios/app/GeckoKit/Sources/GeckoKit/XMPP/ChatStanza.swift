import Foundation

enum ChatNS {
    static let receipts = "urn:xmpp:receipts"
    static let markers = "urn:xmpp:chat-markers:0"
    static let chatStates = "http://jabber.org/protocol/chatstates"
    static let sid = "urn:xmpp:sid:0"
    static let correction = "urn:xmpp:message-correct:0"
    static let reply = "urn:xmpp:reply:0"
    static let reactions = "urn:xmpp:reactions:0"
    static let carbons = "urn:xmpp:carbons:2"
    static let forward = "urn:xmpp:forward:0"
    static let delay = "urn:xmpp:delay"
    static let mam = "urn:xmpp:mam:2"
    static let oob = "jabber:x:oob"
    static let hints = "urn:xmpp:hints"
    static let omemo = "eu.siacs.conversations.axolotl"
    static let roster = "jabber:iq:roster"
}

enum JID {
    static func bare(_ jid: String) -> String {
        String(jid.split(separator: "/", maxSplits: 1).first ?? Substring(jid))
    }

    static func resource(_ jid: String) -> String? {
        let parts = jid.split(separator: "/", maxSplits: 1)
        return parts.count == 2 ? String(parts[1]) : nil
    }

    static func domain(_ jid: String) -> String {
        let bare = bare(jid)
        return String(bare.split(separator: "@", maxSplits: 1).last ?? Substring(bare))
    }
}

/// A `<message/>` as the chat layer reads it, after unwrapping a carbon
/// (XEP-0280) or an archive result (XEP-0313).
struct ChatStanza: Equatable {
    struct Marker: Equatable { let name: String; let id: String }
    struct Reply: Equatable { let jid: String?; let id: String }
    struct Reaction: Equatable { let id: String; let emojis: [String] }

    var from: String
    var to: String
    var type: String
    var id: String?
    var body: String?
    /// The sender's own id (XEP-0359), falling back to the stanza id.
    var originID: String?
    /// The id our archive gave it (XEP-0359 `<stanza-id by=ourBareJID>` or the MAM result id).
    var serverID: String?
    var requestsReceipt = false
    var receiptFor: String?
    var marker: Marker?
    var markable = false
    var chatState: String?
    var replaces: String?
    var replyTo: Reply?
    var reaction: Reaction?
    var url: String?
    var encrypted = false
    /// The OMEMO `<encrypted/>` element, when there is one.
    var omemo: StanzaNode?
    var delay: Date?
    /// A copy of a message one of our other devices sent (carbon or archive).
    var sentByUs = false
    /// Came from the archive, not live.
    var archived = false

    /// Reads a top-level stanza for account `me` (bare JID). Carbons are only
    /// believed from our own bare JID; archive results only from our own
    /// archive (`archive`: the JID queried, nil for our own).
    static func parse(_ node: StanzaNode, me: String, archive: String? = nil) -> ChatStanza? {
        guard node.name == "message", node.ns == XMPPNS.client else { return nil }
        let from = node["from"] ?? me
        if let carbon = node.children.first(where: { $0.ns == ChatNS.carbons && ($0.name == "received" || $0.name == "sent") }) {
            guard JID.bare(from) == me,
                  let inner = carbon.child("forwarded", ChatNS.forward)?.child("message", XMPPNS.client),
                  var parsed = parse(inner, me: me) else { return nil }
            parsed.sentByUs = carbon.name == "sent"
            return parsed
        }
        if let result = node.child("result", ChatNS.mam) {
            guard JID.bare(from) == (archive ?? me) || node["from"] == nil,
                  let forwarded = result.child("forwarded", ChatNS.forward),
                  let inner = forwarded.child("message", XMPPNS.client),
                  var parsed = parse(inner, me: me) else { return nil }
            parsed.archived = true
            parsed.serverID = result["id"]
            parsed.delay = forwarded.child("delay", ChatNS.delay)?["stamp"].flatMap(Self.date) ?? parsed.delay
            parsed.sentByUs = JID.bare(parsed.from) == me
            return parsed
        }
        var m = ChatStanza(from: from, to: node["to"] ?? me, type: node["type"] ?? "normal", id: node["id"])
        m.body = node.child("body", XMPPNS.client)?.text
        m.originID = node.child("origin-id", ChatNS.sid)?["id"] ?? node["id"]
        m.serverID = node.children("stanza-id", ChatNS.sid).first { $0["by"] == (archive ?? me) }?["id"]
        m.requestsReceipt = node.child("request", ChatNS.receipts) != nil
        m.receiptFor = node.child("received", ChatNS.receipts)?["id"]
        if let marker = node.children.first(where: { $0.ns == ChatNS.markers && $0.name != "markable" }),
           let id = marker["id"] {
            m.marker = Marker(name: marker.name, id: id)
        }
        m.markable = node.child("markable", ChatNS.markers) != nil
        m.chatState = node.children.first { $0.ns == ChatNS.chatStates }?.name
        m.replaces = node.child("replace", ChatNS.correction)?["id"]
        if let reply = node.child("reply", ChatNS.reply), let id = reply["id"] { m.replyTo = Reply(jid: reply["to"], id: id) }
        if let reactions = node.child("reactions", ChatNS.reactions), let id = reactions["id"] {
            m.reaction = Reaction(id: id, emojis: reactions.children("reaction", ChatNS.reactions).map(\.text))
        }
        m.url = node.child("x", ChatNS.oob)?.child("url", ChatNS.oob)?.text
        m.omemo = node.child("encrypted", ChatNS.omemo)
        m.encrypted = m.omemo != nil
        m.delay = node.child("delay", ChatNS.delay)?["stamp"].flatMap(Self.date)
        return m
    }

    static func date(_ stamp: String) -> Date? {
        let plain = ISO8601DateFormatter()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions.insert(.withFractionalSeconds)
        return plain.date(from: stamp) ?? fractional.date(from: stamp)
    }

    /// An outgoing one-to-one text message: origin id, receipt request,
    /// markable, active chat state.
    static func outgoing(to: String, body: String, id: String,
                         replyTo: Reply? = nil) -> StanzaNode {
        var children = [StanzaNode("body", XMPPNS.client, text: body),
                        StanzaNode("origin-id", ChatNS.sid, ["id": id]),
                        StanzaNode("request", ChatNS.receipts),
                        StanzaNode("markable", ChatNS.markers),
                        StanzaNode("active", ChatNS.chatStates)]
        if let replyTo {
            var attributes = ["id": replyTo.id]
            attributes["to"] = replyTo.jid
            children.append(StanzaNode("reply", ChatNS.reply, attributes))
        }
        return StanzaNode("message", XMPPNS.client, ["to": to, "type": "chat", "id": id], children)
    }
}
