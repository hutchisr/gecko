import GRDB
import XCTest
@testable import GeckoKit

final class DinoImportTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("dino-import-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// The tables of Dino's on-disk format the importer reads.
    private func makeDino() throws -> String {
        let path = directory.appendingPathComponent("dino.db").path
        try DatabaseQueue(path: path).write { db in
            try db.execute(sql: """
                CREATE TABLE account (id INTEGER PRIMARY KEY, bare_jid TEXT, resourcepart TEXT, password TEXT,
                    alias TEXT, enabled INTEGER, roster_version TEXT, mam_earliest_synced INTEGER);
                CREATE TABLE jid (id INTEGER PRIMARY KEY, bare_jid TEXT);
                CREATE TABLE roster (account_id INTEGER, jid TEXT, name TEXT, subscription TEXT, ask TEXT);
                CREATE TABLE contact_avatar (jid_id INTEGER, account_id INTEGER, hash TEXT, type INTEGER);
                CREATE TABLE conversation (id INTEGER PRIMARY KEY, account_id INTEGER, jid_id INTEGER, resource TEXT,
                    active INTEGER, last_active INTEGER, type INTEGER, encryption INTEGER, notification INTEGER,
                    pinned INTEGER);
                CREATE TABLE message (id INTEGER PRIMARY KEY, stanza_id TEXT, server_id TEXT, account_id INTEGER,
                    counterpart_id INTEGER, our_resource TEXT, counterpart_resource TEXT, direction INTEGER,
                    type INTEGER, time INTEGER, local_time INTEGER, body TEXT, encryption INTEGER, marked INTEGER);
                CREATE TABLE content_item (id INTEGER PRIMARY KEY, conversation_id INTEGER, time INTEGER,
                    local_time INTEGER, content_type INTEGER, foreign_id INTEGER, hide INTEGER DEFAULT 0);
                CREATE TABLE file_transfer (id INTEGER PRIMARY KEY, file_sharing_id TEXT, account_id INTEGER,
                    counterpart_id INTEGER, counterpart_resource TEXT, our_resource TEXT, direction INTEGER,
                    time INTEGER, local_time INTEGER, encryption INTEGER, file_name TEXT, path TEXT, mime_type TEXT,
                    size INTEGER, state INTEGER, provider INTEGER, info TEXT, width INTEGER, height INTEGER);
                CREATE TABLE message_correction (id INTEGER PRIMARY KEY, message_id INTEGER, to_stanza_id TEXT);
                CREATE TABLE real_jid (message_id INTEGER PRIMARY KEY, real_jid TEXT);
                CREATE TABLE reply (id INTEGER PRIMARY KEY, message_id INTEGER, quoted_message_id INTEGER,
                    quoted_message_stanza_id TEXT, quoted_message_from TEXT);
                CREATE TABLE occupant_id (id INTEGER PRIMARY KEY, account_id INTEGER, last_nick TEXT, jid_id INTEGER,
                    occupant_id TEXT);
                CREATE TABLE reaction (id INTEGER PRIMARY KEY, account_id INTEGER, occupant_id INTEGER,
                    content_item_id INTEGER, time INTEGER, jid_id INTEGER, emojis TEXT);

                INSERT INTO account VALUES (1, 'me@example.org', 'gecko.1', 'hunter2', NULL, 1, 'v7', 0);
                INSERT INTO jid VALUES (1, 'friend@example.org'), (2, 'room@muc.example.org');
                INSERT INTO roster VALUES (1, 'friend@example.org', 'Friend', 'both', NULL);
                -- Dino sometimes keeps two rows for one room (3 here): they merge.
                INSERT INTO conversation VALUES (1, 1, 1, NULL, 1, 100, 0, 2, 0, 0),
                                                (2, 1, 2, 'me', 1, 100, 1, 0, 0, 0),
                                                (3, 1, 2, 'me', 0, 200, 1, 0, 0, 1);
                -- 1:1: a message, its correction, an image (with the message carrying its URL), a reply.
                INSERT INTO message VALUES
                    (1, 'orig', 'arch-1', 1, 1, NULL, 'phone', 0, 1, 10, 10, 'helo', 2, 0),
                    (2, 'fix', 'arch-2', 1, 1, NULL, 'phone', 0, 1, 11, 11, 'hello', 2, 0),
                    (3, 'url', 'arch-3', 1, 1, 'gecko.1', NULL, 1, 1, 12, 12,
                        'aesgcm://up.example.org/a.png#00112233', 2, 2),
                    (4, 'rep', 'arch-4', 1, 1, 'gecko.1', NULL, 1, 1, 13, 13, 'yes', 2, 5),
                    (5, 'r1', 'arch-5', 1, 2, NULL, 'alice', 0, 2, 14, 14, 'hi room', 0, 0),
                    (6, 'r2', 'arch-6', 1, 2, NULL, 'bob', 0, 2, 15, 15, 'second row', 0, 0);
                INSERT INTO message_correction VALUES (1, 2, 'orig');
                INSERT INTO file_transfer VALUES (1, 'share', 1, 1, NULL, 'gecko.1', 1, 12, 12, 2, 'a.png',
                    'a.png', 'image/png', 2048, 0, 0, '3', 640, 480);
                INSERT INTO content_item VALUES (1, 1, 10, 10, 1, 2, 0),
                    (3, 1, 12, 12, 1, 3, 0), (4, 1, 12, 12, 2, 1, 0), (5, 1, 13, 13, 1, 4, 0),
                    (6, 2, 14, 14, 1, 5, 0), (7, 3, 15, 15, 1, 6, 0);
                INSERT INTO reply VALUES (1, 4, 1, 'orig', 'friend@example.org');
                INSERT INTO real_jid VALUES (5, 'alice@example.org');
                INSERT INTO occupant_id VALUES (1, 1, 'alice', 2, 'occ-a');
                INSERT INTO reaction VALUES (1, 1, NULL, 1, 15000, 1, '👍,🎉'), (2, 1, 1, 6, 16000, NULL, '❤️');
                """)
        }
        return path
    }

    private func makeOMEMO() throws -> String {
        let path = directory.appendingPathComponent("omemo.db").path
        try DatabaseQueue(path: path).write { db in
            try db.execute(sql: """
                CREATE TABLE identity (id INTEGER PRIMARY KEY, account_id INTEGER, device_id INTEGER,
                    identity_key_private_base64 TEXT, identity_key_public_base64 TEXT);
                CREATE TABLE pre_key (identity_id INTEGER, pre_key_id INTEGER, record_base64 TEXT);
                CREATE TABLE signed_pre_key (identity_id INTEGER, signed_pre_key_id INTEGER, record_base64 TEXT);
                CREATE TABLE session (identity_id INTEGER, name TEXT, device_id INTEGER, record_base64 TEXT);
                CREATE TABLE identity_meta (identity_id INTEGER, address_name TEXT, device_id INTEGER,
                    identity_key_public_base64 TEXT, trust_level INTEGER, now_active INTEGER, last_active INTEGER);
                CREATE TABLE trust (identity_id INTEGER, address_name TEXT, blind_trust INTEGER);
                INSERT INTO identity VALUES (7, 1, 1137, 'cHJpdg==', 'cHVi');
                INSERT INTO pre_key VALUES (7, 1, 'AQI='), (7, 2, 'AwQ=');
                INSERT INTO signed_pre_key VALUES (7, 1, 'BQY=');
                INSERT INTO session VALUES (7, 'friend@example.org', 42, 'c2Vzcw==');
                INSERT INTO identity_meta VALUES (7, 'friend@example.org', 42, 'a2V5', 0, 1, 100),
                                                 (7, 'friend@example.org', 43, 'a2V6', 3, 0, 50);
                INSERT INTO trust VALUES (7, 'friend@example.org', 0);
                """)
        }
        return path
    }

    func testCarriesHistoryKeysAndTrustAcross() throws {
        let store = try GeckoStore(path: nil)
        let dino = try makeDino()
        let report = try DinoImport.run(dino: dino, omemo: makeOMEMO(), into: store)
        XCTAssertEqual(report.passwords, ["me@example.org": "hunter2"])
        XCTAssertEqual(report.messages, 4, "the correction and the URL carrier are not messages of their own")
        XCTAssertEqual(report.files, 1)
        XCTAssertEqual(report.corrections, 1)

        try store.db.read { db in
            let chat = try Int64.fetchOne(db, sql: "SELECT id FROM conversation WHERE jid = 'friend@example.org'")
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT encryption FROM conversation WHERE id = ?",
                                               arguments: [chat]), "omemo")
            let original = try XCTUnwrap(Row.fetchOne(db, sql: "SELECT * FROM message WHERE originID = 'orig'"))
            XCTAssertEqual(original["body"] as String, "hello", "the corrected text shows")
            XCTAssertEqual(original["edited"] as Bool, true)
            XCTAssertEqual(original["time"] as Date, Date(timeIntervalSince1970: 10), "keeps the original's time")

            let file = try XCTUnwrap(Row.fetchOne(db, sql: "SELECT * FROM file"))
            XCTAssertEqual(file["url"] as String, "aesgcm://up.example.org/a.png#00112233")
            XCTAssertEqual(file["aesgcm"] as String, "00112233")
            XCTAssertEqual(file["state"] as String, "complete")

            let reply = try XCTUnwrap(Row.fetchOne(db, sql: "SELECT * FROM message WHERE originID = 'rep'"))
            XCTAssertEqual(reply["replyTo"] as Int64?, original["id"] as Int64?)
            XCTAssertEqual(reply["state"] as String, "failed", "Dino's won't-send mark")

            let room = try XCTUnwrap(Row.fetchOne(db, sql: "SELECT * FROM message WHERE originID = 'r1'"))
            XCTAssertEqual(room["sender"] as String, "alice")
            XCTAssertEqual(room["senderRealJID"] as String, "alice@example.org")
            let rooms = try Row.fetchAll(db, sql: "SELECT * FROM conversation WHERE kind = 'groupchat'")
            XCTAssertEqual(rooms.count, 1, "duplicate room rows merge")
            XCTAssertEqual(rooms.first?["open"] as Bool?, true)
            XCTAssertEqual(rooms.first?["pinned"] as Bool?, true)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM message WHERE conversation = ?",
                                            arguments: [rooms.first?["id"] as Int64?]), 2)

            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT emojis FROM reaction WHERE sender = 'friend@example.org'"),
                           "👍 🎉")
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT sender FROM reaction WHERE emojis = '❤️'"), "alice")

            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT deviceID FROM omemoIdentity"), 1137)
            XCTAssertEqual(try Data.fetchOne(db, sql: "SELECT record FROM omemoSession"), Data("sess".utf8))
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM omemoPreKey"), 3)
            XCTAssertEqual(try String.fetchAll(db, sql: "SELECT trust FROM omemoDevice ORDER BY device"),
                           ["verified", "unknown"])
            XCTAssertEqual(try Bool.fetchOne(db, sql: "SELECT enabled FROM omemoBlindTrust"), false)
        }
        XCTAssertThrowsError(try DinoImport.run(dino: dino, omemo: nil, into: store)) {
            XCTAssertEqual($0 as? DinoImport.Failure, .notEmpty)
        }
    }

    /// A copy of a real Dino database: GECKO_DINO_DIR=<dir with dino.db and omemo.db>.
    func testImportsARealDatabaseCopy() throws {
        guard let dir = ProcessInfo.processInfo.environment["GECKO_DINO_DIR"] else {
            throw XCTSkip("set GECKO_DINO_DIR to a copy of a Dino data directory")
        }
        let store = try GeckoStore(path: nil)
        let report = try DinoImport.run(dino: dir + "/dino.db", omemo: dir + "/omemo.db", into: store)
        let old = try DatabaseQueue(path: dir + "/dino.db")
        try old.read { db in
            XCTAssertEqual(report.conversations, try Int.fetchOne(db, sql: "SELECT count(*) FROM conversation"))
            XCTAssertEqual(report.files, try Int.fetchOne(db, sql: "SELECT count(*) FROM content_item WHERE content_type = 2"))
            XCTAssertEqual(report.contacts, try Int.fetchOne(db, sql: "SELECT count(*) FROM roster"))
            // Every timeline message except those that only carry a file's URL.
            XCTAssertEqual(report.messages, try Int.fetchOne(db, sql: """
                SELECT count(*) FROM content_item WHERE content_type = 1 AND foreign_id NOT IN
                    (SELECT CAST(info AS INTEGER) FROM file_transfer WHERE info GLOB '[0-9]*')
                    AND conversation_id IN (SELECT id FROM conversation)
                """))
            XCTAssertEqual(report.corrections, try Int.fetchOne(db, sql: """
                SELECT count(*) FROM content_item WHERE content_type = 1
                    AND foreign_id IN (SELECT message_id FROM message_correction)
                """))
        }
        print("gecko-import:", report.accounts, "accounts,", report.messages, "messages,", report.files, "files,",
              report.corrections, "corrections,", report.reactions, "reactions,", report.omemoSessions, "sessions,",
              report.omemoDevices, "devices")
    }
}
