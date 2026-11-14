import Foundation
import GRDB
import UniformTypeIdentifiers

/// Where account passwords live (the Keychain in the app).
protocol PasswordKeeper {
    func password(for jid: String) -> String?
    func setPassword(_ password: String?, for jid: String)
}

/// Gecko's XMPP core, behind `GeckoCore`: takes the app's commands and emits
/// its events as JSON-shaped dictionaries that `AppModel` decodes. Accounts,
/// contacts, presence, chats and rooms, OMEMO, files, push and call
/// signalling; group chats live in `RoomCoordinator`, OMEMO in
/// `OMEMOCoordinator`.
@MainActor
final class SwiftCore {
    let store: GeckoStore
    private let passwords: PasswordKeeper
    private let emit: ([String: Any]) -> Void
    private let resource: String
    /// Where avatar images live, by hash: ours first (written), then the
    /// Vala core's cache (read only).
    private let avatarDirectories: [URL]

    private var clients: [String: XMPPClient] = [:]
    private var listeners: [String: Task<Void, Never>] = [:]
    private var connected: Set<String> = []
    /// Bare JID → resource → show ("online", "away", ...), per account.
    private var presence: [String: [String: [String: String]]] = [:]
    /// The conversation the user is looking at.
    private var focused: Int64?
    /// Archive queries in flight (XEP-0313): query id → account.
    private var archiveQueries: [String: String] = [:]
    /// The newest incoming message each chat has sent a displayed marker for.
    private var displayedSent: [Int64: Int64] = [:]
    /// What to do with the answer to each IQ we sent, by id.
    private var replies: [String: (account: String, then: (StanzaNode) -> Void)] = [:]
    /// Avatars already looked up this session, and those asked for before
    /// we were connected (the app asks once, as rows appear).
    private var avatarsChecked: Set<String> = []
    private var avatarsWaiting: Set<String> = []
    private var blocked: Set<String> = []
    /// OMEMO per connected account.
    private var omemo: [String: OMEMOCoordinator] = [:]
    private let transfers = FileTransfers()
    private var uploading: Set<Int64> = []
    private var downloading: Set<Int64> = []
    /// Transfers the user stopped; an upload is not retried after it.
    private var cancelledTransfers: Set<Int64> = []
    /// Each account's HTTP upload service and its size limit (XEP-0363).
    private var uploadServices: [String: (jid: String, limit: Int64?)] = [:]
    private lazy var rooms: RoomCoordinator = {
        let rooms = RoomCoordinator(store: store, emit: { [weak self] in self?.emit($0) }) { [weak self] item, synced in
            if let item { self?.emitItem(item, synced: synced) } else { self?.pushConversations() }
        }
        rooms.onJoined = { [weak self] conversation in self?.flushRoom(conversation) }
        rooms.onFile = { [weak self] item, conversation, link in self?.shareFile(item, conversation: conversation, link: link) }
        rooms.decrypt = { [weak self] encrypted, sender, live in
            guard let self, let account = self.firstAccount,
                  case .text(let text)? = self.omemo[account]?.decrypt(encrypted, from: sender, live: live) else { return nil }
            return text
        }
        return rooms
    }()
    private var blockingSupported = false
    private var foreground = true

    /// The notification extension's short session: no stream management,
    /// presence, roster, room joins or sending; it only catches up on the
    /// archives (stored, decrypted) and then calls `onCaughtUp`.
    private let forNotifications: Bool
    var onCaughtUp: (() -> Void)?

    init(store: GeckoStore, passwords: PasswordKeeper, resource: String, avatarDirectories: [URL],
         forNotifications: Bool = false, emit: @escaping ([String: Any]) -> Void) {
        self.forNotifications = forNotifications
        self.store = store
        self.avatarDirectories = avatarDirectories
        self.passwords = passwords
        self.resource = resource
        self.emit = emit
    }

    // MARK: Lifecycle

    func start() {
        for account in (try? store.accounts()) ?? [] where account.enabled {
            if let password = passwords.password(for: account.jid) {
                connect(account.jid, password)
            } else {
                // The Keychain lost it (restored backup, reinstall): signed
                // out, so the app asks for the password again.
                try? store.setEnabled(account.jid, false)
            }
        }
        emit(["type": "ready"])
    }

    func requestState() {
        let accounts = ((try? store.accounts()) ?? []).filter(\.enabled).map {
            ["jid": $0.jid, "state": connected.contains($0.jid) ? "CONNECTED" : "CONNECTING"]
        }
        emit(["type": "accounts", "list": accounts])
        pushConversations()
        pushRoster()
    }

    func addAccount(jid: String, password: String) {
        let bare = JID.bare(jid).lowercased()
        do {
            try store.addAccount(bare, resource: resource)
        } catch {
            return fail("\(error)")
        }
        passwords.setPassword(password, for: bare)
        connect(bare, password)
        emit(["type": "account_added", "account": bare])
    }

    /// Keeps the account row (and later its OMEMO identity); only stops it.
    func signOut() {
        for (jid, client) in clients {
            Task { await client.stop() }
            try? store.setEnabled(jid, false)
            passwords.setPassword(nil, for: jid)
        }
        clients = [:]
        listeners.values.forEach { $0.cancel() }
        listeners = [:]
        connected = []
        emit(["type": "signed_out"])
    }

    /// iOS, before suspension: close the streams (acknowledging what arrived)
    /// so the server holds no session for us. Messages then wait in offline
    /// storage and the archive and push as usual, while copies of what we send
    /// from other devices no longer wake the phone.
    func appBackgrounded() {
        foreground = false
        for client in clients.values { Task { await client.stop() } }
        emit(["type": "app_backgrounded"])
    }

    func appForegrounded() {
        foreground = true
        for client in clients.values {
            Task {
                await client.setActive(true)
                await client.start()
            }
        }
    }

    // MARK: Conversations and messages

    func startConversation(jid: String) {
        guard let account = firstAccount else { return }
        do {
            let id = try store.conversation(account: account, jid: JID.bare(jid))
            pushConversations()
            emit(["type": "open_conversation", "id": id])
        } catch {
            fail("\(error)")
        }
    }

    func closeConversation(_ id: Int64) {
        rooms.leave(id)
        try? store.update(conversation: id, "open", false)
        pushConversations()
    }

    func focus(_ id: Int64) {
        focused = id
        markRead(id)
    }

    func blur(_ id: Int64) {
        if focused == id { focused = nil }
    }

    func setNotify(_ id: Int64, _ setting: String) {
        // Default: mentions only in rooms, everything elsewhere.
        let room = ((try? store.conversationRow(id))??["kind"] as String?) == "groupchat"
        try? store.update(conversation: id, "notify", setting != "default" ? setting : room ? "highlight" : "on")
        pushConversations()
        syncPushFilters()
    }

    func setEncryption(_ id: Int64, omemo: Bool) {
        try? store.update(conversation: id, "encryption", omemo ? "omemo" : "none")
        pushConversations()
    }

    func requestMessages(_ conversation: Int64, count: Int) {
        let items = (try? store.history(conversation, count: count)) ?? []
        emit(["type": "history", "conversation": conversation, "complete": items.count < count,
              "next_before": items.first?["item"] ?? NSNull(), "items": items])
    }

    func requestMessagesBefore(_ conversation: Int64, before: Int64, count: Int) {
        let items = (try? store.history(conversation, before: before, count: count)) ?? []
        emit(["type": "history_before", "conversation": conversation, "before": before,
              "complete": items.count < count, "next_before": items.first?["item"] ?? NSNull(), "items": items])
    }

    func sendText(_ conversation: Int64, body: String, replyTo: Int64? = nil) {
        guard let row = try? store.conversationRow(conversation) else { return }
        let account: String = row["account"], jid: String = row["jid"]
        let encrypted = (row["encryption"] as String) == "omemo"
        let id = UUID().uuidString.lowercased()
        do {
            guard let item = try store.insert(.init(
                conversation: conversation, direction: "out", sender: account, body: body, time: Date(),
                originID: id, encryption: encrypted ? "omemo" : "none", state: "pending"))
            else { return }
            var reply: ChatStanza.Reply?
            if let replyTo, let target = try store.messageRow(replyTo), let targetID = target["originID"] as String? {
                let sender: String = target["sender"]
                reply = ChatStanza.Reply(jid: sender, id: targetID)
                try store.setReply(message: item, to: replyTo, targetID: targetID, targetSender: sender)
            }
            if (row["kind"] as String) == "groupchat", encrypted {
                sendEncryptedToRoom(item, conversation: conversation, account: account)
            } else if (row["kind"] as String) == "groupchat" {
                if let stanza = rooms.outgoing(conversation, body: body, id: id), let client = clients[account] {
                    Task { await client.send(stanza) }
                    try store.setState(message: item, "sent")
                }
            } else if encrypted {
                if connected.contains(account) { sendEncrypted(item) }
            } else if let client = clients[account], connected.contains(account) {
                Task { await client.send(ChatStanza.outgoing(to: jid, body: body, id: id, replyTo: reply)) }
                try store.setState(message: item, "sent")
            }
            emitItem(item)
            pushConversations()
        } catch {
            fail("\(error)")
        }
    }

    /// Sends a stored message of an OMEMO chat: never in the clear. Fails it
    /// when the contact has no device we can encrypt for.
    private func sendEncrypted(_ item: Int64) {
        guard let message = try? store.messageRow(item), let row = try? store.conversationRow(message["conversation"]),
              let coordinator = omemo[row["account"]], let client = clients[row["account"]] else { return }
        let account: String = row["account"], jid: String = row["jid"]
        let body: String = message["body"] ?? "", id: String = message["originID"] ?? UUID().uuidString.lowercased()
        let reply = (message["replyToID"] as String?).map {
            ChatStanza.Reply(jid: message["replyToSender"], id: $0)
        }
        coordinator.prepare([jid, account]) { [weak self] in
            guard let self else { return }
            guard let encrypted = coordinator.encrypt(body, to: jid) else {
                try? store.setState(message: item, "failed")
                emitItem(item)
                return fail("\(jid) has no OMEMO device this message could be encrypted for; it was not sent.")
            }
            var stanza = ChatStanza.outgoing(to: jid, body: body, id: id, replyTo: reply)
            stanza.children.removeAll { $0.name == "body" }
            stanza.children += encrypted
            Task { await client.send(stanza) }
            try? store.setState(message: item, "sent")
            emitItem(item)
        }
    }

    func correctMessage(_ conversation: Int64, item: Int64, body: String) {
        guard let (account, jid, client) = chat(conversation), let row = try? store.messageRow(item),
              row["direction"] as String == "out", (row["encryption"] as String) == "none",
              let original = row["originID"] as String? else { return }
        let id = UUID().uuidString.lowercased()
        var stanza = ChatStanza.outgoing(to: jid, body: body, id: id)
        stanza.children.append(StanzaNode("replace", ChatNS.correction, ["id": original]))
        Task { await client.send(stanza) }
        try? store.correct(message: item, body: body)
        _ = account
        emitItem(item)
        pushConversations()
    }

    func setReaction(_ conversation: Int64, item: Int64, emoji: String, add: Bool) {
        guard let (account, jid, client) = chat(conversation), let row = try? store.messageRow(item),
              let target = row["originID"] as String? ?? row["serverID"] as String? else { return }
        var set = (try? store.reactions(message: item, sender: account)) ?? []
        set.removeAll { $0 == emoji }
        if add { set.append(emoji) }
        let stanza = StanzaNode("message", XMPPNS.client, ["to": jid, "type": "chat", "id": UUID().uuidString], [
            StanzaNode("reactions", ChatNS.reactions, ["id": target],
                       set.map { StanzaNode("reaction", ChatNS.reactions, text: $0) }),
            StanzaNode("store", ChatNS.hints),
        ])
        Task { await client.send(stanza) }
        try? store.setReactions(message: item, sender: account, emojis: set)
        emitItem(item)
    }

    func setTyping(_ conversation: Int64, _ typing: Bool) {
        guard privacy("send_typing"), let (_, jid, client) = chat(conversation) else { return }
        Task {
            await client.send(StanzaNode("message", XMPPNS.client, ["to": jid, "type": "chat"],
                                         [StanzaNode(typing ? "composing" : "paused", ChatNS.chatStates),
                                          StanzaNode("no-store", ChatNS.hints)]))
        }
    }

    // MARK: Avatars

    /// Shows a contact's (or our own) avatar: what is stored at once, then,
    /// once per session, asks for the current one (PEP, then vCard).
    func requestAvatar(jid: String) {
        let bare = JID.bare(jid)
        guard let account = firstAccount else { return }
        if let hash = avatarHash(account, bare), let file = avatarFile(hash) {
            emit(["type": "avatar", "jid": bare, "path": file.path])
        }
        guard !avatarsChecked.contains(bare) else { return }
        guard let client = clients[account], connected.contains(account) else {
            avatarsWaiting.insert(bare)
            return
        }
        avatarsChecked.insert(bare)
        let id = "avatar-meta-\(UUID().uuidString)"
        request(Avatars.itemsQuery(AvatarNS.metadata, to: bare, id: id), client) { [weak self] reply in
            guard let self else { return }
            guard reply["type"] == "result", let current = Avatars.metadataID(reply) else {
                return fetchVCardAvatar(account, bare, client)
            }
            if current.isEmpty || current == avatarHash(account, bare) && avatarFile(current) != nil { return }
            if avatarFile(current) != nil { return storeAvatar(account, bare, hash: current, image: nil) }
            let dataID = "avatar-data-\(UUID().uuidString)"
            request(Avatars.itemsQuery(AvatarNS.data, to: bare, id: dataID, item: current), client) { [weak self] reply in
                guard let image = Avatars.data(reply, id: current) else { return }
                self?.storeAvatar(account, bare, hash: current, image: image)
            }
        }
    }

    private func fetchVCardAvatar(_ account: String, _ jid: String, _ client: XMPPClient) {
        let id = "vcard-\(UUID().uuidString)"
        request(StanzaNode("iq", XMPPNS.client, ["type": "get", "to": jid, "id": id],
                           [StanzaNode("vCard", AvatarNS.vcard)]), client) { [weak self] reply in
            guard let image = Avatars.vcardPhoto(reply) else { return }
            self?.storeAvatar(account, jid, hash: Avatars.sha1(image), image: image)
        }
    }

    func setAvatar(path: String) {
        guard let account = firstAccount, let client = clients[account], connected.contains(account),
              let scaled = Avatars.scaledPNG(URL(fileURLWithPath: path)) else {
            return fail("The picture could not be used as an avatar.")
        }
        for iq in Avatars.publish(png: scaled.png, width: scaled.width, height: scaled.height) {
            request(iq, client) { [weak self] reply in
                if reply["type"] == "error" { self?.fail("The server did not accept the avatar.") }
            }
        }
        storeAvatar(account, account, hash: Avatars.sha1(scaled.png), image: scaled.png)
    }

    private func avatarHash(_ account: String, _ jid: String) -> String? {
        try? store.db.read { db in
            try String.fetchOne(db, sql: "SELECT hash FROM avatar WHERE account = ? AND jid = ?", arguments: [account, jid])
        }
    }

    private func avatarFile(_ hash: String) -> URL? {
        avatarDirectories.map { $0.appendingPathComponent(hash) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    private func storeAvatar(_ account: String, _ jid: String, hash: String, image: Data?) {
        if let image, let directory = avatarDirectories.first {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? image.write(to: directory.appendingPathComponent(hash), options: .atomic)
        }
        try? store.db.write { db in
            try db.execute(sql: "INSERT OR REPLACE INTO avatar (account, jid, hash) VALUES (?, ?, ?)",
                           arguments: [account, jid, hash])
        }
        if let file = avatarFile(hash) { emit(["type": "avatar", "jid": jid, "path": file.path]) }
    }

    // MARK: Blocking (XEP-0191)

    func requestBlocklistEmit() {
        emit(["type": "blocklist", "supported": blockingSupported, "list": blocked.sorted()])
    }

    func setBlocked(_ jid: String, _ block: Bool) {
        guard let account = firstAccount, let client = clients[account], connected.contains(account) else { return }
        let iq = StanzaNode("iq", XMPPNS.client, ["type": "set", "id": "block-\(UUID().uuidString)"], [
            StanzaNode(block ? "block" : "unblock", AvatarNS.blocking, [:],
                       [StanzaNode("item", AvatarNS.blocking, ["jid": JID.bare(jid)])]),
        ])
        request(iq, client) { [weak self] reply in
            if reply["type"] == "error" { self?.fail("The server did not accept the change to blocking.") }
        }
    }

    // MARK: Presence, nickname, password

    func setPresence(show: String, status: String) {
        try? store.setSetting("show", show)
        try? store.setSetting("status", status)
        for (account, client) in clients where connected.contains(account) {
            let presence = ownPresence()
            Task { await client.send(presence) }
        }
        requestSelfPresence()
    }

    func requestSelfPresence() {
        emit(["type": "self_presence", "show": ((try? store.setting("show")) ?? nil) ?? "online",
              "status": ((try? store.setting("status")) ?? nil) ?? ""])
    }

    /// Our presence as the user set it (RFC 6121 §4.7).
    private func ownPresence() -> StanzaNode {
        let show = ((try? store.setting("show")) ?? nil) ?? "online"
        let status = ((try? store.setting("status")) ?? nil) ?? ""
        var children: [StanzaNode] = []
        if ["away", "chat", "dnd", "xa"].contains(show) { children.append(StanzaNode("show", XMPPNS.client, text: show)) }
        if !status.isEmpty { children.append(StanzaNode("status", XMPPNS.client, text: status)) }
        return StanzaNode("presence", XMPPNS.client, [:], children)
    }

    func requestAccountDetails() {
        guard let account = firstAccount else { return emit(["type": "signed_out"]) }
        let identity = try? store.db.read { db in
            try Row.fetchOne(db, sql: "SELECT deviceID, publicKey FROM omemoIdentity WHERE account = ?", arguments: [account])
        }
        emit(["type": "account_details", "jid": account,
              "alias": ((try? store.setting("alias:\(account)")) ?? nil) ?? "",
              "omemo_device_id": (identity ?? nil).map { $0["deviceID"] as Int } ?? 0,
              "omemo_fingerprint": (identity ?? nil).map { omemoFingerprint($0["publicKey"]) } ?? ""])
    }

    /// The name shown for ourselves; kept on this device, as before.
    func setAlias(_ alias: String) {
        guard let account = firstAccount else { return }
        try? store.setSetting("alias:\(account)", alias)
        requestAccountDetails()
    }

    /// In-band password change (XEP-0077 §3.3).
    func changePassword(_ password: String) {
        guard let account = firstAccount, let client = clients[account], connected.contains(account) else {
            return fail("Password change failed: not connected")
        }
        let localpart = String(account.split(separator: "@").first ?? "")
        let iq = StanzaNode("iq", XMPPNS.client, ["type": "set", "to": JID.domain(account),
                                                  "id": "password-\(UUID().uuidString)"], [
            StanzaNode("query", AvatarNS.register, [:], [
                StanzaNode("username", AvatarNS.register, text: localpart),
                StanzaNode("password", AvatarNS.register, text: password),
            ]),
        ])
        request(iq, client) { [weak self] reply in
            guard let self else { return }
            if reply["type"] == "result" {
                passwords.setPassword(password, for: account)
                emit(["type": "password_changed"])
            } else {
                let condition = reply.child("error", XMPPNS.client)?.children.first?.name ?? "error"
                fail("Password change failed: \(condition)")
            }
        }
    }

    // MARK: Privacy

    func requestPrivacy() {
        emit(["type": "privacy", "send_typing": privacy("send_typing"), "send_marker": privacy("send_marker")])
    }

    func setPrivacy(_ key: String, _ on: Bool) {
        try? store.setSetting(key, on ? "1" : "0")
        requestPrivacy()
    }

    private func privacy(_ key: String) -> Bool { ((try? store.setting(key)) ?? nil) != "0" }

    /// Account, peer and connection of a one-to-one chat that is online.
    private func chat(_ conversation: Int64) -> (String, String, XMPPClient)? {
        guard let row = try? store.conversationRow(conversation) else { return nil }
        let account: String = row["account"]
        guard let client = clients[account], connected.contains(account) else { return nil }
        return (account, row["jid"], client)
    }

    // MARK: Contacts

    func addContact(jid: String, alias: String?) {
        guard let account = firstAccount, let client = clients[account] else { return }
        let bare = JID.bare(jid)
        var item = ["jid": bare]
        if let alias, !alias.isEmpty { item["name"] = alias }
        let set = StanzaNode("iq", XMPPNS.client, ["type": "set", "id": UUID().uuidString],
                             [StanzaNode("query", ChatNS.roster, [:], [StanzaNode("item", ChatNS.roster, item)])])
        Task {
            await client.send(set)
            await client.send(StanzaNode("presence", XMPPNS.client, ["to": bare, "type": "subscribe"]))
        }
    }

    func removeContact(jid: String) {
        guard let account = firstAccount, let client = clients[account] else { return }
        let remove = StanzaNode("iq", XMPPNS.client, ["type": "set", "id": UUID().uuidString], [
            StanzaNode("query", ChatNS.roster, [:],
                       [StanzaNode("item", ChatNS.roster, ["jid": JID.bare(jid), "subscription": "remove"])]),
        ])
        Task { await client.send(remove) }
    }

    func respondSubscription(jid: String, approve: Bool) {
        guard let account = firstAccount, let client = clients[account] else { return }
        let bare = JID.bare(jid)
        Task {
            if approve {
                await client.send(StanzaNode("presence", XMPPNS.client, ["to": bare, "type": "subscribed"]))
                await client.send(StanzaNode("presence", XMPPNS.client, ["to": bare, "type": "subscribe"]))
            } else {
                await client.send(StanzaNode("presence", XMPPNS.client, ["to": bare, "type": "unsubscribed"]))
            }
        }
    }

    // MARK: Connections

    private var firstAccount: String? {
        (try? store.accounts())?.first { $0.enabled }?.jid
    }

    private func connect(_ jid: String, _ password: String) {
        guard clients[jid] == nil else { return }
        // The account's own resource, the same every launch, so a new session
        // replaces one the server still holds rather than standing beside it
        // (and showing us online twice). The extension keeps its own.
        let stored = forNotifications ? nil : (try? store.accounts())?.first { $0.jid == jid }?.resource
        let client = XMPPClient(jid: jid, password: password, resource: stored ?? resource,
                                streamManagement: !forNotifications)
        clients[jid] = client
        emit(["type": "connection", "account": jid, "state": "CONNECTING"])
        listeners[jid] = Task { [weak self] in
            for await event in client.events {
                self?.handle(event, account: jid, client: client)
            }
        }
        Task {
            await client.setActive(foreground)
            await client.start()
        }
    }

    private func handle(_ event: XMPPClient.Event, account: String, client: XMPPClient) {
        switch event {
        case .connected(let jid, let resumed):
            connected.insert(account)
            boundJIDs[account] = jid
            emit(["type": "connection", "account": account, "state": "CONNECTED"])
            if forNotifications {
                openOMEMO(account, client, publish: false)
                return catchUp(account, client, after: (try? store.mamLastID(account)) ?? nil)
            }
            if !resumed {
                // A new session: contacts' presence arrives afresh. (A resumed
                // one keeps what we knew; the server sends only changes.)
                presence[account] = [:]
                abandonRequests(account)
                sessionStarted(account, client)
                rooms.connected(account, link: .init(
                    send: { stanza in Task { await client.send(stanza) } },
                    request: { [weak self] iq, then in self?.request(iq, client, then: then) }))
            }
            flushPending(account, client)
            let waiting = avatarsWaiting
            avatarsWaiting = []
            waiting.forEach { requestAvatar(jid: $0) }
        case .disconnected:
            connected.remove(account)
            rooms.disconnected(account)
            emit(["type": "connection", "account": account, "state": "DISCONNECTED"])
        case .failed(let failure):
            connected.remove(account)
            abandonRequests(account)
            clients[account] = nil
            let source = if case .notAuthorized = failure { "SASL" } else { "\(failure)" }
            emit(["type": "connection_error", "account": account, "source": source, "message": "\(failure)"])
            emit(["type": "connection", "account": account, "state": "DISCONNECTED"])
        case .stanza(let node):
            receive(node, account: account, client: client)
        }
    }

    /// A new session: fetch the roster (versioned), then come online.
    private func sessionStarted(_ account: String, _ client: XMPPClient) {
        var query = [String: String]()
        query["ver"] = (try? store.rosterVersion(account)) ?? ""
        Task {
            await client.send(StanzaNode("iq", XMPPNS.client, ["type": "get", "id": "roster"],
                                         [StanzaNode("query", ChatNS.roster, query)]))
            await client.send(self.ownPresence())
            await client.send(StanzaNode("iq", XMPPNS.client, ["type": "set", "id": "carbons"],
                                         [StanzaNode("enable", ChatNS.carbons)]))
        }
        openOMEMO(account, client, publish: true)
        findUploadService(account, client)
        catchUp(account, client, after: (try? store.mamLastID(account)) ?? nil)
        request(StanzaNode("iq", XMPPNS.client, ["type": "get", "id": "blocklist-\(UUID().uuidString)"],
                           [StanzaNode("blocklist", AvatarNS.blocking)]), client) { [weak self] reply in
            guard let self else { return }
            blockingSupported = reply["type"] == "result"
            blocked = Set(reply.child("blocklist", AvatarNS.blocking)?.children("item", AvatarNS.blocking)
                .compactMap { $0["jid"] } ?? [])
            requestBlocklistEmit()
        }
    }

    /// `publish`: announce our device and keys (not from the extension, which
    /// only reads).
    private func openOMEMO(_ account: String, _ client: XMPPClient, publish: Bool) {
        if omemo[account] == nil {
            do {
                omemo[account] = try OMEMOCoordinator(
                    store: store, account: account,
                    request: { [weak self] iq, then in self?.request(iq, client, then: then) },
                    send: { stanza in Task { await client.send(stanza) } })
            } catch {
                NSLog("gecko-omemo: cannot open OMEMO for %@: %@", account, "\(error)")
            }
        }
        if publish { omemo[account]?.start() }
    }

    /// Sends `iq` and runs `then` with the answer (result or error).
    private func request(_ iq: StanzaNode, _ client: XMPPClient, then: @escaping (StanzaNode) -> Void) {
        if let id = iq["id"], let account = clients.first(where: { $0.value === client })?.key {
            replies[id] = (account, then)
        }
        Task { await client.send(iq) }
    }

    /// A new session (not a resumed one) or a failure: answers to earlier
    /// requests will never come, so their callers get an error now.
    private func abandonRequests(_ account: String) {
        for (id, waiting) in replies where waiting.account == account {
            replies[id] = nil
            waiting.then(StanzaNode("iq", XMPPNS.client, ["type": "error", "id": id], [
                StanzaNode("error", XMPPNS.client, ["type": "wait"],
                           [StanzaNode("remote-server-timeout", "urn:ietf:params:xml:ns:xmpp-stanzas")]),
            ]))
        }
    }

    /// Fetches what our archive holds since `after` (XEP-0313), page by page;
    /// without a starting point, only the newest page.
    private func catchUp(_ account: String, _ client: XMPPClient, after: String?) {
        let id = "mam-\(UUID().uuidString.lowercased())"
        archiveQueries[id] = account
        let form = StanzaNode("x", "jabber:x:data", ["type": "submit"], [
            StanzaNode("field", "jabber:x:data", ["var": "FORM_TYPE", "type": "hidden"],
                       [StanzaNode("value", "jabber:x:data", text: ChatNS.mam)]),
        ])
        let page = StanzaNode("set", "http://jabber.org/protocol/rsm", [:], [
            StanzaNode("max", "http://jabber.org/protocol/rsm", text: "100"),
            after.map { StanzaNode("after", "http://jabber.org/protocol/rsm", text: $0) }
                ?? StanzaNode("before", "http://jabber.org/protocol/rsm"),
        ])
        Task {
            await client.send(StanzaNode("iq", XMPPNS.client, ["type": "set", "id": id],
                                         [StanzaNode("query", ChatNS.mam, ["queryid": id], [form, page])]))
        }
    }

    /// A page of the archive is in (or the query failed).
    private func archiveFinished(_ node: StanzaNode, account: String, client: XMPPClient) {
        let fin = node.child("fin", ChatNS.mam)
        let last = fin?.child("set", "http://jabber.org/protocol/rsm")?.child("last", "http://jabber.org/protocol/rsm")?.text
        if let last { try? store.setMamLastID(account, last) }
        if let fin, fin["complete"] != "true", let last, ((try? store.mamLastID(account)) ?? nil) != nil {
            return catchUp(account, client, after: last)
        }
        guard forNotifications else { return }
        rooms.catchUpWithoutJoining(account, link: .init(
            send: { stanza in Task { await client.send(stanza) } },
            request: { [weak self] iq, then in self?.request(iq, client, then: then) })) { [weak self] in
            self?.onCaughtUp?()
        }
    }

    /// Ends the extension's session cleanly.
    func stop() async {
        for client in clients.values { await client.stop() }
    }

    /// Unread messages across open conversations (the app icon's badge).
    func unreadTotal() -> Int {
        ((try? store.conversationList()) ?? []).reduce(0) { $0 + ($1["unread"] as? Int ?? 0) }
    }

    /// Messages written while offline go out once connected.
    private func flushPending(_ account: String, _ client: XMPPClient) {
        let pending = (try? store.db.read { db in
            try Row.fetchAll(db, sql: """
                SELECT m.id, m.body, m.originID, m.encryption, c.jid, c.kind, m.conversation,
                       (SELECT state FROM file WHERE message = m.id) AS fileState FROM message m
                JOIN conversation c ON c.id = m.conversation
                WHERE c.account = ? AND m.direction = 'out' AND m.state = 'pending' ORDER BY m.id
                """, arguments: [account])
        }) ?? []
        for row in pending {
            let id: Int64 = row["id"]
            if (row["kind"] as String) == "groupchat" { continue }  // once the room is joined
            if let state = row["fileState"] as String? {
                // Unfinished uploads resume once the upload service is known.
                if state == "complete" { sendFileMessage(id, conversation: row["conversation"]) }
                continue
            }
            if (row["encryption"] as String) == "omemo" {
                sendEncrypted(id)
                continue
            }
            Task {
                await client.send(ChatStanza.outgoing(to: row["jid"], body: row["body"] ?? "",
                                                      id: row["originID"] ?? UUID().uuidString))
            }
            try? store.setState(message: id, "sent")
            emitItem(id)
        }
    }

    /// An OMEMO message to a private room: encrypted for every member's devices.
    private func sendEncryptedToRoom(_ item: Int64, conversation: Int64, account: String) {
        guard let members = rooms.memberJIDs(conversation) else {
            try? store.setState(message: item, "failed")
            emitItem(item)
            return fail("OMEMO works only in private rooms (members only, members' addresses visible).")
        }
        guard let coordinator = omemo[account], let client = clients[account],
              let message = try? store.messageRow(item) else { return }
        let body: String = message["body"] ?? "", id: String = message["originID"] ?? UUID().uuidString
        coordinator.prepare(members + [account]) { [weak self] in
            guard let self else { return }
            guard var stanza = rooms.outgoing(conversation, body: body, id: id),
                  let encrypted = coordinator.encrypt(body, to: members) else {
                try? store.setState(message: item, "failed")
                emitItem(item)
                return fail("No room member has an OMEMO device this message could be encrypted for; it was not sent.")
            }
            stanza.children.removeAll { $0.name == "body" }
            stanza.children += encrypted
            Task { await client.send(stanza) }
            try? store.setState(message: item, "sent")
            emitItem(item)
        }
    }

    /// Room messages written while we were not in the room.
    private func flushRoom(_ conversation: Int64) {
        guard let row = try? store.conversationRow(conversation), let client = clients[row["account"]] else { return }
        let pending = (try? store.db.read { db in
            try Row.fetchAll(db, sql: """
                SELECT id, body, originID, encryption, (SELECT state FROM file WHERE message = message.id) AS fileState
                FROM message WHERE conversation = ? AND direction = 'out' AND state = 'pending' ORDER BY id
                """, arguments: [conversation])
        }) ?? []
        for message in pending {
            if let state = message["fileState"] as String? {
                if state == "complete" { sendFileMessage(message["id"], conversation: conversation) }
                continue
            }
            if (message["encryption"] as String) == "omemo" {
                sendEncryptedToRoom(message["id"], conversation: conversation, account: row["account"])
                continue
            }
            guard let stanza = rooms.outgoing(conversation, body: message["body"] ?? "",
                                              id: message["originID"] ?? UUID().uuidString) else { return }
            Task { await client.send(stanza) }
            try? store.setState(message: message["id"], "sent")
            emitItem(message["id"])
        }
    }

    // MARK: Calls

    /// Our full JID per account, as the server bound it.
    private var boundJIDs: [String: String] = [:]
    /// Jingle sessions that are calls (CallSignaling's), by sid.
    private var callSessions: Set<String> = []

    /// A stanza from CallSignaling. Requests' answers come back as `stanza`
    /// events like everything else it handles.
    func sendStanza(account: String, xml: String) {
        guard let client = clients[account], var node = StanzaNode.parse(xml) else { return }
        if let jingle = node.child("jingle", CallNS.jingle), let sid = jingle["sid"] { trackCall(jingle, sid) }
        guard node.name == "iq", node["type"] == "get" || node["type"] == "set" else {
            Task { await client.send(node) }
            return
        }
        if node["id"] == nil { node.attributes["id"] = UUID().uuidString }
        request(node, client) { [weak self] reply in self?.forwardStanza(reply, account: account) }
    }

    /// Whether the Jingle session is a call, keeping track as calls start and end.
    @discardableResult
    private func trackCall(_ jingle: StanzaNode, _ sid: String) -> Bool {
        if jingle["action"] == "session-initiate", jingle.children("content", CallNS.jingle).contains(where: {
            $0.children.contains { $0.name == "description" && $0.ns == CallNS.rtp }
        }) {
            callSessions.insert(sid)
        }
        let ours = callSessions.contains(sid)
        if jingle["action"] == "session-terminate" { callSessions.remove(sid) }
        return ours
    }

    private func forwardStanza(_ node: StanzaNode, account: String) {
        emit(["type": "stanza", "account": account, "me": boundJIDs[account] ?? "", "xml": node.xml])
    }

    /// A one-to-one call message (XEP-0353), live or our other devices' copy
    /// (carbons); not room or archive messages.
    nonisolated static func callMessage(_ node: StanzaNode, account: String) -> StanzaNode? {
        guard node["type"] != "groupchat", node.child("result", ChatNS.mam) == nil else { return nil }
        var message = node
        if let carbon = node.children.first(where: { $0.ns == ChatNS.carbons && ($0.name == "received" || $0.name == "sent") }) {
            guard JID.bare(node["from"] ?? account) == account,
                  let inner = carbon.child("forwarded", ChatNS.forward)?.child("message", XMPPNS.client) else { return nil }
            message = inner
        }
        return message.children.contains { $0.ns == CallNS.jmi } ? message : nil
    }

    // MARK: Push (XEP-0357)

    private var push: (proxy: String, token: String)?

    /// Registers this device's token with the push service, once: every
    /// earlier registration with that service goes first, as each would make
    /// the server push again.
    func enablePush(proxy: String, token: String) {
        guard let account = firstAccount, let client = clients[account], connected.contains(account) else {
            return emit(["type": "push_state", "enabled": false, "reason": "not connected"])
        }
        let disable = StanzaNode("iq", XMPPNS.client, ["type": "set", "id": "push-off-\(UUID().uuidString)"],
                                 [StanzaNode("disable", Self.pushNS, ["jid": proxy])])
        request(disable, client) { [weak self] _ in
            let enable = StanzaNode("iq", XMPPNS.client, ["type": "set", "id": "push-on-\(UUID().uuidString)"],
                                    [StanzaNode("enable", Self.pushNS, ["jid": proxy, "node": token])])
            self?.request(enable, client) { [weak self] reply in
                guard let self else { return }
                let enabled = reply["type"] == "result"
                if enabled {
                    push = (proxy, token)
                    syncPushFilters()
                }
                emit(["type": "push_state", "enabled": enabled])
            }
        }
    }

    static let pushNS = "urn:xmpp:push:0"

    /// Tells the push service which conversations are muted or mentions-only,
    /// so it can stay quiet for them.
    private func syncPushFilters() {
        guard let push, let account = firstAccount, let client = clients[account] else { return }
        let local = String(account.split(separator: "@").first ?? "")
        var muted: [String] = [], mentionOnly: [(jid: String, nick: String)] = []
        for conversation in (try? store.conversationList()) ?? [] {
            guard let jid = conversation["jid"] as? String, let id = conversation["id"] as? Int64 else { continue }
            switch conversation["notify"] as? String {
            case "off": muted.append(jid)
            case "highlight":
                let nick = (try? store.conversationRow(id))??["nick"] as String?
                mentionOnly.append((jid, nick.flatMap { $0.isEmpty ? nil : $0 } ?? local))
            default: break
            }
        }
        guard let message = Self.pushFilters(to: push.proxy, token: push.token, muted: muted, mentionOnly: mentionOnly)
        else { return }
        Task { await client.send(message) }
    }

    /// The push service's filter message: no body, kept out of archives and
    /// other devices' copies, so no chat client shows it.
    nonisolated static func pushFilters(to proxy: String, token: String, muted: [String],
                            mentionOnly: [(jid: String, nick: String)]) -> StanzaNode? {
        let rules: [String: Any] = ["gecko-push-filters": 1, "token": token, "muted": muted,
                                    "mention_only": mentionOnly.map { ["jid": $0.jid, "nick": $0.nick] }]
        guard let data = try? JSONSerialization.data(withJSONObject: rules, options: .sortedKeys),
              let json = String(data: data, encoding: .utf8) else { return nil }
        return StanzaNode("message", XMPPNS.client, ["to": proxy, "type": "normal"], [
            StanzaNode("filters", "urn:gecko:push:filters", text: json),
            StanzaNode("no-store", "urn:xmpp:hints"),
            StanzaNode("no-copy", "urn:xmpp:hints"),
        ])
    }

    // MARK: Files

    private func findUploadService(_ account: String, _ client: XMPPClient) {
        let domain = JID.domain(account)
        request(StanzaNode("iq", XMPPNS.client, ["type": "get", "to": domain, "id": "items-\(UUID().uuidString)"],
                           [StanzaNode("query", "http://jabber.org/protocol/disco#items")]), client) { [weak self] reply in
            let items = reply.child("query", "http://jabber.org/protocol/disco#items")?
                .children("item", "http://jabber.org/protocol/disco#items").compactMap { $0["jid"] } ?? []
            for jid in [domain] + items {
                self?.request(StanzaNode("iq", XMPPNS.client, ["type": "get", "to": jid, "id": "info-\(UUID().uuidString)"],
                                         [StanzaNode("query", Disco.info)]), client) { [weak self] info in
                    guard let self, let limit = FileSharing.maxSize(info), uploadServices[account] == nil else { return }
                    uploadServices[account] = (jid, limit)
                    resumeUploads(account)
                }
            }
        }
    }

    /// Whether a file can go to this chat (only through the server now).
    func previewFileTransport(_ conversation: Int64, path: String, requestID: String) {
        var answer: [String: Any] = ["type": "file_transport", "conversation": conversation, "request_id": requestID]
        let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64) ?? nil
        let account = (try? store.conversationRow(conversation))??["account"] as String?
        if let account, let service = uploadServices[account] {
            if let limit = service.limit, let size, size > limit {
                answer["transport"] = "none"
                answer["message"] = "This file is \(Self.megabytes(size)); your server accepts up to \(Self.megabytes(limit))."
            } else {
                answer["transport"] = "http"
            }
        } else {
            answer["transport"] = "none"
            answer["message"] = "Your server does not offer file uploads, or Gecko is not connected."
        }
        emit(answer)
    }

    private static func megabytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// Copies the file in, shows it as sending, and uploads it.
    func sendFile(_ conversation: Int64, path: String) {
        guard let row = try? store.conversationRow(conversation), let root = store.fileRoots.first else { return }
        let source = URL(fileURLWithPath: path)
        let name = source.lastPathComponent
        let stored = "\(UUID().uuidString.prefix(8).lowercased())_\(name)"
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: source, to: root.appendingPathComponent(stored))
            let size = (try FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64) ?? 0
            guard let item = try store.insert(.init(
                conversation: conversation, direction: "out", sender: row["account"], body: nil, time: Date(),
                originID: UUID().uuidString.lowercased(), encryption: row["encryption"], state: "pending")) else { return }
            try store.attach(.init(url: nil, name: name, mime: Self.mime(name), size: size, path: stored,
                                   state: "inProgress"), to: item)
            emitItem(item)
            pushConversations()
            startUpload(item, conversation: conversation)
        } catch {
            fail("The file could not be sent: \(error.localizedDescription)")
        }
    }

    private static func mime(_ name: String) -> String {
        UTType(filenameExtension: (name as NSString).pathExtension)?.preferredMIMEType ?? "application/octet-stream"
    }

    private func startUpload(_ item: Int64, conversation: Int64) {
        guard uploading.insert(item).inserted else { return }
        Task {
            await upload(item, conversation: conversation, attempts: 3)
            uploading.remove(item)
        }
    }

    /// Files still waiting to upload when the account comes back.
    private func resumeUploads(_ account: String) {
        let waiting = (try? store.db.read { db in
            try Row.fetchAll(db, sql: """
                SELECT m.id, m.conversation FROM message m JOIN conversation c ON c.id = m.conversation
                JOIN file f ON f.message = m.id
                WHERE c.account = ? AND m.direction = 'out' AND m.state = 'pending' AND f.state != 'complete'
                """, arguments: [account])
        }) ?? []
        for row in waiting { startUpload(row["id"], conversation: row["conversation"]) }
    }

    private func upload(_ item: Int64, conversation: Int64, attempts: Int) async {
        guard let row = try? store.conversationRow(conversation), let file = try? store.fileRow(item),
              let local = store.file(file["path"]), var data = try? Data(contentsOf: local) else { return failUpload(item) }
        let account: String = row["account"], encrypted = (row["encryption"] as String) == "omemo"
        // Offline: it stays pending and goes once connected (resumeUploads).
        guard let client = clients[account], connected.contains(account), let service = uploadServices[account] else {
            return
        }
        // ponytail: the whole file is held in memory (up to the server's limit,
        // often 100 MB); stream it if bigger files become common.
        var secret: FileSharing.Secret?
        if encrypted {
            guard let sealed = try? FileSharing.encrypt(data) else { return failUpload(item) }
            (data, secret) = (sealed.sealed, sealed.secret)
        }
        let name: String = file["name"], mime: String = file["mime"] ?? "application/octet-stream"
        let slotReply: StanzaNode = await withCheckedContinuation { done in
            request(FileSharing.slotRequest(to: service.jid, name: name, size: Int64(data.count), type: mime,
                                            id: "slot-\(UUID().uuidString)"), client) { done.resume(returning: $0) }
        }
        guard let slot = FileSharing.slot(slotReply) else {
            // A dropped connection waits for the next one; a refusal is final.
            if slotReply.child("error", XMPPNS.client)?["type"] == "wait" { return }
            return failUpload(item)
        }
        let total = Int64(data.count)
        guard cancelledTransfers.remove(item) == nil else { return failUpload(item) }
        let stored = await transfers.upload(data, to: slot, type: mime, key: item) { [weak self] sent, _ in
            self?.emit(["type": "file_progress", "conversation": conversation, "item": item,
                        "transferred_bytes": sent, "total_bytes": total])
        }
        guard stored else {
            if cancelledTransfers.remove(item) == nil, attempts > 1 {
                return await upload(item, conversation: conversation, attempts: attempts - 1)
            }
            return failUpload(item)
        }
        let link = secret.map { FileSharing.aesgcmLink(slot.get, $0) } ?? slot.get.absoluteString
        try? store.setBody(message: item, link)
        try? store.updateFile(item, "url", link)
        try? store.updateFile(item, "state", "complete")
        sendFileMessage(item, conversation: conversation)
    }

    /// The message sharing an uploaded file; stays pending (and is flushed
    /// later) when the account or room is not reachable now.
    private func sendFileMessage(_ item: Int64, conversation: Int64) {
        guard let row = try? store.conversationRow(conversation), let message = try? store.messageRow(item),
              let link = message["body"] as String? else { return }
        let account: String = row["account"], room = (row["kind"] as String) == "groupchat"
        if (row["encryption"] as String) == "omemo" {
            return room ? sendEncryptedToRoom(item, conversation: conversation, account: account) : sendEncrypted(item)
        }
        guard let client = clients[account], connected.contains(account) else { return }
        let id: String = message["originID"] ?? UUID().uuidString
        guard var stanza = room ? rooms.outgoing(conversation, body: link, id: id)
                                : ChatStanza.outgoing(to: row["jid"], body: link, id: id) else { return }
        stanza.children.append(StanzaNode("x", ChatNS.oob, [:], [StanzaNode("url", ChatNS.oob, text: link)]))
        Task { await client.send(stanza) }
        try? store.setState(message: item, "sent")
        emitItem(item)
    }

    private func failUpload(_ item: Int64) {
        try? store.updateFile(item, "state", "failed")
        try? store.setState(message: item, "failed")
        emitItem(item)
    }

    /// Stops an upload (it is not sent) or a download (what arrived is kept
    /// for the next try).
    func cancelTransfer(_ item: Int64) {
        guard uploading.contains(item) || downloading.contains(item) else { return }
        cancelledTransfers.insert(item)
        transfers.cancel(item)
    }

    /// Fetches (and for OMEMO, decrypts) a shared file, resuming a download
    /// that stopped part way.
    func downloadFile(_ conversation: Int64, item: Int64) {
        guard let file = try? store.fileRow(item), let link = file["url"] as String?,
              let root = store.fileRoots.first, downloading.insert(item).inserted else { return }
        let encrypted = FileSharing.parseAesgcm(link)
        guard let url = encrypted?.url ?? URL(string: link), url.scheme == "https" else {
            downloading.remove(item)
            return
        }
        let partials = root.appendingPathComponent(".partial", isDirectory: true)
        let partial = partials.appendingPathComponent(String(item))
        try? store.updateFile(item, "state", "inProgress")
        emitItem(item)
        Task {
            defer { downloading.remove(item) }
            try? FileManager.default.createDirectory(at: partials, withIntermediateDirectories: true)
            let fetched = await transfers.download(url, to: partial, key: item) { [weak self] received, total in
                self?.emit(["type": "file_progress", "conversation": conversation, "item": item,
                            "transferred_bytes": received, "total_bytes": total.map { $0 as Any } ?? NSNull()])
            }
            let cancelled = cancelledTransfers.remove(item) != nil
            guard fetched else {
                try? store.updateFile(item, "state", "notStarted")
                emitItem(item)
                if !cancelled { emit(["type": "download_failed", "conversation": conversation, "item": item]) }
                return
            }
            let name = "\(UUID().uuidString.prefix(8).lowercased())_\(file["name"] as String)"
            let target = root.appendingPathComponent(name)
            do {
                if let secret = encrypted?.secret {
                    // The whole file is in: a failed tag means bad bytes, so the next try starts over.
                    defer { try? FileManager.default.removeItem(at: partial) }
                    try FileSharing.decrypt(Data(contentsOf: partial), secret).write(to: target, options: .atomic)
                } else {
                    try FileManager.default.moveItem(at: partial, to: target)
                }
                let size = (try FileManager.default.attributesOfItem(atPath: target.path)[.size] as? Int64) ?? 0
                try store.updateFile(item, "path", name)
                try store.updateFile(item, "size", size)
                try store.updateFile(item, "state", "complete")
            } catch {
                try? store.updateFile(item, "state", "notStarted")
                emit(["type": "download_failed", "conversation": conversation, "item": item])
            }
            emitItem(item)
        }
    }

    /// A message that only shares a file becomes a file item (images fetched at once).
    func shareFile(_ item: Int64, conversation: Int64, link: String) {
        let name = FileSharing.name(of: link)
        try? store.attach(.init(url: link, name: name, mime: Self.mime(name), size: nil, path: nil, state: "notStarted",
                                aesgcm: link.split(separator: "#").dropFirst().first.map(String.init)), to: item)
        if UTType(filenameExtension: (name as NSString).pathExtension)?.conforms(to: .image) == true {
            downloadFile(conversation, item: item)
        }
    }

    // MARK: Group chats

    /// Joins an existing room; for one that does not exist yet, asks the user
    /// first (it would be created).
    func joinMuc(jid: String, nick: String?) {
        guard let account = firstAccount, let client = clients[account], connected.contains(account) else {
            return fail("Could not join: not connected")
        }
        let room = JID.bare(jid).lowercased()
        request(StanzaNode("iq", XMPPNS.client, ["type": "get", "to": room, "id": "probe-\(UUID().uuidString)"],
                           [StanzaNode("query", Disco.info)]), client) { [weak self] reply in
            if MUC.info(reply).exists {
                self?.rooms.join(account, room, nick: nick, password: nil)
            } else {
                self?.emit(["type": "confirm_create_muc", "jid": room, "nick": nick ?? ""])
            }
        }
    }

    func createMuc(jid: String, nick: String?) {
        guard let account = firstAccount else { return }
        rooms.join(account, jid, nick: nick, password: nil)
    }

    func acceptMucInvite(account: String, room: String, password: String?) {
        rooms.join(account, room, nick: nil, password: password, invited: true)
    }

    func requestOccupants(_ conversation: Int64) { rooms.requestOccupants(conversation) }
    func mucKick(_ conversation: Int64, nick: String) { rooms.kick(conversation, nick: nick) }
    func mucSetRole(_ conversation: Int64, nick: String, role: String) { rooms.setRole(conversation, nick: nick, role: role) }
    func mucSetAffiliation(_ conversation: Int64, jid: String, affiliation: String) {
        rooms.setAffiliation(conversation, jid: jid, affiliation: affiliation)
    }
    func mucSetName(_ conversation: Int64, _ name: String) {
        rooms.configure(conversation, ["muc#roomconfig_roomname": name])
    }
    /// Private: members only, and members' real JIDs visible to all (needed for OMEMO).
    func mucSetPrivate(_ conversation: Int64, _ on: Bool) {
        rooms.configure(conversation, ["muc#roomconfig_membersonly": on ? "1" : "0",
                                       "muc#roomconfig_whois": on ? "anyone" : "moderators"])
    }
    func mucSetModerated(_ conversation: Int64, _ on: Bool) {
        rooms.configure(conversation, ["muc#roomconfig_moderatedroom": on ? "1" : "0"])
    }
    func mucSetAvatar(_ conversation: Int64, path: String) {
        guard let (jid, png) = rooms.setAvatar(conversation, path: path), let account = firstAccount else { return }
        storeAvatar(account, jid, hash: Avatars.sha1(png), image: png)
    }
    func requestRoomInfo(_ conversation: Int64) { rooms.requestInfo(conversation) }
    func mucInvite(_ conversation: Int64, jid: String) { rooms.invite(conversation, jid) }
    func mucSetSubject(_ conversation: Int64, _ subject: String) { rooms.setSubject(conversation, subject) }

    func startRoomMemberDM(_ conversation: Int64, jid: String) {
        guard let chat = rooms.privateChat(conversation, with: jid) else { return }
        pushConversations()
        emit(["type": "open_conversation", "id": chat])
    }

    // MARK: Incoming

    private func receive(_ node: StanzaNode, account: String, client: XMPPClient) {
        switch node.name {
        case "iq": iq(node, account: account, client: client)
        case "presence": presence(node, account: account)
        case "message": message(node, account: account, client: client)
        default: break
        }
    }

    private func iq(_ node: StanzaNode, account: String, client: XMPPClient) {
        let type = node["type"] ?? ""
        if type == "result" || type == "error" {
            if let id = node["id"], let reply = replies.removeValue(forKey: id) {
                reply.then(node)
                return
            }
            if let id = node["id"], archiveQueries.removeValue(forKey: id) != nil {
                archiveFinished(node, account: account, client: client)
                return
            }
            if node["id"] == "roster", type == "result" {
                // An empty result means the stored roster is current.
                if let query = node.child("query", ChatNS.roster) {
                    try? store.storeRoster(account, items: RosterItem.items(of: query), version: query["ver"],
                                           replace: true)
                }
                pushRoster()
                pushConversations()
            }
            return
        }
        let from = node["from"]
        if type == "set", let query = node.child("query", ChatNS.roster) {
            // Pushes are only believed from our own account (RFC 6121 §2.1.6).
            guard from == nil || JID.bare(from!) == account else { return }
            try? store.storeRoster(account, items: RosterItem.items(of: query), version: query["ver"], replace: false)
            Task { await client.send(StanzaNode("iq", XMPPNS.client, ["type": "result", "id": node["id"] ?? ""])) }
            pushRoster()
            pushConversations()
            return
        }
        if type == "set", from == nil || JID.bare(from!) == account,
           let push = node.children.first(where: { $0.ns == AvatarNS.blocking }) {
            let jids = push.children("item", AvatarNS.blocking).compactMap { $0["jid"] }
            if push.name == "block" { blocked.formUnion(jids) }
            if push.name == "unblock" { jids.isEmpty ? blocked.removeAll() : blocked.subtract(jids) }
            Task { await client.send(StanzaNode("iq", XMPPNS.client, ["type": "result", "id": node["id"] ?? ""])) }
            requestBlocklistEmit()
            return
        }
        if type == "set", let jingle = node.child("jingle", CallNS.jingle), let sid = jingle["sid"],
           trackCall(jingle, sid) {
            return forwardStanza(node, account: account)
        }
        if type == "get", let query = node.child("query", Disco.info) {
            var reply = ["type": "result", "id": node["id"] ?? ""]
            reply["to"] = from
            Task { await client.send(StanzaNode("iq", XMPPNS.client, reply, [Disco.ours(node: query["node"])])) }
            return
        }
        // Anything else we do not do (RFC 6120 §8.2.3).
        var error = ["type": "error", "id": node["id"] ?? ""]
        error["to"] = from
        Task {
            await client.send(StanzaNode("iq", XMPPNS.client, error, [
                StanzaNode("error", XMPPNS.client, ["type": "cancel"],
                           [StanzaNode("service-unavailable", "urn:ietf:params:xml:ns:xmpp-stanzas")]),
            ]))
        }
    }

    private func presence(_ node: StanzaNode, account: String) {
        if rooms.presence(node) { return }
        guard let from = node["from"] else { return }
        let bare = JID.bare(from)
        switch node["type"] {
        case "subscribe":
            emit(["type": "subscription_request", "account": account, "jid": bare])
        case "unavailable":
            presence[account, default: [:]][bare]?[JID.resource(from) ?? ""] = nil
            pushRoster()
        case nil:
            let show = node.child("show", XMPPNS.client)?.text ?? "online"
            presence[account, default: [:]][bare, default: [:]][JID.resource(from) ?? ""] = show
            pushRoster()
        default:
            break  // subscribed / unsubscribed: the roster push that follows says it
        }
    }

    private func message(_ node: StanzaNode, account: String, client: XMPPClient) {
        if let call = Self.callMessage(node, account: account) { forwardStanza(call, account: account) }
        if rooms.invitation(node, account: account) || rooms.message(node, account: account) { return }
        guard let m = ChatStanza.parse(node, me: account), m.type == "chat" || m.type == "normal" else { return }
        let other = m.sentByUs ? m.to : m.from
        // A private message through a room keeps the member's room JID.
        let viaRoom = rooms.isRoom(other) && JID.resource(other) != nil
        let peer = viaRoom ? other : JID.bare(other)
        guard peer != account || !m.sentByUs,
              let conversation = try? store.conversation(account: account, jid: peer,
                                                         kind: viaRoom ? "groupchatPrivate" : "chat")
        else { return }
        let sender = m.sentByUs ? account : peer
        if let receipt = m.receiptFor {
            updateState(account: account, peer: peer, originID: receipt, to: "received")
        }
        if let marker = m.marker, let target = try? store.message(conversation, originID: marker.id) {
            if !m.sentByUs, marker.name == "displayed" {
                for id in (try? store.markRead(conversation: conversation, upTo: target["id"])) ?? [] { emitItem(id) }
            } else if !m.sentByUs, marker.name == "received" {
                updateState(account: account, peer: peer, originID: marker.id, to: "received")
            } else if m.sentByUs, marker.name == "displayed" {
                // Read on another of our devices.
                try? store.update(conversation: conversation, "readUpTo", target["id"] as Int64)
                pushConversations()
            }
        }
        if let state = m.chatState, !m.sentByUs, !m.archived, m.body == nil {
            emit(["type": "chat_state", "conversation": conversation, "state": state])
        }
        if let replaces = m.replaces {
            // Only the author can correct a message.
            if let body = m.body, let target = try? store.message(conversation, originID: replaces, sender: sender) {
                try? store.correct(message: target["id"], body: body)
                emitItem(target["id"])
                pushConversations()
            }
            return
        }
        if let reaction = m.reaction {
            if let target = try? store.message(conversation, originID: reaction.id) {
                try? store.setReactions(message: target["id"], sender: sender, emojis: reaction.emojis)
                emitItem(target["id"])
            }
            return
        }
        if let devices = OMEMOStanzas.devices(node), let from = node["from"] {
            omemo[account]?.devicesChanged(JID.bare(from), devices)
        }
        var body = m.body
        if let encrypted = m.omemo {
            // Decrypting a message twice breaks the session: skip what we have,
            // by archive id or by the sender's own id.
            let known = [m.serverID.map { (id: $0, sender: String?.none) }, m.originID.map { (id: $0, sender: Optional(sender)) }]
                .compactMap { $0 }
                .contains { (try? store.message(conversation, originID: $0.id, sender: $0.sender)) != nil }
            if known { return }
            switch omemo[account]?.decrypt(encrypted, from: sender, live: !m.archived) {
            case .text(let text): body = text
            case .failed(let why)?: NSLog("gecko-omemo: undecryptable message from %@: %@", sender, why); return
            default: return
            }
        }
        guard let body, !body.isEmpty else { return }
        do {
            guard let item = try store.insert(.init(
                conversation: conversation, direction: m.sentByUs ? "out" : "in", sender: sender, body: body,
                time: m.delay ?? Date(), originID: m.originID, serverID: m.serverID,
                encryption: m.omemo == nil ? "none" : "omemo", state: m.sentByUs ? "sent" : "none")) else { return }
            if let link = FileSharing.sharedLink(body: body, oob: m.url) {
                shareFile(item, conversation: conversation, link: link)
            }
            if let reply = m.replyTo {
                let target = try store.message(conversation, originID: reply.id)
                try store.setReply(message: item, to: target?["id"], targetID: reply.id, targetSender: reply.jid)
            }
            if m.requestsReceipt, !m.sentByUs, !m.archived, let id = m.id {
                Task {
                    await client.send(StanzaNode("message", XMPPNS.client, ["to": m.from, "id": UUID().uuidString],
                                                 [StanzaNode("received", ChatNS.receipts, ["id": id])]))
                }
            }
            emitItem(item, synced: m.archived)
            if focused == conversation { markRead(conversation) }
            pushConversations()
        } catch {
            fail("\(error)")
        }
    }

    private func updateState(account: String, peer: String, originID: String, to state: String) {
        let id = try? store.db.read { db in
            try Int64.fetchOne(db, sql: """
                SELECT m.id FROM message m JOIN conversation c ON c.id = m.conversation
                WHERE c.account = ? AND c.jid = ? AND m.originID = ? AND m.direction = 'out'
                """, arguments: [account, peer, originID])
        }
        guard let id = id ?? nil else { return }
        try? store.setState(message: id, state)
        emitItem(id)
    }

    private func markRead(_ conversation: Int64) {
        let last = try? store.db.read { db in
            try Int64.fetchOne(db, sql: "SELECT max(id) FROM message WHERE conversation = ?", arguments: [conversation])
        }
        guard let last = last ?? nil else { return }
        try? store.update(conversation: conversation, "readUpTo", last)
        pushConversations()
        sendDisplayed(conversation)
    }

    /// Tells the peer we have seen their newest message (XEP-0333).
    private func sendDisplayed(_ conversation: Int64) {
        guard privacy("send_marker"), let (_, jid, client) = chat(conversation) else { return }
        let newest = try? store.db.read { db in
            try Row.fetchOne(db, sql: """
                SELECT id, originID FROM message WHERE conversation = ? AND direction = 'in' AND originID IS NOT NULL
                ORDER BY id DESC LIMIT 1
                """, arguments: [conversation])
        }
        guard let newest = newest ?? nil, let originID = newest["originID"] as String?,
              displayedSent[conversation] != newest["id"] else { return }
        displayedSent[conversation] = newest["id"]
        Task {
            await client.send(StanzaNode("message", XMPPNS.client, ["to": jid, "type": "chat", "id": UUID().uuidString],
                                         [StanzaNode("displayed", ChatNS.markers, ["id": originID]),
                                          StanzaNode("store", ChatNS.hints)]))
        }
    }

    // MARK: Events

    /// `synced`: it came from the archive (catching up), not live, so it does
    /// not notify.
    private func emitItem(_ id: Int64, synced: Bool = false) {
        guard var item = try? store.item(id) else { return }
        item["synced"] = synced
        emit(item)
    }

    private func pushConversations() {
        emit(["type": "conversations", "list": (try? store.conversationList()) ?? []])
    }

    private func pushRoster() {
        let list = ((try? store.contacts()) ?? []).map { contact -> [String: Any] in
            let shows = presence[contact.account]?[contact.jid]?.values.map { $0 } ?? []
            let show = shows.contains("online") || shows.contains("chat") ? "online" : shows.first ?? "offline"
            return ["account": contact.account, "jid": contact.jid, "name": contact.name ?? "",
                    "subscription": contact.subscription, "show": show]
        }
        emit(["type": "roster", "list": list])
    }

    private func fail(_ message: String) {
        emit(["type": "error", "message": message])
    }
}

/// Service discovery (XEP-0030) of this client, as far as the Swift core
/// implements things so far.
enum Disco {
    static let info = "http://jabber.org/protocol/disco#info"

    static let features = [info, ChatNS.receipts, XMPPNS.ping, ChatNS.chatStates, ChatNS.markers,
                           ChatNS.correction, ChatNS.reply, ChatNS.reactions, CallNS.jmi] + CallNS.features

    static func ours(node: String?) -> StanzaNode {
        var attributes = [String: String]()
        attributes["node"] = node
        return StanzaNode("query", info, attributes,
                          [StanzaNode("identity", info, ["category": "client", "type": "phone", "name": "Gecko"])]
                          + features.map { StanzaNode("feature", info, ["var": $0]) })
    }
}
