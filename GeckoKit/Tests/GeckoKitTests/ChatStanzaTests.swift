import XCTest
@testable import GeckoKit

final class ChatStanzaTests: XCTestCase {
    private let me = "me@example.org"

    private func parse(_ xml: String, archive: String? = nil) -> ChatStanza? {
        StanzaNode.parse(xml).flatMap { ChatStanza.parse($0, me: me, archive: archive) }
    }

    func testReadsAPlainMessageWithItsExtensions() throws {
        let m = try XCTUnwrap(parse("""
            <message xmlns='jabber:client' from='friend@example.org/phone' to='me@example.org' type='chat' id='m1'>
              <body>hi</body><origin-id xmlns='urn:xmpp:sid:0' id='o1'/>
              <stanza-id xmlns='urn:xmpp:sid:0' by='me@example.org' id='s1'/>
              <stanza-id xmlns='urn:xmpp:sid:0' by='evil@example.org' id='forged'/>
              <request xmlns='urn:xmpp:receipts'/><markable xmlns='urn:xmpp:chat-markers:0'/>
              <active xmlns='http://jabber.org/protocol/chatstates'/>
              <reply xmlns='urn:xmpp:reply:0' to='me@example.org' id='o0'/>
            </message>
            """))
        XCTAssertEqual(m.body, "hi")
        XCTAssertEqual(m.originID, "o1")
        XCTAssertEqual(m.serverID, "s1", "only our archive's stanza-id counts")
        XCTAssertTrue(m.requestsReceipt)
        XCTAssertTrue(m.markable)
        XCTAssertEqual(m.chatState, "active")
        XCTAssertEqual(m.replyTo, .init(jid: "me@example.org", id: "o0"))
        XCTAssertFalse(m.sentByUs)
    }

    func testCarbonsOnlyFromOurOwnAccount() throws {
        let carbon = { (from: String) in """
            <message xmlns='jabber:client' from='\(from)' to='me@example.org/gecko'>
              <sent xmlns='urn:xmpp:carbons:2'><forwarded xmlns='urn:xmpp:forward:0'>
                <message xmlns='jabber:client' from='me@example.org/laptop' to='friend@example.org' type='chat'
                  id='c1'><body>from my laptop</body></message>
              </forwarded></sent>
            </message>
            """ }
        let sent = try XCTUnwrap(parse(carbon("me@example.org")))
        XCTAssertTrue(sent.sentByUs)
        XCTAssertEqual(sent.to, "friend@example.org")
        XCTAssertNil(parse(carbon("mallory@example.org")), "a forged carbon must be dropped")
    }

    func testArchiveResultsCarryTheirIDAndTime() throws {
        let m = try XCTUnwrap(parse("""
            <message xmlns='jabber:client' to='me@example.org/gecko'>
              <result xmlns='urn:xmpp:mam:2' queryid='q' id='arch-9'><forwarded xmlns='urn:xmpp:forward:0'>
                <delay xmlns='urn:xmpp:delay' stamp='2026-11-01T10:00:00Z'/>
                <message xmlns='jabber:client' from='friend@example.org/phone' to='me@example.org' type='chat'>
                  <body>old</body></message>
              </forwarded></result>
            </message>
            """))
        XCTAssertTrue(m.archived)
        XCTAssertEqual(m.serverID, "arch-9")
        XCTAssertEqual(m.delay, ChatStanza.date("2026-11-01T10:00:00Z"))
        XCTAssertNil(parse("""
            <message xmlns='jabber:client' from='mallory@example.org' to='me@example.org/gecko'>
              <result xmlns='urn:xmpp:mam:2' id='x'><forwarded xmlns='urn:xmpp:forward:0'>
                <message xmlns='jabber:client' from='friend@example.org' type='chat'><body>fake</body></message>
              </forwarded></result></message>
            """), "an archive result from someone else's JID must be dropped")
    }

    func testOutgoingMessageRequestsReceiptAndMarkers() {
        let node = ChatStanza.outgoing(to: "friend@example.org", body: "hello", id: "x1")
        let back = ChatStanza.parse(node, me: "friend@example.org")
        XCTAssertEqual(back?.body, "hello")
        XCTAssertEqual(back?.originID, "x1")
        XCTAssertEqual(back?.requestsReceipt, true)
        XCTAssertEqual(back?.markable, true)
    }

    func testReadsXMPPLinks() throws {
        func link(_ text: String) -> String? {
            URL(string: text).flatMap(JID.link).map { "\($0.jid) \($0.join ? "join" : "chat")" }
        }
        XCTAssertEqual(link("xmpp:Friend@Example.org"), "friend@example.org chat")
        XCTAssertEqual(link("xmpp:friend@example.org/phone?message;body=hi"), "friend@example.org chat")
        XCTAssertEqual(link("xmpp:room@muc.example.org?join"), "room@muc.example.org join")
        XCTAssertEqual(link("xmpp:room@muc.example.org?join;password=secret"), "room@muc.example.org join")
        XCTAssertEqual(link("xmpp:two%20words%23@example.org"), nil, "a space is in no address")
        XCTAssertEqual(link("xmpp:caf%C3%A9@example.org"), "café@example.org chat")
        XCTAssertEqual(link("xmpp://me@example.org/room@muc.example.org?join"), "room@muc.example.org join",
                       "an authority names the account to use, not who to talk to")
        XCTAssertNil(link("xmpp://me@example.org"))
        XCTAssertNil(link("xmpp:example.org"), "a server is no one to chat with")
        XCTAssertNil(link("https://friend@example.org"))
    }
}

final class StoreQueriesTests: XCTestCase {
    func testHistoryPagesOldestFirstAndListCountsUnread() throws {
        let store = try GeckoStore(path: nil)
        try store.addAccount("me@example.org", resource: "r")
        let chat = try store.conversation(account: "me@example.org", jid: "friend@example.org")
        var ids: [Int64] = []
        for i in 0..<5 {
            ids.append(try XCTUnwrap(store.insert(.init(
                conversation: chat, direction: i == 4 ? "out" : "in",
                sender: i == 4 ? "me@example.org" : "friend@example.org",
                body: "m\(i)", time: Date(timeIntervalSince1970: TimeInterval(i)), originID: "o\(i)"))))
        }
        XCTAssertNil(try store.insert(.init(conversation: chat, direction: "out", sender: "me@example.org",
                                            body: "m4 again", time: Date(), originID: "o4")),
                     "our own message echoed back must not appear twice")

        let latest = try store.history(chat, count: 2)
        XCTAssertEqual(latest.map { $0["body"] as? String }, ["m3", "m4"])
        let older = try store.history(chat, before: try XCTUnwrap(latest.first?["item"] as? Int64), count: 2)
        XCTAssertEqual(older.map { $0["body"] as? String }, ["m1", "m2"])

        var list = try store.conversationList()
        XCTAssertEqual(list.first?["unread"] as? Int, 4)
        XCTAssertEqual(list.first?["preview"] as? String, "m4")
        XCTAssertEqual(list.first?["preview_direction"] as? String, "out")
        try store.update(conversation: chat, "readUpTo", ids[3])
        list = try store.conversationList()
        XCTAssertEqual(list.first?["unread"] as? Int, 0)
    }

    func testReadMarkersCorrectionsAndReactions() throws {
        let store = try GeckoStore(path: nil)
        try store.addAccount("me@example.org", resource: "r")
        let chat = try store.conversation(account: "me@example.org", jid: "friend@example.org")
        func add(_ direction: String, _ origin: String, state: String = "sent") throws -> Int64 {
            try XCTUnwrap(store.insert(.init(conversation: chat, direction: direction,
                                             sender: direction == "out" ? "me@example.org" : "friend@example.org",
                                             body: origin, time: Date(), originID: origin, state: state)))
        }
        let first = try add("out", "a"), second = try add("out", "b"), later = try add("out", "c")
        XCTAssertEqual(try store.markRead(conversation: chat, upTo: second), [first, second],
                       "a displayed marker covers everything before it")
        XCTAssertEqual(try store.messageRow(later)?["state"] as String?, "sent")

        // Only the author's correction is found.
        let theirs = try add("in", "t")
        XCTAssertNil(try store.message(chat, originID: "t", sender: "me@example.org"))
        XCTAssertEqual(try store.message(chat, originID: "t", sender: "friend@example.org")?["id"] as Int64?, theirs)

        try store.setReactions(message: theirs, sender: "me@example.org", emojis: ["👍", "🎉"])
        XCTAssertEqual(try store.reactions(message: theirs, sender: "me@example.org"), ["👍", "🎉"])
        let item = try XCTUnwrap(store.item(theirs))
        let reactions = try XCTUnwrap(item["reactions"] as? [[String: Any]])
        XCTAssertEqual(reactions.map { $0["emoji"] as? String }, ["👍", "🎉"])
        XCTAssertEqual(reactions.first?["me"] as? Bool, true)
        try store.setReactions(message: theirs, sender: "me@example.org", emojis: [])
        XCTAssertEqual(try store.reactions(message: theirs, sender: "me@example.org"), [])
    }
}
