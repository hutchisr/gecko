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
}
