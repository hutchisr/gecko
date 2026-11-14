import GRDB
import XCTest
@testable import GeckoKit

final class OMEMOSessionTests: XCTestCase {
    private func session(_ account: String, trust: @escaping OMEMOSession.Trust = { _, _, _ in true }) throws
        -> (OMEMOSession, GeckoStore) {
        let store = try GeckoStore(path: nil)
        try store.addAccount(account, resource: "r")
        return (try OMEMOSession(store: store, account: account, trust: trust), store)
    }

    private func preKeyCount(_ store: GeckoStore) throws -> Int {
        try store.db.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM omemoPreKey WHERE NOT signed") ?? 0 }
    }

    func testTwoDevicesSetUpASessionAndTalkBothWays() throws {
        let (alice, _) = try session("alice@example.org")
        let (bob, bobStore) = try session("bob@example.org")
        let bundle = try bob.bundle()
        XCTAssertEqual(bundle.preKeys.count, OMEMOSession.preKeyCount)
        XCTAssertEqual(bundle.identityKey.count, 33, "a djb-typed Curve25519 key")
        XCTAssertEqual(bundle.signature.count, 64)

        try alice.startSession("bob@example.org", bob.deviceID, bundle: bundle)
        XCTAssertTrue(alice.hasSession("bob@example.org", bob.deviceID))
        let key = Data((0..<32).map { UInt8($0) })
        let first = try alice.encrypt(key, for: "bob@example.org", bob.deviceID)
        XCTAssertTrue(first.preKey, "the first message carries the session setup")

        XCTAssertEqual(try bob.decrypt(first.data, preKey: true, from: "alice@example.org", alice.deviceID), key)
        XCTAssertEqual(try preKeyCount(bobStore), OMEMOSession.preKeyCount - 1, "a used pre-key is deleted")
        XCTAssertTrue(try bob.refillPreKeys())
        XCTAssertEqual(try preKeyCount(bobStore), OMEMOSession.preKeyCount)

        let reply = try bob.encrypt(Data(key.reversed()), for: "alice@example.org", alice.deviceID)
        XCTAssertFalse(reply.preKey)
        XCTAssertEqual(try alice.decrypt(reply.data, preKey: false, from: "bob@example.org", bob.deviceID),
                       Data(key.reversed()))
        XCTAssertFalse(try alice.encrypt(key, for: "bob@example.org", bob.deviceID).preKey,
                       "once answered, the session is confirmed")
    }

    func testAnUntrustedIdentityIsRefused() throws {
        let (alice, _) = try session("alice@example.org")
        let (bob, _) = try session("bob@example.org") { _, _, _ in false }
        try alice.startSession("bob@example.org", bob.deviceID, bundle: bob.bundle())
        let message = try alice.encrypt(Data(count: 32), for: "bob@example.org", bob.deviceID)
        XCTAssertThrowsError(try bob.decrypt(message.data, preKey: true, from: "alice@example.org", alice.deviceID)) {
            XCTAssertEqual(($0 as? OMEMOError)?.code, -1010, "SG_ERR_UNTRUSTED_IDENTITY")
        }
    }

    func testReopeningKeepsTheSameDeviceAndIdentity() throws {
        let store = try GeckoStore(path: nil)
        try store.addAccount("me@example.org", resource: "r")
        let first = try OMEMOSession(store: store, account: "me@example.org") { _, _, _ in true }
        let again = try OMEMOSession(store: store, account: "me@example.org") { _, _, _ in true }
        XCTAssertEqual(first.deviceID, again.deviceID)
        XCTAssertEqual(first.identityKey, again.identityKey)
        XCTAssertEqual(try first.bundle(), try again.bundle())
    }

    /// The keys the Vala core left (GECKO_DINO_DIR, a copy of its data
    /// directory) work unchanged: same device, same identity, same bundle.
    func testImportedValaKeysStayTheSameDevice() throws {
        guard let dir = ProcessInfo.processInfo.environment["GECKO_DINO_DIR"] else {
            throw XCTSkip("set GECKO_DINO_DIR to a copy of a Dino data directory")
        }
        let store = try GeckoStore(path: nil)
        _ = try DinoImport.run(dino: dir + "/dino.db", omemo: dir + "/omemo.db", into: store)
        let account = try XCTUnwrap(store.accounts().first?.jid)
        let imported = try store.db.read { db in
            try XCTUnwrap(Row.fetchOne(db, sql: "SELECT * FROM omemoIdentity WHERE account = ?", arguments: [account]))
        }
        let omemo = try OMEMOSession(store: store, account: account) { _, _, _ in true }
        XCTAssertEqual(Int64(omemo.deviceID), imported["deviceID"] as Int64)
        XCTAssertEqual(omemo.identityKey, imported["publicKey"] as Data)
        let bundle = try omemo.bundle()
        XCTAssertEqual(bundle.signature.count, 64)
        XCTAssertFalse(bundle.preKeys.isEmpty)
        let sessions = try store.db.read { db in
            try Row.fetchAll(db, sql: "SELECT jid, device FROM omemoSession WHERE account = ? LIMIT 5", arguments: [account])
        }
        for row in sessions {
            XCTAssertTrue(omemo.hasSession(row["jid"], UInt32(truncatingIfNeeded: row["device"] as Int64)))
        }
    }
}
