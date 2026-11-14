import Foundation
import GRDB

/// Group chats (XEP-0045) for the Swift core: joining from bookmarks and open
/// conversations, occupants, room messages and subjects, invitations, room
/// history, private messages to members, and being removed.
@MainActor
final class RoomCoordinator {
    struct Link {
        let send: (StanzaNode) -> Void
        let request: (StanzaNode, @escaping (StanzaNode) -> Void) -> Void
    }

    private final class Room {
        let account: String
        let jid: String
        let conversation: Int64
        var nick: String
        var joined = false
        var occupants: [String: MUC.Presence] = [:]
        var subject = ""
        /// Nicks composing a message right now.
        var typing: Set<String> = []
        var info = MUC.Info()
        /// Joining because the user accepted an invitation.
        var invited = false
        var password: String?
        /// Members by affiliation list (private rooms), whether present or not.
        var members: [String: String] = [:]

        init(account: String, jid: String, conversation: Int64, nick: String) {
            self.account = account
            self.jid = jid
            self.conversation = conversation
            self.nick = nick
        }

        var me: MUC.Presence? { occupants[nick] }
    }

    private let store: GeckoStore
    private let emit: ([String: Any]) -> Void
    private let onChanged: (Int64?, Bool) -> Void
    private var links: [String: Link] = [:]
    /// We are in the room now (messages written meanwhile can go).
    var onJoined: ((Int64) -> Void)?
    /// Opens an OMEMO message from a member (encrypted element, their real
    /// JID, live); nil when it cannot be read.
    var decrypt: ((StanzaNode, String, Bool) -> String?)?
    /// A stored room message that only shares a file (item, conversation, link).
    var onFile: ((Int64, Int64, String) -> Void)?
    private var rooms: [String: Room] = [:]

    /// `changed(item, synced)`: a stored message (or, with nil, the conversation
    /// list) changed; `synced` when it came from the archive, not live.
    init(store: GeckoStore, emit: @escaping ([String: Any]) -> Void, changed: @escaping (Int64?, Bool) -> Void) {
        self.store = store
        self.emit = emit
        self.onChanged = changed
    }

    private func changed(_ item: Int64?, synced: Bool = false) { onChanged(item, synced) }

    func isRoom(_ jid: String) -> Bool { rooms[JID.bare(jid)] != nil }

    // MARK: Sessions

    /// A new session: join bookmarked rooms marked autojoin and every open room conversation.
    func connected(_ account: String, link: Link) {
        links[account] = link
        rooms.values.filter { $0.account == account }.forEach { $0.joined = false; $0.occupants = [:] }
        link.request(Avatars.itemsQuery(MUCNS.bookmarks, to: account, id: "bookmarks-\(UUID().uuidString)")
            .removingMaxItems()) { [weak self] reply in
            guard let self else { return }
            for bookmark in MUC.bookmarks(reply) where bookmark.autojoin {
                join(account, bookmark.room, nick: bookmark.nick, password: bookmark.password, bookmark: false)
            }
            let open = (try? store.db.read { db in
                try Row.fetchAll(db, sql: "SELECT jid, nick FROM conversation WHERE account = ? AND kind = 'groupchat' AND open",
                                 arguments: [account])
            }) ?? []
            for row in open where rooms[row["jid"]]?.joined != true {
                join(account, row["jid"], nick: row["nick"], password: nil, bookmark: false)
            }
        }
    }

    /// The notification extension: each open room's archive since last time,
    /// without joining (no presence goes out); `done` once every room answered.
    func catchUpWithoutJoining(_ account: String, link: Link, done: @escaping () -> Void) {
        links[account] = link
        let open = (try? store.db.read { db in
            try Row.fetchAll(db, sql: "SELECT id, jid, nick FROM conversation WHERE account = ? AND kind = 'groupchat' AND open",
                             arguments: [account])
        }) ?? []
        var waiting = open.count
        guard waiting > 0 else { return done() }
        for row in open {
            let jid: String = row["jid"]
            let room = rooms[jid] ?? Room(account: account, jid: jid, conversation: row["id"],
                                          nick: row["nick"] ?? String(account.split(separator: "@").first ?? "gecko"))
            rooms[jid] = room
            catchUp(room) {
                waiting -= 1
                if waiting == 0 { done() }
            }
        }
    }

    func disconnected(_ account: String) {
        links[account] = nil
        rooms.values.filter { $0.account == account }.forEach { $0.joined = false; $0.occupants = [:] }
    }

    // MARK: Commands

    func join(_ account: String, _ room: String, nick: String?, password: String?, bookmark: Bool = true,
              invited: Bool = false) {
        let jid = JID.bare(room).lowercased()
        let name = nick?.isEmpty == false ? nick! : String(account.split(separator: "@").first ?? "gecko")
        guard let conversation = try? store.conversation(account: account, jid: jid, kind: "groupchat") else { return }
        try? store.update(conversation: conversation, "nick", name)
        let state = rooms[jid] ?? Room(account: account, jid: jid, conversation: conversation, nick: name)
        state.nick = name
        state.invited = invited
        state.password = password
        rooms[jid] = state
        changed(nil)
        guard let link = links[account] else {
            if invited { failInvite(state, "Could not join while disconnected") }
            return
        }
        link.send(MUC.join(jid, nick: name, password: password))
        if bookmark {
            link.request(MUC.publishBookmark(.init(room: jid, name: nil, nick: name, autojoin: true, password: password),
                                             id: "bookmark-\(UUID().uuidString)")) { _ in }
        }
        refreshInfo(state)
    }

    /// Leaves a room the user closed, and stops it joining automatically.
    func leave(_ conversation: Int64) {
        guard let room = rooms.values.first(where: { $0.conversation == conversation }) else { return }
        rooms[room.jid] = nil
        guard let link = links[room.account] else { return }
        link.send(MUC.leave(room.jid, nick: room.nick))
        link.request(MUC.retractBookmark(room.jid, id: "bookmark-\(UUID().uuidString)")) { _ in }
    }

    func requestOccupants(_ conversation: Int64) {
        if let room = room(conversation) { emitOccupants(room) }
    }

    func requestInfo(_ conversation: Int64) {
        guard let room = room(conversation) else { return }
        emitInfo(room)
        refreshInfo(room)
    }

    func invite(_ conversation: Int64, _ jid: String) {
        guard let room = room(conversation), let link = links[room.account] else {
            return emit(["type": "error", "message": "Could not send invitation while disconnected"])
        }
        link.send(MUC.invite(JID.bare(jid), to: room.jid))
    }

    func setSubject(_ conversation: Int64, _ subject: String) {
        guard let room = room(conversation), let link = links[room.account] else { return }
        link.send(StanzaNode("message", XMPPNS.client, ["to": room.jid, "type": "groupchat", "id": UUID().uuidString],
                             [StanzaNode("subject", XMPPNS.client, text: subject)]))
    }

    /// A private conversation with a member: with their account when the
    /// room shows it, otherwise through the room (room/nick).
    func privateChat(_ conversation: Int64, with member: String) -> Int64? {
        guard let room = room(conversation) else { return nil }
        let nick = JID.resource(member) ?? member
        if let real = room.occupants[nick]?.realJID {
            return try? store.conversation(account: room.account, jid: real)
        }
        return try? store.conversation(account: room.account, jid: "\(room.jid)/\(nick)", kind: "groupchatPrivate")
    }

    /// A room message to send: the stanza, or nil when we are not in the room.
    func outgoing(_ conversation: Int64, body: String, id: String) -> StanzaNode? {
        guard let room = room(conversation), room.joined else { return nil }
        return StanzaNode("message", XMPPNS.client, ["to": room.jid, "type": "groupchat", "id": id], [
            StanzaNode("body", XMPPNS.client, text: body),
            StanzaNode("origin-id", ChatNS.sid, ["id": id]),
        ])
    }

    // MARK: Moderation and configuration

    func kick(_ conversation: Int64, nick: String) {
        admin(conversation, ["nick": nick, "role": "none"])
    }

    func setRole(_ conversation: Int64, nick: String, role: String) {
        admin(conversation, ["nick": nick, "role": role])
    }

    func setAffiliation(_ conversation: Int64, jid: String, affiliation: String) {
        admin(conversation, ["jid": JID.bare(jid), "affiliation": affiliation]) { [weak self] in
            guard let self, let room = self.room(conversation) else { return }
            fetchMembers(room)
        }
    }

    private func admin(_ conversation: Int64, _ item: [String: String], then: (() -> Void)? = nil) {
        guard let room = room(conversation), let link = links[room.account] else { return }
        let iq = StanzaNode("iq", XMPPNS.client, ["type": "set", "to": room.jid, "id": "admin-\(UUID().uuidString)"],
                            [StanzaNode("query", MUCNS.admin, [:], [StanzaNode("item", MUCNS.admin, item)])])
        link.request(iq) { [weak self] reply in
            if reply["type"] == "error" {
                let condition = reply.child("error", XMPPNS.client)?.children.first?.name ?? "error"
                self?.emit(["type": "error", "message": "The room refused that (\(condition))."])
            } else {
                then?()
            }
        }
    }

    /// Changes room settings through its owner form (XEP-0045 §10.2).
    func configure(_ conversation: Int64, _ values: [String: String]) {
        guard let room = room(conversation), let link = links[room.account] else { return }
        let get = StanzaNode("iq", XMPPNS.client, ["type": "get", "to": room.jid, "id": "config-\(UUID().uuidString)"],
                             [StanzaNode("query", MUCNS.owner)])
        link.request(get) { [weak self] reply in
            guard let self, reply["type"] == "result",
                  let form = reply.child("query", MUCNS.owner)?.child("x", "jabber:x:data") else {
                self?.emit(["type": "error", "message": "Couldn't load room settings (owner only)."])
                return
            }
            var fields = form.children("field", "jabber:x:data").filter { $0["var"] != nil && $0["type"] != "fixed" }
            for (index, field) in fields.enumerated() {
                guard let name = field["var"], let value = values[name] else { continue }
                fields[index].children = [StanzaNode("value", "jabber:x:data", text: value)]
            }
            let submitted = fields.map { field in
                StanzaNode("field", "jabber:x:data", ["var": field["var"] ?? ""],
                           field.children("value", "jabber:x:data"))
            }
            let set = StanzaNode("iq", XMPPNS.client, ["type": "set", "to": room.jid, "id": "config-\(UUID().uuidString)"],
                                 [StanzaNode("query", MUCNS.owner, [:],
                                             [StanzaNode("x", "jabber:x:data", ["type": "submit"], submitted)])])
            link.request(set) { [weak self] reply in
                if reply["type"] == "error" {
                    self?.emit(["type": "error", "message": "The room did not accept the new settings."])
                }
                self?.refreshInfo(room)
            }
        }
    }

    /// The room's picture (vCard-temp on the room, XEP-0153).
    func setAvatar(_ conversation: Int64, path: String) -> (jid: String, png: Data)? {
        guard let room = room(conversation), let link = links[room.account],
              let scaled = Avatars.scaledPNG(URL(fileURLWithPath: path)) else { return nil }
        let vcard = StanzaNode("vCard", AvatarNS.vcard, [:], [StanzaNode("PHOTO", AvatarNS.vcard, [:], [
            StanzaNode("TYPE", AvatarNS.vcard, text: "image/png"),
            StanzaNode("BINVAL", AvatarNS.vcard, text: scaled.png.base64EncodedString()),
        ])])
        link.request(StanzaNode("iq", XMPPNS.client, ["type": "set", "to": room.jid, "id": "room-avatar-\(UUID().uuidString)"],
                                [vcard])) { [weak self] reply in
            if reply["type"] == "error" { self?.emit(["type": "error", "message": "The room did not accept the picture."]) }
        }
        return (room.jid, scaled.png)
    }

    /// The real JIDs of a private room's members besides us, for OMEMO.
    func memberJIDs(_ conversation: Int64) -> [String]? {
        guard let room = room(conversation), room.info.membersOnly, room.info.nonAnonymous else { return nil }
        let present = room.occupants.values.compactMap(\.realJID)
        return Array(Set(present + room.members.keys)).filter { $0 != room.account }
    }

    /// Whether a room is private (members only, real JIDs visible), where OMEMO works.
    func isPrivate(_ jid: String) -> Bool {
        guard let room = rooms[JID.bare(jid)] else { return false }
        return room.info.membersOnly && room.info.nonAnonymous
    }

    /// The affiliation lists of a private room (owner, admin, member).
    private func fetchMembers(_ room: Room) {
        guard let link = links[room.account], room.info.membersOnly else { return }
        for affiliation in ["owner", "admin", "member"] {
            let iq = StanzaNode("iq", XMPPNS.client, ["type": "get", "to": room.jid, "id": "members-\(UUID().uuidString)"],
                                [StanzaNode("query", MUCNS.admin, [:], [StanzaNode("item", MUCNS.admin, ["affiliation": affiliation])])])
            link.request(iq) { [weak self] reply in
                guard let self, reply["type"] == "result" else { return }
                room.members = room.members.filter { $0.value != affiliation }
                for item in reply.child("query", MUCNS.admin)?.children("item", MUCNS.admin) ?? [] {
                    if let jid = item["jid"] { room.members[JID.bare(jid)] = affiliation }
                }
                emitOccupants(room)
            }
        }
    }

    // MARK: Incoming

    /// A presence from a room; false when it is not one of ours.
    func presence(_ node: StanzaNode) -> Bool {
        guard let presence = MUC.presence(node), let room = rooms[presence.room] else { return false }
        if let error = presence.error {
            room.joined = false
            if room.invited {
                failInvite(room, "Could not join the invited room (\(error))")
            } else {
                emit(["type": "error", "message": "Could not join \(room.jid): \(error)"])
            }
            return true
        }
        let isSelf = presence.isSelf || presence.nick == room.nick
        if presence.available {
            room.occupants[presence.nick] = presence
            if isSelf, !room.joined {
                room.joined = true
                if room.invited {
                    room.invited = false
                    emit(["type": "muc_invite_joined", "account": room.account, "room": room.jid,
                          "conversation": room.conversation])
                }
                if presence.codes.contains(201) {
                    // We created it: accept the default configuration (an instant room).
                    links[room.account]?.request(StanzaNode(
                        "iq", XMPPNS.client, ["type": "set", "to": room.jid, "id": "instant-\(UUID().uuidString)"],
                        [StanzaNode("query", MUCNS.owner, [:], [StanzaNode("x", "jabber:x:data", ["type": "submit"])])])) { _ in }
                }
                catchUp(room)
                emitInfo(room)
                onJoined?(room.conversation)
            }
        } else {
            room.occupants[presence.nick] = nil
            setTyping(room, presence.nick, false)
            if let newNick = presence.newNick, presence.codes.contains(303), isSelf {
                room.nick = newNick
            } else if isSelf {
                room.joined = false
                if let reason = MUC.removal(presence) {
                    rooms[room.jid] = nil
                    emit(["type": "muc_removed", "conversation": room.conversation, "account": room.account,
                          "room": room.jid, "reason": reason])
                }
            }
        }
        emitOccupants(room)
        return true
    }

    /// An invitation, if the message is one.
    func invitation(_ node: StanzaNode, account: String) -> Bool {
        guard let invite = MUC.invitation(node) else { return false }
        emit(["type": "muc_invite", "account": account, "room": invite.room, "inviter": invite.inviter,
              "reason": invite.reason ?? "", "password": invite.password ?? ""])
        return true
    }

    /// A groupchat message (live or from the room's archive); true when handled.
    private func setTyping(_ room: Room, _ nick: String, _ typing: Bool) {
        let changed = typing ? room.typing.insert(nick).inserted : room.typing.remove(nick) != nil
        guard changed else { return }
        emit(["type": "chat_state", "conversation": room.conversation,
              "state": room.typing.isEmpty ? "active" : "composing", "typing_names": room.typing.sorted()])
    }

    func message(_ node: StanzaNode, account: String) -> Bool {
        let from = node["from"] ?? ""
        // The room keeps the archive, live ids and results alike.
        guard let room = rooms[JID.bare(from)], let m = ChatStanza.parse(node, me: account, archive: room.jid),
              m.type == "groupchat" else { return false }
        if let subject = node.child("subject", XMPPNS.client), m.body == nil {
            room.subject = subject.text
            emitInfo(room)
            return true
        }
        guard let nick = JID.resource(m.from) else { return true }
        // Ours: our nick here, or (where real JIDs show) our account under
        // another nick, as from our other devices.
        let ours = nick == room.nick || room.occupants[nick]?.realJID.map(JID.bare) == room.account
        if let state = m.chatState, !ours, !m.archived { setTyping(room, nick, state == "composing") }
        if ours, let originID = m.originID,
           let mine = try? store.message(room.conversation, originID: originID, sender: room.account) {
            // Our own message reflected by the room: now it is delivered.
            if (mine["state"] as String) != "received" {
                try? store.setState(message: mine["id"], "received")
                changed(mine["id"])
            }
            return true
        }
        var body = m.body
        if let encrypted = m.omemo {
            // Only members' real JIDs have sessions; a copy of ours we cannot open.
            if let known = m.serverID, (try? store.message(room.conversation, originID: known)) != nil { return true }
            guard !ours, let real = room.occupants[nick]?.realJID,
                  let text = decrypt?(encrypted, real, !m.archived) else { return true }
            body = text
        }
        guard let body, !body.isEmpty else { return true }
        let item = try? store.insert(.init(
            conversation: room.conversation, direction: ours ? "out" : "in", sender: ours ? room.account : nick,
            body: body, time: m.delay ?? Date(), originID: m.originID, serverID: m.serverID,
            encryption: m.omemo == nil ? "none" : "omemo", state: ours ? "received" : "none"))
        if let item = item ?? nil {
            if let link = FileSharing.sharedLink(body: body, oob: m.url) { onFile?(item, room.conversation, link) }
            try? store.db.write { db in
                try db.execute(sql: "UPDATE message SET senderRealJID = ? WHERE id = ?",
                               arguments: [room.occupants[nick]?.realJID, item])
            }
            changed(item, synced: m.archived)
            changed(nil)
        }
        return true
    }

    // MARK: Helpers

    private func room(_ conversation: Int64) -> Room? {
        rooms.values.first { $0.conversation == conversation }
    }

    private func failInvite(_ room: Room, _ message: String) {
        room.invited = false
        emit(["type": "muc_invite_failed", "account": room.account, "room": room.jid, "message": message])
    }

    /// The room's archive since what we last fetched (XEP-0313 on the room).
    private func catchUp(_ room: Room, then: (() -> Void)? = nil) {
        guard let link = links[room.account] else { then?(); return }
        let key = "mam:\(room.account):\(room.jid)"
        let after = (try? store.setting(key)) ?? nil
        let id = "room-mam-\(UUID().uuidString)"
        let page = StanzaNode("set", "http://jabber.org/protocol/rsm", [:], [
            StanzaNode("max", "http://jabber.org/protocol/rsm", text: "50"),
            after.map { StanzaNode("after", "http://jabber.org/protocol/rsm", text: $0) }
                ?? StanzaNode("before", "http://jabber.org/protocol/rsm"),
        ])
        link.request(StanzaNode("iq", XMPPNS.client, ["type": "set", "to": room.jid, "id": id],
                                [StanzaNode("query", ChatNS.mam, ["queryid": id], [page])])) { [weak self] reply in
            guard let self, let last = reply.child("fin", ChatNS.mam)?.child("set", "http://jabber.org/protocol/rsm")?
                .child("last", "http://jabber.org/protocol/rsm")?.text else { then?(); return }
            try? store.setSetting(key, last)
            if reply.child("fin", ChatNS.mam)?["complete"] != "true", after != nil {
                catchUp(room, then: then)
            } else {
                then?()
            }
        }
    }

    private func refreshInfo(_ room: Room) {
        guard let link = links[room.account] else { return }
        link.request(StanzaNode("iq", XMPPNS.client, ["type": "get", "to": room.jid, "id": "room-info-\(UUID().uuidString)"],
                                [StanzaNode("query", Disco.info)])) { [weak self] reply in
            let info = MUC.info(reply)
            guard info.exists else { return }
            room.info = info
            try? self?.store.setSetting("roomPrivate:\(room.jid)", info.membersOnly && info.nonAnonymous ? "1" : "0")
            self?.changed(nil)
            self?.fetchMembers(room)
            if let name = info.name {
                try? self?.store.setSetting("roomName:\(room.jid)", name)
                self?.changed(nil)
            }
            self?.emitInfo(room)
        }
    }

    private func emitInfo(_ room: Room) {
        emit(["type": "room_info", "conversation": room.conversation, "subject": room.subject,
              "is_private": room.info.membersOnly && room.info.nonAnonymous, "is_moderated": room.info.moderated,
              "my_affiliation": room.me?.affiliation ?? "none", "my_role": room.me?.role ?? "none"])
    }

    private func emitOccupants(_ room: Room) {
        let list = room.occupants.values.sorted { $0.nick < $1.nick }.map { o -> [String: Any] in
            ["nick": o.nick, "self": o.nick == room.nick, "jid": "\(room.jid)/\(o.nick)", "real_jid": o.realJID ?? "",
             "affiliation": o.affiliation, "role": o.role]
        }
        let present = Set(room.occupants.values.compactMap(\.realJID))
        let offline = room.members.filter { !present.contains($0.key) && $0.key != room.account }.sorted { $0.key < $1.key }
            .map { member -> [String: Any] in
                ["id": member.key, "name": String(member.key.split(separator: "@").first ?? ""), "jid": member.key,
                 "affiliation": member.value]
            }
        emit(["type": "occupants", "conversation": room.conversation, "list": list, "offline": offline])
    }
}

private extension StanzaNode {
    /// Bookmarks are all wanted, not only the newest.
    func removingMaxItems() -> StanzaNode {
        var copy = self
        if var pubsub = copy.children.first, var items = pubsub.children.first {
            items.attributes["max_items"] = nil
            pubsub.children = [items]
            copy.children = [pubsub]
        }
        return copy
    }
}
