import XCTest
@testable import GeckoKit

final class PushFiltersTests: XCTestCase {
    /// The fields `ios/push-proxy` deserialises (protocol.rs `FilterUpdate`).
    func testFilterMessageCarriesWhatTheProxyReads() throws {
        let message = try XCTUnwrap(SwiftCore.pushFilters(
            to: "push.example.org", token: "ab12", muted: ["quiet@example.org"],
            mentionOnly: [(jid: "room@muc.example.org", nick: "gecko")]))
        XCTAssertEqual(message["to"], "push.example.org")
        XCTAssertNil(message.child("body", XMPPNS.client), "no chat client may show it")
        XCTAssertNotNil(message.child("no-store", "urn:xmpp:hints"))
        let json = try XCTUnwrap(message.child("filters", "urn:gecko:push:filters")?.text)
        let rules = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual(rules["token"] as? String, "ab12")
        XCTAssertEqual(rules["muted"] as? [String], ["quiet@example.org"])
        XCTAssertEqual(rules["mention_only"] as? [[String: String]], [["jid": "room@muc.example.org", "nick": "gecko"]])
    }
}
