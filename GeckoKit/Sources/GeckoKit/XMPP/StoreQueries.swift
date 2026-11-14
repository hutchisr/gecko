import Foundation
import GRDB

/// What the Swift core reads and writes, shaped as the app's events expect
/// them (see `AppModel.handle`).
extension GeckoStore {
    // MARK: Accounts and contacts

    func accounts() throws -> [(jid: String, resource: String, enabled: Bool)] {
        try db.read { db in
            try Row.fetchAll(db, sql: "SELECT jid, resource, enabled FROM account ORDER BY jid").map {
                ($0["jid"], $0["resource"], $0["enabled"])
            }
        }
    }

    func addAccount(_ jid: String, resource: String) throws {
        try db.write { db in
            try db.execute(sql: """
                INSERT INTO account (jid, resource) VALUES (?, ?) ON CONFLICT(jid) DO UPDATE SET enabled = 1
                """, arguments: [jid, resource])
        }
    }

    func setEnabled(_ jid: String, _ enabled: Bool) throws {
        try db.write { try $0.execute(sql: "UPDATE account SET enabled = ? WHERE jid = ?", arguments: [enabled, jid]) }
    }

    func rosterVersion(_ account: String) throws -> String? {
        try db.read { try String.fetchOne($0, sql: "SELECT rosterVersion FROM account WHERE jid = ?", arguments: [account]) }
    }

    /// A full roster (replacing what was stored) or one push (`replace` false).
    func storeRoster(_ account: String, items: [RosterItem], version: String?, replace: Bool) throws {
        try db.write { db in
            if replace { try db.execute(sql: "DELETE FROM contact WHERE account = ?", arguments: [account]) }
            for item in items {
                if item.subscription == "remove" {
                    try db.execute(sql: "DELETE FROM contact WHERE account = ? AND jid = ?", arguments: [account, item.jid])
                } else {
                    try db.execute(sql: """
                        INSERT INTO contact (account, jid, name, subscription, ask) VALUES (?, ?, ?, ?, ?)
                        ON CONFLICT(account, jid) DO UPDATE SET name = excluded.name,
                            subscription = excluded.subscription, ask = excluded.ask
                        """, arguments: [account, item.jid, item.name, item.subscription, item.ask])
                }
            }
            if let version {
                try db.execute(sql: "UPDATE account SET rosterVersion = ? WHERE jid = ?", arguments: [version, account])
            }
        }
    }

    func contacts() throws -> [(account: String, jid: String, name: String?, subscription: String)] {
        try db.read { db in
            try Row.fetchAll(db, sql: """
                SELECT c.* FROM contact c JOIN account a ON a.jid = c.account WHERE a.enabled ORDER BY c.jid
                """).map { ($0["account"], $0["jid"], $0["name"], $0["subscription"]) }
        }
    }

    // MARK: Conversations

    /// The open conversation with `jid`, created (or reopened) when needed.
    func conversation(account: String, jid: String, kind: String = "chat") throws -> Int64 {
        try db.write { db in
            try db.execute(sql: """
                INSERT INTO conversation (account, jid, kind, lastActive) VALUES (?, ?, ?, ?)
                ON CONFLICT(account, jid, kind) DO UPDATE SET open = 1
                """, arguments: [account, jid, kind, Date()])
            return try Int64.fetchOne(db, sql: "SELECT id FROM conversation WHERE account = ? AND jid = ? AND kind = ?",
                                      arguments: [account, jid, kind]) ?? 0
        }
    }

    /// The conversation with `jid`, if there is one; never creates or reopens it.
    func existingConversation(account: String, jid: String, kind: String) throws -> Int64? {
        try db.read { db in
            try Int64.fetchOne(db, sql: "SELECT id FROM conversation WHERE account = ? AND jid = ? AND kind = ?",
                               arguments: [account, jid, kind])
        }
    }

    func conversationRow(_ id: Int64) throws -> Row? {
        try db.read { try Row.fetchOne($0, sql: "SELECT * FROM conversation WHERE id = ?", arguments: [id]) }
    }

    func update(conversation id: Int64, _ column: String, _ value: DatabaseValueConvertible?) throws {
        // Column names come from this module only.
        try db.write { try $0.execute(sql: "UPDATE conversation SET \(column) = ? WHERE id = ?", arguments: [value, id]) }
    }

    /// The `conversations` event's list: open conversations of enabled accounts.
    func conversationList() throws -> [[String: Any]] {
        try db.read { db in
            try Row.fetchAll(db, sql: """
                SELECT c.*, k.name AS contactName,
                    (SELECT value FROM setting WHERE key = 'roomName:' || c.jid) AS roomName,
                    (SELECT value FROM setting WHERE key = 'roomPrivate:' || c.jid) AS roomPrivate,
                    (SELECT count(*) FROM message m WHERE m.conversation = c.id AND m.direction = 'in'
                        AND NOT m.hidden AND m.id > coalesce(c.readUpTo, 0)) AS unread,
                    l.body AS lastBody, l.direction AS lastDirection, l.time AS lastTime,
                    (SELECT 1 FROM file f WHERE f.message = l.id) AS lastIsFile
                FROM conversation c JOIN account a ON a.jid = c.account AND a.enabled
                LEFT JOIN contact k ON k.account = c.account AND k.jid = c.jid
                LEFT JOIN message l ON l.id = (SELECT id FROM message WHERE conversation = c.id AND NOT hidden
                                               ORDER BY time DESC, id DESC LIMIT 1)
                WHERE c.open
                """).map { row in
                let jid: String = row["jid"]
                let kind: String = row["kind"]
                let notify: String = row["notify"]
                let time = (row["lastTime"] as Date?) ?? (row["lastActive"] as Date?) ?? Date(timeIntervalSince1970: 0)
                return [
                    "id": row["id"] as Int64, "account": row["account"] as String, "jid": jid,
                    "name": [row["contactName"] as String?, row["roomName"] as String?]
                        .compactMap { $0 }.first { !$0.isEmpty } ?? jid,
                    "encryption": (row["encryption"] as String) == "omemo" ? "OMEMO" : "NONE",
                    // A room only when private: OMEMO needs its members' real JIDs.
                    "encryption_available": kind == "chat" || (kind == "groupchat" && row["roomPrivate"] as String? == "1"),
                    "kind": kind == "groupchat" ? "groupchat" : "chat",
                    "unread": row["unread"] as Int,
                    "preview": (row["lastIsFile"] as Int?) != nil ? "[file]" : (row["lastBody"] as String? ?? ""),
                    "preview_direction": row["lastDirection"] as String? ?? "",
                    "time": Int(time.timeIntervalSince1970),
                    "notify": notify,
                    "notify_effective": notify,
                ] as [String: Any]
            }
        }
    }

    // MARK: Messages

    struct NewMessage {
        var conversation: Int64
        var direction: String
        var sender: String
        var body: String?
        var time: Date
        var originID: String?
        var serverID: String?
        var encryption = "none"
        var state = "none"
    }

    /// Stores a message; nil when it is already there (same archive id, or
    /// our own message coming back with the same origin id).
    func insert(_ m: NewMessage) throws -> Int64? {
        try db.write { db in
            // The same message again (a carbon, an archive copy of a live one,
            // our own message echoed back): same sender, same origin id.
            if let originID = m.originID,
               try Bool.fetchOne(db, sql: """
                SELECT 1 FROM message WHERE conversation = ? AND originID = ? AND direction = ? AND sender = ?
                """, arguments: [m.conversation, originID, m.direction, m.sender]) == true {
                return nil
            }
            try db.execute(sql: """
                INSERT INTO message (conversation, direction, sender, body, time, localTime, originID, serverID,
                                     encryption, state)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?) ON CONFLICT DO NOTHING
                """, arguments: [m.conversation, m.direction, m.sender, m.body, m.time, Date(), m.originID,
                                 m.serverID, m.encryption, m.state])
            guard db.changesCount > 0 else { return nil }
            let id = db.lastInsertedRowID
            try db.execute(sql: "UPDATE conversation SET lastActive = ?, open = 1 WHERE id = ?",
                           arguments: [m.time, m.conversation])
            return id
        }
    }

    /// A message of this conversation by the id its sender gave it.
    func message(_ conversation: Int64, originID: String, sender: String? = nil) throws -> Row? {
        try db.read { db in
            try Row.fetchOne(db, sql: """
                SELECT * FROM message WHERE conversation = ? AND (originID = ? OR serverID = ?)
                    AND (? IS NULL OR sender = ?) ORDER BY id DESC LIMIT 1
                """, arguments: [conversation, originID, originID, sender, sender])
        }
    }

    func messageRow(_ id: Int64) throws -> Row? {
        try db.read { try Row.fetchOne($0, sql: "SELECT * FROM message WHERE id = ?", arguments: [id]) }
    }

    /// A correction (XEP-0308): the new text, keeping the original's place.
    func correct(message id: Int64, body: String) throws {
        try db.write { try $0.execute(sql: "UPDATE message SET body = ?, edited = 1 WHERE id = ?", arguments: [body, id]) }
    }

    func setReply(message id: Int64, to target: Int64?, targetID: String, targetSender: String?) throws {
        try db.write { db in
            try db.execute(sql: "UPDATE message SET replyTo = ?, replyToID = ?, replyToSender = ? WHERE id = ?",
                           arguments: [target, targetID, targetSender, id])
        }
    }

    /// `sender`'s whole current reaction set to a message (XEP-0444 sends it whole).
    func setReactions(message id: Int64, sender: String, emojis: [String]) throws {
        try db.write { db in
            if emojis.isEmpty {
                try db.execute(sql: "DELETE FROM reaction WHERE message = ? AND sender = ?", arguments: [id, sender])
            } else {
                try db.execute(sql: "INSERT OR REPLACE INTO reaction (message, sender, emojis, time) VALUES (?, ?, ?, ?)",
                               arguments: [id, sender, emojis.joined(separator: " "), Date()])
            }
        }
    }

    func reactions(message id: Int64, sender: String) throws -> [String] {
        try db.read { db in
            (try String.fetchOne(db, sql: "SELECT emojis FROM reaction WHERE message = ? AND sender = ?",
                                 arguments: [id, sender]))?.split(separator: " ").map(String.init) ?? []
        }
    }

    /// Our messages up to and including `id` that the peer has now read;
    /// returns those whose state changed.
    func markRead(conversation: Int64, upTo id: Int64) throws -> [Int64] {
        try db.write { db in
            let changed = try Int64.fetchAll(db, sql: """
                SELECT id FROM message WHERE conversation = ? AND direction = 'out' AND id <= ? AND state != 'read'
                    AND state != 'failed'
                """, arguments: [conversation, id])
            try db.execute(sql: "UPDATE message SET state = 'read' WHERE id IN (\(changed.map(String.init).joined(separator: ",")))")
            return changed
        }
    }

    func setting(_ key: String) throws -> String? {
        try db.read { try String.fetchOne($0, sql: "SELECT value FROM setting WHERE key = ?", arguments: [key]) }
    }

    func setSetting(_ key: String, _ value: String) throws {
        try db.write {
            try $0.execute(sql: "INSERT OR REPLACE INTO setting (key, value) VALUES (?, ?)", arguments: [key, value])
        }
    }

    func mamLastID(_ account: String) throws -> String? {
        try db.read { try String.fetchOne($0, sql: "SELECT mamLastID FROM account WHERE jid = ?", arguments: [account]) }
    }

    func setMamLastID(_ account: String, _ id: String) throws {
        try db.write { try $0.execute(sql: "UPDATE account SET mamLastID = ? WHERE jid = ?", arguments: [id, account]) }
    }

    struct NewFile {
        var url: String?
        var name: String
        var mime: String?
        var size: Int64?
        var path: String?
        var state: String
        var aesgcm: String?
    }

    func attach(_ file: NewFile, to message: Int64) throws {
        try db.write { db in
            try db.execute(sql: """
                INSERT OR REPLACE INTO file (message, url, name, mime, size, path, state, aesgcm) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [message, file.url, file.name, file.mime, file.size, file.path, file.state, file.aesgcm])
        }
    }

    func fileRow(_ message: Int64) throws -> Row? {
        try db.read { try Row.fetchOne($0, sql: "SELECT * FROM file WHERE message = ?", arguments: [message]) }
    }

    func updateFile(_ message: Int64, _ column: String, _ value: DatabaseValueConvertible?) throws {
        // Column names come from this module only.
        try db.write { try $0.execute(sql: "UPDATE file SET \(column) = ? WHERE message = ?", arguments: [value, message]) }
    }

    func setBody(message id: Int64, _ body: String) throws {
        try db.write { try $0.execute(sql: "UPDATE message SET body = ? WHERE id = ?", arguments: [body, id]) }
    }

    func setState(message id: Int64, _ state: String) throws {
        try db.write { try $0.execute(sql: "UPDATE message SET state = ? WHERE id = ?", arguments: [state, id]) }
    }

    /// The `message`/`history` item for one stored message.
    func item(_ id: Int64) throws -> [String: Any]? {
        try db.read { db in try Self.items(db, where: "m.id = ?", [id], limit: 1, roots: fileRoots).first }
    }

    /// The newest `count` items, oldest first; `before` pages further back.
    func history(_ conversation: Int64, before: Int64? = nil, count: Int) throws -> [[String: Any]] {
        try db.read { db in
            let filter = before == nil ? "m.conversation = ?" : "m.conversation = ? AND m.id < ?"
            let arguments: [DatabaseValueConvertible] = before.map { [conversation, $0] } ?? [conversation]
            return try Self.items(db, where: filter, arguments, limit: count, roots: fileRoots).reversed()
        }
    }

    /// The file a stored name refers to, if it is on disk.
    func file(_ name: String?) -> URL? {
        Self.file(name, roots: fileRoots)
    }

    private static func file(_ name: String?, roots: [URL]) -> URL? {
        guard let name, !name.isEmpty else { return nil }
        if name.hasPrefix("/") { return URL(fileURLWithPath: name) }
        return roots.map { $0.appendingPathComponent(name) }.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    private static func items(_ db: Database, where filter: String, _ arguments: [DatabaseValueConvertible],
                              limit: Int, roots: [URL]) throws -> [[String: Any]] {
        try Row.fetchAll(db, sql: """
            SELECT m.*, f.name AS fileName, f.mime, f.size, f.state AS fileState, f.path,
                   q.id AS quoteID, q.sender AS quoteSender, q.body AS quoteBody,
                   c.kind AS conversationKind, c.jid AS conversationJID, c.nick AS conversationNick
            FROM message m JOIN conversation c ON c.id = m.conversation
            LEFT JOIN file f ON f.message = m.id LEFT JOIN message q ON q.id = m.replyTo
            WHERE \(filter) AND NOT m.hidden ORDER BY m.time DESC, m.id DESC LIMIT ?
            """, arguments: StatementArguments(arguments + [limit])).map { row in
            let id: Int64 = row["id"]
            let direction: String = row["direction"]
            let sender: String = row["sender"]
            // In a room the sender is a nick; the app knows occupants as room/nick.
            let room = (row["conversationKind"] as String) == "groupchat"
            let roomNick = row["conversationNick"] as String?
            var item: [String: Any] = [
                "type": "message", "conversation": row["conversation"] as Int64, "item": id,
                "direction": direction,
                "from": room && direction == "in" ? "\(row["conversationJID"] as String)/\(sender)" : sender,
                "from_display": room && direction == "out" ? (roomNick ?? sender) : sender,
                "time": Int((row["time"] as Date).timeIntervalSince1970),
                "encryption": (row["encryption"] as String) == "omemo" ? "OMEMO" : "NONE",
                "synced": false, "reactions": try reactions(db, message: id),
            ]
            if let name: String = row["fileName"] {
                item["content"] = "file"
                item["file_name"] = name
                item["mime"] = row["mime"] as String? ?? ""
                item["size"] = row["size"] as Int64? ?? -1
                item["file_state"] = ["complete": "complete", "inProgress": "in_progress",
                                      "failed": "failed"][row["fileState"] as String] ?? "not_started"
                item["path"] = file(row["path"], roots: roots)?.path ?? ""
            } else {
                item["content"] = "text"
                item["body"] = row["body"] as String? ?? ""
                let body = (row["body"] as String? ?? "").lowercased()
                item["mentioned"] = room && direction == "in" && !(roomNick ?? "").isEmpty
                    && body.contains(roomNick!.lowercased())
                item["editable"] = direction == "out"
                item["marked"] = ["pending": "unsent", "failed": "wontsend"][row["state"] as String]
                    ?? row["state"] as String
                if let quote: Int64 = row["quoteID"] {
                    item["quote"] = ["item": quote, "from": row["quoteSender"] as String? ?? "",
                                     "body": String((row["quoteBody"] as String? ?? "").prefix(100))]
                }
            }
            return item
        }
    }

    private static func reactions(_ db: Database, message: Int64) throws -> [[String: Any]] {
        let account = try String.fetchOne(db, sql: """
            SELECT c.account FROM message m JOIN conversation c ON c.id = m.conversation WHERE m.id = ?
            """, arguments: [message]) ?? ""
        var counts: [String: (count: Int, me: Bool)] = [:]
        var order: [String] = []
        for row in try Row.fetchAll(db, sql: "SELECT sender, emojis FROM reaction WHERE message = ? ORDER BY time",
                                    arguments: [message]) {
            let sender: String = row["sender"]
            for emoji in (row["emojis"] as String).split(separator: " ").map(String.init) {
                if counts[emoji] == nil { order.append(emoji) }
                counts[emoji, default: (0, false)].count += 1
                if sender == account { counts[emoji]?.me = true }
            }
        }
        return order.map { ["emoji": $0, "count": counts[$0]!.count, "me": counts[$0]!.me] }
    }
}

/// One `<item/>` of a roster result or push (RFC 6121 §2.1).
struct RosterItem: Equatable {
    let jid: String
    let name: String?
    let subscription: String
    let ask: String?

    static func items(of query: StanzaNode) -> [RosterItem] {
        query.children("item", ChatNS.roster).compactMap { item in
            guard let jid = item["jid"] else { return nil }
            return RosterItem(jid: jid, name: item["name"], subscription: item["subscription"] ?? "none",
                              ask: item["ask"])
        }
    }
}
