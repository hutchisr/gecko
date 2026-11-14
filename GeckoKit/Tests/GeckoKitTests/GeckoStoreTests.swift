import GRDB
import XCTest
@testable import GeckoKit

final class GeckoStoreTests: XCTestCase {
    func testMigratesAndKeepsReferencesConsistent() throws {
        let store = try GeckoStore(path: nil)
        try store.db.write { db in
            try db.execute(sql: "INSERT INTO account (jid, resource) VALUES ('me@example.org', 'gecko')")
            try db.execute(sql: """
                INSERT INTO conversation (account, jid, kind) VALUES ('me@example.org', 'friend@example.org', 'chat')
                """)
            let conversation = db.lastInsertedRowID
            try db.execute(sql: """
                INSERT INTO message (conversation, direction, sender, body, time, localTime, serverID)
                VALUES (?, 'in', 'friend@example.org', 'hi', ?, ?, 'archive-1')
                """, arguments: [conversation, Date(), Date()])
            let message = db.lastInsertedRowID
            try db.execute(sql: """
                INSERT INTO reaction (message, sender, emojis, time) VALUES (?, 'me@example.org', '👍', ?)
                """, arguments: [message, Date()])

            // The same archive item twice must not become two messages.
            XCTAssertThrowsError(try db.execute(sql: """
                INSERT INTO message (conversation, direction, sender, body, time, localTime, serverID)
                VALUES (?, 'in', 'friend@example.org', 'hi', ?, ?, 'archive-1')
                """, arguments: [conversation, Date(), Date()]))

            // Signing an account out of the store removes everything it owned.
            try db.execute(sql: "DELETE FROM account")
            for table in ["conversation", "message", "reaction"] {
                XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM \(table)"), 0, table)
            }
        }
    }

    func testReopeningAnExistingDatabaseDoesNotMigrateAgain() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("gecko-store-\(UUID()).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        try GeckoStore(path: path).db.write { db in
            try db.execute(sql: "INSERT INTO setting (key, value) VALUES ('k', 'v')")
        }
        let reopened = try GeckoStore(path: path)
        XCTAssertEqual(try reopened.db.read { try String.fetchOne($0, sql: "SELECT value FROM setting") }, "v")
    }

    func testUpgradeDropsOnlyEmptyChatsDuplicatingARoom() throws {
        let db = try DatabaseQueue()
        try GeckoStore.migrator.migrate(db, upTo: "v1")
        try db.write { db in
            try db.execute(sql: """
                INSERT INTO account (jid, resource) VALUES ('me@x.org', 'r');
                INSERT INTO conversation (id, account, jid, kind) VALUES
                    (1, 'me@x.org', 'room@muc.x.org', 'groupchat'),
                    (2, 'me@x.org', 'room@muc.x.org', 'chat'),
                    (3, 'me@x.org', 'friend@x.org', 'chat'),
                    (4, 'me@x.org', 'other@muc.x.org', 'groupchat'),
                    (5, 'me@x.org', 'other@muc.x.org', 'chat');
                INSERT INTO message (conversation, direction, sender, body, time, localTime, state)
                    VALUES (5, 'in', 'other@muc.x.org', 'kept', '2026-01-01 00:00:00', '2026-01-01 00:00:00', 'none');
                """)
        }
        try GeckoStore.migrator.migrate(db)
        let left = try db.read { try Int64.fetchAll($0, sql: "SELECT id FROM conversation ORDER BY id") }
        XCTAssertEqual(left, [1, 3, 4, 5], "the empty room-address chat goes; real chats and ones with messages stay")
    }
}
