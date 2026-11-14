import Foundation
import GRDB

/// One-time move of the Vala core's data (`dino.db`, `omemo.db`) into a
/// `GeckoStore`. The old databases are only read; they stay as a backup.
/// Reads Dino's stored format; no Dino code is involved.
enum DinoImport {
    struct Report: Equatable {
        var accounts = 0
        var contacts = 0
        var conversations = 0
        var messages = 0
        var files = 0
        var corrections = 0
        var reactions = 0
        var omemoSessions = 0
        var omemoDevices = 0
        /// Passwords by bare JID, for the caller to put in the Keychain.
        var passwords: [String: String] = [:]
    }

    enum Failure: Error, Equatable {
        case notEmpty
    }

    /// Imports into an empty store; refuses to merge into one already used.
    static func run(dino: String, omemo: String?, into store: GeckoStore) throws -> Report {
        // Opened writable but only read: a read-only connection cannot use a
        // WAL database whose shared-memory file is missing (a copied backup).
        let source = try DatabaseQueue(path: dino)
        let keys = try omemo.map { try DatabaseQueue(path: $0) }
        var report = Report()
        try store.db.write { db in
            guard try Int.fetchOne(db, sql: "SELECT count(*) FROM account") == 0 else { throw Failure.notEmpty }
            try source.read { old in
                let accounts = try importAccounts(old, db, &report)
                let conversations = try importConversations(old, db, accounts, &report)
                let items = try importItems(old, db, accounts, conversations, &report)
                try importReactions(old, db, accounts, items, &report)
                if let keys {
                    try keys.read { old in try importOMEMO(old, db, accounts, &report) }
                }
            }
        }
        return report
    }

    // MARK: Accounts, contacts, conversations

    /// Dino account id → bare JID.
    private static func importAccounts(_ old: Database, _ db: Database, _ report: inout Report) throws -> [Int64: String] {
        var accounts: [Int64: String] = [:]
        for row in try Row.fetchAll(old, sql: "SELECT * FROM account") {
            let jid: String = row["bare_jid"]
            accounts[row["id"]] = jid
            try db.execute(sql: "INSERT INTO account (jid, resource, enabled, rosterVersion) VALUES (?, ?, ?, ?)",
                           arguments: [jid, row["resourcepart"] ?? "gecko", (row["enabled"] as Int? ?? 1) != 0,
                                       row["roster_version"] as String?])
            if let password: String = row["password"] { report.passwords[jid] = password }
            report.accounts += 1
        }
        for row in try Row.fetchAll(old, sql: "SELECT * FROM roster") {
            guard let account = accounts[row["account_id"]] else { continue }
            try db.execute(sql: """
                INSERT OR IGNORE INTO contact (account, jid, name, subscription, ask) VALUES (?, ?, ?, ?, ?)
                """, arguments: [account, row["jid"], row["name"] as String?,
                                 row["subscription"] as String? ?? "none", row["ask"] as String?])
            report.contacts += db.changesCount
        }
        for row in try Row.fetchAll(old, sql: """
            SELECT a.account_id, j.bare_jid, a.hash FROM contact_avatar a JOIN jid j ON j.id = a.jid_id
            """) {
            guard let account = accounts[row["account_id"]] else { continue }
            try db.execute(sql: "INSERT OR REPLACE INTO avatar (account, jid, hash) VALUES (?, ?, ?)",
                           arguments: [account, row["bare_jid"], row["hash"]])
        }
        return accounts
    }

    /// Dino conversation id → new conversation id.
    private static func importConversations(_ old: Database, _ db: Database, _ accounts: [Int64: String],
                                            _ report: inout Report) throws -> [Int64: Int64] {
        var conversations: [Int64: Int64] = [:]
        for row in try Row.fetchAll(old, sql: """
            SELECT c.*, j.bare_jid FROM conversation c JOIN jid j ON j.id = c.jid_id
            """) {
            guard let account = accounts[row["account_id"]] else { continue }
            // Dino: type 0 chat, 1 group chat, 2 private message in a room
            // (the JID then carries the member's nick as resource).
            let type: Int = row["type"] ?? 0
            let kind = ["chat", "groupchat", "groupchatPrivate"][min(max(type, 0), 2)]
            let resource: String? = row["resource"]
            let jid = type == 2 ? "\(row["bare_jid"] as String)/\(resource ?? "")" : row["bare_jid"] as String
            // Dino: notification 0 default, 1 on, 2 off, 3 highlight. Default
            // means highlight in rooms and on elsewhere.
            let notify = switch row["notification"] as Int? ?? 0 {
            case 1: "on"
            case 2: "off"
            case 3: "highlight"
            default: type == 1 ? "highlight" : "on"
            }
            // Dino can keep two rows for one conversation: they become one.
            try db.execute(sql: """
                INSERT INTO conversation (account, jid, kind, nick, encryption, notify, open, pinned, lastActive)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT (account, jid, kind) DO UPDATE SET open = open OR excluded.open,
                    pinned = pinned OR excluded.pinned,
                    lastActive = max(coalesce(lastActive, excluded.lastActive), coalesce(excluded.lastActive, lastActive))
                """, arguments: [account, jid, kind, type == 1 ? resource : nil,
                                 encryption(row["encryption"]), notify, (row["active"] as Int? ?? 0) != 0,
                                 (row["pinned"] as Int? ?? 0) != 0,
                                 (row["last_active"] as Int64?).map { Date(timeIntervalSince1970: TimeInterval($0)) }])
            conversations[row["id"]] = try Int64.fetchOne(db, sql: """
                SELECT id FROM conversation WHERE account = ? AND jid = ? AND kind = ?
                """, arguments: [account, jid, kind])
        }
        report.conversations = Set(conversations.values).count
        return conversations
    }

    /// Dino: 0 none, 1 OpenPGP, 2 OMEMO. OpenPGP history is kept as plain
    /// text marked none: Gecko never decrypted it.
    private static func encryption(_ value: Int?) -> String { value == 2 ? "omemo" : "none" }

    // MARK: Messages and files

    /// Dino content item id → new message id (for reactions and replies).
    private static func importItems(_ old: Database, _ db: Database, _ accounts: [Int64: String],
                                    _ conversations: [Int64: Int64], _ report: inout Report) throws -> [Int64: Int64] {
        // Messages that only carry a file's URL; the file item stands for them.
        let fileCarriers = Set(try Int64.fetchAll(old, sql: """
            SELECT CAST(info AS INTEGER) FROM file_transfer WHERE info GLOB '[0-9]*'
            """))
        // Dino points a corrected message's timeline item at its newest
        // correction; that row has the text to show, under the original's id.
        let corrected = Dictionary(uniqueKeysWithValues: try Row.fetchAll(old, sql: """
            SELECT message_id, to_stanza_id FROM message_correction WHERE to_stanza_id IS NOT NULL
            """).map { ($0["message_id"] as Int64, $0["to_stanza_id"] as String) })
        let realJIDs = Dictionary(uniqueKeysWithValues: try Row.fetchAll(old, sql: "SELECT * FROM real_jid").map {
            ($0["message_id"] as Int64, $0["real_jid"] as String)
        })
        let replies = Dictionary(uniqueKeysWithValues: try Row.fetchAll(old, sql: "SELECT * FROM reply").map {
            ($0["message_id"] as Int64, $0)
        })

        var items: [Int64: Int64] = [:]
        var pendingReplies: [(message: Int64, quotedItem: Int64)] = []
        for item in try Row.fetchAll(old, sql: "SELECT * FROM content_item ORDER BY time, id") {
            guard let conversation = conversations[item["conversation_id"]] else { continue }
            let foreign: Int64 = item["foreign_id"]
            let hidden = (item["hide"] as Int? ?? 0) != 0
            switch item["content_type"] as Int {
            case 1:
                guard !fileCarriers.contains(foreign),
                      let m = try Row.fetchOne(old, sql: """
                        SELECT m.*, j.bare_jid FROM message m JOIN jid j ON j.id = m.counterpart_id WHERE m.id = ?
                        """, arguments: [foreign]) else { continue }
                let original = corrected[foreign]
                let id = try insertMessage(db, conversation: conversation, row: m, time: item["time"],
                                           originID: original ?? m["stanza_id"], body: m["body"],
                                           edited: original != nil, hidden: hidden, realJID: realJIDs[foreign],
                                           accounts: accounts)
                if original != nil { report.corrections += 1 }
                if let reply = replies[foreign] {
                    try db.execute(sql: "UPDATE message SET replyToID = ?, replyToSender = ? WHERE id = ?",
                                   arguments: [reply["quoted_message_stanza_id"] as String?,
                                               reply["quoted_message_from"] as String?, id])
                    if let quoted: Int64 = reply["quoted_message_id"] { pendingReplies.append((id, quoted)) }
                }
                items[item["id"]] = id
                report.messages += 1
            case 2:
                guard let f = try Row.fetchOne(old, sql: """
                    SELECT f.*, j.bare_jid FROM file_transfer f JOIN jid j ON j.id = f.counterpart_id WHERE f.id = ?
                    """, arguments: [foreign]) else { continue }
                let carrier = (f["info"] as String?).flatMap(Int64.init)
                let url = try carrier.flatMap { try String.fetchOne(old, sql: "SELECT body FROM message WHERE id = ?",
                                                                    arguments: [$0]) }
                let id = try insertMessage(db, conversation: conversation, row: f, time: item["time"],
                                           originID: f["file_sharing_id"], body: url, edited: false,
                                           hidden: hidden, realJID: nil, accounts: accounts)
                // Dino: state 0 complete, 1 in progress, 2 not started, 3 failed.
                // An interrupted transfer did not survive the old core.
                let state = switch f["state"] as Int? ?? 2 {
                case 0: "complete"
                case 3, 1: "failed"
                default: "notStarted"
                }
                let width: Int? = f["width"], height: Int? = f["height"], size: Int64? = f["size"]
                try db.execute(sql: """
                    INSERT INTO file (message, url, name, mime, size, path, state, aesgcm, width, height)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [id, url, f["file_name"] as String? ?? "file", f["mime_type"] as String?,
                                     size.flatMap { $0 >= 0 ? $0 : nil }, f["path"] as String?, state,
                                     url.flatMap(aesgcmKey), width.flatMap { $0 > 0 ? $0 : nil },
                                     height.flatMap { $0 > 0 ? $0 : nil }])
                items[item["id"]] = id
                report.files += 1
            default:
                continue  // calls: not kept
            }
        }
        for (message, quoted) in pendingReplies {
            guard let target = items[quoted] else { continue }
            try db.execute(sql: "UPDATE message SET replyTo = ? WHERE id = ?", arguments: [target, message])
        }
        return items
    }

    /// The key and IV of an `aesgcm://` URL (the fragment), hex.
    private static func aesgcmKey(_ url: String) -> String? {
        guard url.hasPrefix("aesgcm://"), let hash = url.firstIndex(of: "#") else { return nil }
        return String(url[url.index(after: hash)...])
    }

    // swiftlint:disable:next function_parameter_count
    private static func insertMessage(_ db: Database, conversation: Int64, row: Row, time: Int64, originID: String?,
                                      body: String?, edited: Bool, hidden: Bool, realJID: String?,
                                      accounts: [Int64: String]) throws -> Int64 {
        let outgoing = (row["direction"] as Int? ?? 0) == 1
        let room = try String.fetchOne(db, sql: "SELECT kind FROM conversation WHERE id = ?",
                                       arguments: [conversation]) == "groupchat"
        let sender: String = if outgoing {
            accounts[row["account_id"]] ?? ""
        } else if room {
            row["counterpart_resource"] ?? ""
        } else {
            row["bare_jid"]
        }
        // Dino marks: 0 none, 1 received, 2 read, 3 acknowledged, 4 unsent,
        // 5 won't send, 6 sending, 7 sent, 8 error.
        let state: String = if !outgoing {
            "none"
        } else {
            switch row["marked"] as Int? ?? 7 {
            case 1, 3: "received"
            case 2: "read"
            case 4, 6: "pending"
            case 5, 8: "failed"
            default: "sent"
            }
        }
        // The timeline item's time: for a corrected message, the original's.
        let date = Date(timeIntervalSince1970: TimeInterval(time))
        let local = (row["local_time"] as Int64?).map { Date(timeIntervalSince1970: TimeInterval($0)) } ?? date
        try db.execute(sql: """
            INSERT INTO message (conversation, direction, sender, senderRealJID, body, time, localTime, originID,
                                 serverID, encryption, state, edited, hidden)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT DO NOTHING
            """, arguments: [conversation, outgoing ? "out" : "in", sender, realJID, body, date, local, originID,
                             row["server_id"] as String?, encryption(row["encryption"]), state, edited, hidden])
        // A second copy of an archive item (same server id) keeps the first.
        if db.changesCount == 0 {
            return try Int64.fetchOne(db, sql: "SELECT id FROM message WHERE conversation = ? AND serverID = ?",
                                      arguments: [conversation, row["server_id"] as String?]) ?? 0
        }
        return db.lastInsertedRowID
    }

    // MARK: Reactions

    private static func importReactions(_ old: Database, _ db: Database, _ accounts: [Int64: String],
                                        _ items: [Int64: Int64], _ report: inout Report) throws {
        for row in try Row.fetchAll(old, sql: """
            SELECT r.*, j.bare_jid, o.last_nick FROM reaction r
            LEFT JOIN jid j ON j.id = r.jid_id LEFT JOIN occupant_id o ON o.id = r.occupant_id
            """) {
            guard let message = items[row["content_item_id"]], let emojis: String = row["emojis"],
                  !emojis.isEmpty else { continue }
            let sender: String? = row["bare_jid"] ?? row["last_nick"]
            guard let sender else { continue }
            // Dino keeps the set comma separated; the store, space separated.
            let set = emojis.split(separator: ",").joined(separator: " ")
            try db.execute(sql: "INSERT OR REPLACE INTO reaction (message, sender, emojis, time) VALUES (?, ?, ?, ?)",
                           arguments: [message, sender, set,
                                       Date(timeIntervalSince1970: TimeInterval(row["time"] as Int64? ?? 0) / 1000)])
            report.reactions += 1
        }
    }

    // MARK: OMEMO

    private static func importOMEMO(_ old: Database, _ db: Database, _ accounts: [Int64: String],
                                    _ report: inout Report) throws {
        // omemo.db keys everything by its own identity row, one per account.
        var identities: [Int64: String] = [:]
        for row in try Row.fetchAll(old, sql: "SELECT * FROM identity") {
            guard let account = accounts[row["account_id"]],
                  let publicKey = Data(base64Encoded: row["identity_key_public_base64"] as String),
                  let privateKey = Data(base64Encoded: row["identity_key_private_base64"] as String) else { continue }
            identities[row["id"]] = account
            try db.execute(sql: "INSERT INTO omemoIdentity (account, deviceID, publicKey, privateKey) VALUES (?, ?, ?, ?)",
                           arguments: [account, row["device_id"] as Int64, publicKey, privateKey])
        }
        for (table, column, signed) in [("pre_key", "pre_key_id", false), ("signed_pre_key", "signed_pre_key_id", true)] {
            for row in try Row.fetchAll(old, sql: "SELECT * FROM \(table)") {
                guard let account = identities[row["identity_id"]],
                      let record = Data(base64Encoded: row["record_base64"] as String) else { continue }
                try db.execute(sql: "INSERT INTO omemoPreKey (account, id, record, signed) VALUES (?, ?, ?, ?)",
                               arguments: [account, row[column] as Int64, record, signed])
            }
        }
        for row in try Row.fetchAll(old, sql: "SELECT * FROM session") {
            guard let account = identities[row["identity_id"]],
                  let record = Data(base64Encoded: row["record_base64"] as String) else { continue }
            try db.execute(sql: "INSERT INTO omemoSession (account, jid, device, record) VALUES (?, ?, ?, ?)",
                           arguments: [account, row["name"] as String, row["device_id"] as Int64, record])
            report.omemoSessions += 1
        }
        // Dino trust levels: 0 verified, 1 trusted, 2 untrusted, 3 unknown.
        for row in try Row.fetchAll(old, sql: "SELECT * FROM identity_meta") {
            guard let account = identities[row["identity_id"]] else { continue }
            let trust = ["verified", "trusted", "untrusted", "unknown"][min(max(row["trust_level"] as Int? ?? 3, 0), 3)]
            try db.execute(sql: """
                INSERT OR REPLACE INTO omemoDevice (account, jid, device, identityKey, trust, active, lastSeen)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """, arguments: [account, row["address_name"] as String, row["device_id"] as Int64,
                                 (row["identity_key_public_base64"] as String?).flatMap { Data(base64Encoded: $0) },
                                 trust, (row["now_active"] as Int? ?? 1) != 0,
                                 (row["last_active"] as Int64?).map { Date(timeIntervalSince1970: TimeInterval($0)) }])
            report.omemoDevices += 1
        }
        for row in try Row.fetchAll(old, sql: "SELECT * FROM trust") {
            guard let account = identities[row["identity_id"]], let jid: String = row["address_name"] else { continue }
            try db.execute(sql: "INSERT OR REPLACE INTO omemoBlindTrust (account, jid, enabled) VALUES (?, ?, ?)",
                           arguments: [account, jid, (row["blind_trust"] as Int? ?? 1) != 0])
        }
    }
}
