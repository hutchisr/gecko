import Foundation
import GRDB

/// The Swift core's database: accounts, contacts, conversations, messages
/// and their files and reactions, and the OMEMO key material libomemo-c
/// needs. Passwords are not stored here; they live in the Keychain.
struct GeckoStore {
    let db: DatabaseQueue
    /// Where stored file names are looked up, ours first (written), then the
    /// Vala core's. Names are relative: the app's container moves on updates.
    var fileRoots: [URL] = []

    /// Opens (creating and migrating) the database at `path`; nil `path`
    /// opens a private in-memory one.
    init(path: String?) throws {
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        // The notification extension writes the same file from its own process.
        configuration.busyMode = .timeout(5)
        db = try path.map { try DatabaseQueue(path: $0, configuration: configuration) }
            ?? DatabaseQueue(configuration: configuration)
        try Self.migrator.migrate(db)
    }

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "account") { t in
                t.primaryKey("jid", .text)
                t.column("resource", .text).notNull()
                t.column("enabled", .boolean).notNull().defaults(to: true)
                t.column("rosterVersion", .text)
                /// Stream-management resumption (XEP-0198) of the last session.
                t.column("smID", .text)
                t.column("smLocation", .text)
                /// The newest archive (XEP-0313) item already fetched.
                t.column("mamLastID", .text)
            }
            try db.create(table: "contact") { t in
                t.column("account", .text).notNull().references("account", onDelete: .cascade)
                t.column("jid", .text).notNull()
                t.column("name", .text)
                t.column("subscription", .text).notNull().defaults(to: "none")
                t.column("ask", .text)
                t.primaryKey(["account", "jid"])
            }
            try db.create(table: "conversation") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("account", .text).notNull().references("account", onDelete: .cascade)
                t.column("jid", .text).notNull()
                /// chat, groupchat, or groupchatPrivate (a room member's JID with resource).
                t.column("kind", .text).notNull()
                t.column("nick", .text)
                t.column("encryption", .text).notNull().defaults(to: "none")
                /// on, highlight or off.
                t.column("notify", .text).notNull().defaults(to: "on")
                t.column("open", .boolean).notNull().defaults(to: true)
                t.column("pinned", .boolean).notNull().defaults(to: false)
                t.column("lastActive", .datetime)
                t.column("readUpTo", .integer)
                t.uniqueKey(["account", "jid", "kind"])
            }
            try db.create(table: "message") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("conversation", .integer).notNull().indexed()
                    .references("conversation", onDelete: .cascade)
                /// in or out.
                t.column("direction", .text).notNull()
                /// Bare JID, or the room nick in a group chat.
                t.column("sender", .text).notNull()
                t.column("senderRealJID", .text)
                t.column("body", .text)
                t.column("time", .datetime).notNull()
                t.column("localTime", .datetime).notNull()
                /// Our stanza id / origin id (XEP-0359), and the one the archive assigned.
                t.column("originID", .text)
                t.column("serverID", .text)
                /// none or omemo.
                t.column("encryption", .text).notNull().defaults(to: "none")
                /// pending, sent, received, read, failed (outgoing); none for incoming.
                t.column("state", .text).notNull().defaults(to: "none")
                /// Corrected text replaces `body`; this keeps the stanza id the
                /// corrections point at (XEP-0308).
                t.column("edited", .boolean).notNull().defaults(to: false)
                t.column("replyTo", .integer).references("message", onDelete: .setNull)
                t.column("replyToID", .text)
                t.column("replyToSender", .text)
                t.column("hidden", .boolean).notNull().defaults(to: false)
            }
            try db.create(index: "message_time", on: "message", columns: ["conversation", "time"])
            try db.create(index: "message_server", on: "message", columns: ["conversation", "serverID"],
                          unique: true, condition: Column("serverID") != nil)
            try db.create(index: "message_origin", on: "message", columns: ["conversation", "originID"])
            try db.create(table: "file") { t in
                t.column("message", .integer).primaryKey().references("message", onDelete: .cascade)
                t.column("url", .text)
                t.column("name", .text).notNull()
                t.column("mime", .text)
                t.column("size", .integer)
                /// Local copy, relative to the files directory.
                t.column("path", .text)
                /// notStarted, inProgress, complete, failed.
                t.column("state", .text).notNull()
                /// aesgcm:// key and IV (OMEMO media sharing), hex.
                t.column("aesgcm", .text)
                t.column("width", .integer)
                t.column("height", .integer)
            }
            try db.create(table: "reaction") { t in
                t.column("message", .integer).notNull().references("message", onDelete: .cascade)
                /// Bare JID, or the room nick.
                t.column("sender", .text).notNull()
                /// The sender's current set, space separated (XEP-0444 replaces it whole).
                t.column("emojis", .text).notNull()
                t.column("time", .datetime).notNull()
                t.primaryKey(["message", "sender"])
            }
            try db.create(table: "avatar") { t in
                t.column("account", .text).notNull().references("account", onDelete: .cascade)
                t.column("jid", .text).notNull()
                t.column("hash", .text).notNull()
                t.primaryKey(["account", "jid"])
            }
            try db.create(table: "setting") { t in
                t.primaryKey("key", .text)
                t.column("value", .text).notNull()
            }
            // OMEMO: libomemo-c's own serialized records, kept as it wrote them.
            try db.create(table: "omemoIdentity") { t in
                t.column("account", .text).primaryKey().references("account", onDelete: .cascade)
                t.column("deviceID", .integer).notNull()
                t.column("publicKey", .blob).notNull()
                t.column("privateKey", .blob).notNull()
            }
            try db.create(table: "omemoPreKey") { t in
                t.column("account", .text).notNull().references("account", onDelete: .cascade)
                t.column("id", .integer).notNull()
                t.column("record", .blob).notNull()
                t.column("signed", .boolean).notNull()
                t.primaryKey(["account", "id", "signed"])
            }
            try db.create(table: "omemoSession") { t in
                t.column("account", .text).notNull().references("account", onDelete: .cascade)
                t.column("jid", .text).notNull()
                t.column("device", .integer).notNull()
                t.column("record", .blob).notNull()
                t.primaryKey(["account", "jid", "device"])
            }
            try db.create(table: "omemoDevice") { t in
                t.column("account", .text).notNull().references("account", onDelete: .cascade)
                t.column("jid", .text).notNull()
                t.column("device", .integer).notNull()
                t.column("identityKey", .blob)
                /// unknown, trusted, verified, untrusted.
                t.column("trust", .text).notNull().defaults(to: "unknown")
                /// Still in the contact's published device list.
                t.column("active", .boolean).notNull().defaults(to: true)
                t.column("lastSeen", .datetime)
                t.primaryKey(["account", "jid", "device"])
            }
            try db.create(table: "omemoBlindTrust") { t in
                t.column("account", .text).notNull().references("account", onDelete: .cascade)
                t.column("jid", .text).notNull()
                /// Trust new devices until one is verified (BTBV).
                t.column("enabled", .boolean).notNull().defaults(to: true)
                t.primaryKey(["account", "jid"])
            }
        }
        return migrator
    }
}
