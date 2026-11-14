import Foundation

enum MUCNS {
    static let muc = "http://jabber.org/protocol/muc"
    static let user = "http://jabber.org/protocol/muc#user"
    static let admin = "http://jabber.org/protocol/muc#admin"
    static let owner = "http://jabber.org/protocol/muc#owner"
    static let conference = "jabber:x:conference"
    static let bookmarks = "urn:xmpp:bookmarks:1"
    static let stanzas = "urn:ietf:params:xml:ns:xmpp-stanzas"
}

/// Multi-user chat (XEP-0045) as far as reading and writing stanzas goes.
enum MUC {
    /// A room occupant's presence.
    struct Presence: Equatable {
        let room: String
        let nick: String
        let available: Bool
        let affiliation: String
        let role: String
        /// The member's own JID, when the room shows it to us.
        let realJID: String?
        let show: String
        let codes: Set<Int>
        /// A join refused (presence type error): its condition.
        let error: String?
        /// A nick change (code 303): the new nick.
        let newNick: String?

        var isSelf: Bool { codes.contains(110) }
    }

    static func presence(_ node: StanzaNode) -> Presence? {
        guard node.name == "presence", let from = node["from"], let nick = JID.resource(from) else { return nil }
        let user = node.child("x", MUCNS.user)
        let error = node["type"] == "error"
            ? node.child("error", XMPPNS.client)?.children.first { $0.ns == MUCNS.stanzas }?.name ?? "error"
            : nil
        guard user != nil || error != nil else { return nil }
        let item = user?.child("item", MUCNS.user)
        return Presence(
            room: JID.bare(from), nick: nick, available: node["type"] == nil,
            affiliation: item?["affiliation"] ?? "none", role: item?["role"] ?? "none",
            realJID: item?["jid"].map(JID.bare), show: node.child("show", XMPPNS.client)?.text ?? "online",
            codes: Set(user?.children("status", MUCNS.user).compactMap { $0["code"].flatMap(Int.init) } ?? []),
            error: error, newNick: item?["nick"])
    }

    /// Why we are no longer in a room, from our own unavailable presence; nil
    /// for an ordinary leave.
    static func removal(_ presence: Presence) -> String? {
        if presence.codes.contains(301) { return "banned" }
        if presence.codes.contains(307) { return "kicked" }
        if presence.codes.contains(321) { return "affiliation" }
        if presence.codes.contains(322) { return "members-only" }
        if presence.codes.contains(332) { return "shutdown" }
        return nil
    }

    static func join(_ room: String, nick: String, password: String?) -> StanzaNode {
        // History comes from the room's archive instead (XEP-0313).
        var x = [StanzaNode("history", MUCNS.muc, ["maxstanzas": "0"])]
        if let password, !password.isEmpty { x.append(StanzaNode("password", MUCNS.muc, text: password)) }
        return StanzaNode("presence", XMPPNS.client, ["to": "\(room)/\(nick)"], [StanzaNode("x", MUCNS.muc, [:], x)])
    }

    static func leave(_ room: String, nick: String) -> StanzaNode {
        StanzaNode("presence", XMPPNS.client, ["to": "\(room)/\(nick)", "type": "unavailable"])
    }

    /// An invitation in a message: mediated (XEP-0045 §7.8.2) or direct (XEP-0249).
    struct Invitation: Equatable {
        let room: String
        let inviter: String
        let reason: String?
        let password: String?
    }

    static func invitation(_ node: StanzaNode) -> Invitation? {
        guard node.name == "message", let from = node["from"] else { return nil }
        if let user = node.child("x", MUCNS.user), let invite = user.child("invite", MUCNS.user) {
            return Invitation(room: JID.bare(from), inviter: JID.bare(invite["from"] ?? from),
                              reason: invite.child("reason", MUCNS.user)?.text,
                              password: user.child("password", MUCNS.user)?.text)
        }
        if let direct = node.child("x", MUCNS.conference), let room = direct["jid"] {
            return Invitation(room: JID.bare(room), inviter: JID.bare(from), reason: direct["reason"],
                              password: direct["password"])
        }
        return nil
    }

    /// A mediated invitation, sent through the room so it can admit the invitee.
    static func invite(_ jid: String, to room: String) -> StanzaNode {
        StanzaNode("message", XMPPNS.client, ["to": room, "id": UUID().uuidString], [
            StanzaNode("x", MUCNS.user, [:], [StanzaNode("invite", MUCNS.user, ["to": jid])]),
        ])
    }

    // MARK: Bookmarks (XEP-0402)

    struct Bookmark: Equatable {
        let room: String
        let name: String?
        let nick: String?
        let autojoin: Bool
        let password: String?
    }

    static func bookmarks(_ node: StanzaNode) -> [Bookmark] {
        let items = node.child("pubsub", AvatarNS.pubsub)?.child("items", AvatarNS.pubsub)?.children ?? []
        return items.compactMap { item in
            guard let room = item["id"], let conference = item.child("conference", MUCNS.bookmarks) else { return nil }
            return Bookmark(room: room, name: conference["name"], nick: conference.child("nick", MUCNS.bookmarks)?.text,
                            autojoin: conference["autojoin"] == "true" || conference["autojoin"] == "1",
                            password: conference.child("password", MUCNS.bookmarks)?.text)
        }
    }

    /// Publishes (or replaces) one bookmark, private to us (XEP-0402 §3.2).
    static func publishBookmark(_ bookmark: Bookmark, id: String) -> StanzaNode {
        var attributes = ["autojoin": bookmark.autojoin ? "true" : "false"]
        attributes["name"] = bookmark.name
        var children: [StanzaNode] = []
        if let nick = bookmark.nick { children.append(StanzaNode("nick", MUCNS.bookmarks, text: nick)) }
        if let password = bookmark.password { children.append(StanzaNode("password", MUCNS.bookmarks, text: password)) }
        let form = StanzaNode("x", "jabber:x:data", ["type": "submit"], [
            StanzaNode("field", "jabber:x:data", ["var": "FORM_TYPE", "type": "hidden"],
                       [StanzaNode("value", "jabber:x:data", text: "\(AvatarNS.pubsub)#publish-options")]),
            StanzaNode("field", "jabber:x:data", ["var": "pubsub#persist_items"], [StanzaNode("value", "jabber:x:data", text: "true")]),
            StanzaNode("field", "jabber:x:data", ["var": "pubsub#max_items"], [StanzaNode("value", "jabber:x:data", text: "max")]),
            StanzaNode("field", "jabber:x:data", ["var": "pubsub#send_last_published_item"],
                       [StanzaNode("value", "jabber:x:data", text: "never")]),
            StanzaNode("field", "jabber:x:data", ["var": "pubsub#access_model"],
                       [StanzaNode("value", "jabber:x:data", text: "whitelist")]),
        ])
        return StanzaNode("iq", XMPPNS.client, ["type": "set", "id": id], [
            StanzaNode("pubsub", AvatarNS.pubsub, [:], [
                StanzaNode("publish", AvatarNS.pubsub, ["node": MUCNS.bookmarks], [
                    StanzaNode("item", AvatarNS.pubsub, ["id": bookmark.room],
                               [StanzaNode("conference", MUCNS.bookmarks, attributes, children)]),
                ]),
                StanzaNode("publish-options", AvatarNS.pubsub, [:], [form]),
            ]),
        ])
    }

    static func retractBookmark(_ room: String, id: String) -> StanzaNode {
        StanzaNode("iq", XMPPNS.client, ["type": "set", "id": id], [
            StanzaNode("pubsub", AvatarNS.pubsub, [:], [
                StanzaNode("retract", AvatarNS.pubsub, ["node": MUCNS.bookmarks, "notify": "true"],
                           [StanzaNode("item", AvatarNS.pubsub, ["id": room])]),
            ]),
        ])
    }

    // MARK: Room information

    struct Info: Equatable {
        var name: String?
        var membersOnly = false
        var nonAnonymous = false
        var moderated = false
        var exists = true
    }

    static func info(_ reply: StanzaNode) -> Info {
        guard reply["type"] == "result", let query = reply.child("query", Disco.info) else {
            return Info(exists: false)
        }
        let features = Set(query.children("feature", Disco.info).compactMap { $0["var"] })
        let name = query.children("identity", Disco.info).first { $0["category"] == "conference" }?["name"]
        return Info(name: name.flatMap { $0.isEmpty ? nil : $0 }, membersOnly: features.contains("muc_membersonly"),
                    nonAnonymous: features.contains("muc_nonanonymous"), moderated: features.contains("muc_moderated"))
    }
}
