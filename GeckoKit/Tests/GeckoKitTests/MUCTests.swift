import XCTest
@testable import GeckoKit

final class MUCTests: XCTestCase {
    private func parse(_ xml: String) -> StanzaNode { StanzaNode.parse(xml)! }

    func testReadsOccupantPresenceAndOurOwn() throws {
        let other = try XCTUnwrap(MUC.presence(parse("""
            <presence xmlns='jabber:client' from='room@muc.example.org/alice'>
              <x xmlns='http://jabber.org/protocol/muc#user'>
                <item affiliation='owner' role='moderator' jid='alice@example.org/phone'/></x></presence>
            """)))
        XCTAssertEqual(other.room, "room@muc.example.org")
        XCTAssertEqual(other.nick, "alice")
        XCTAssertEqual(other.realJID, "alice@example.org")
        XCTAssertEqual(other.affiliation, "owner")
        XCTAssertFalse(other.isSelf)

        let me = try XCTUnwrap(MUC.presence(parse("""
            <presence xmlns='jabber:client' from='room@muc.example.org/me'>
              <x xmlns='http://jabber.org/protocol/muc#user'><item affiliation='none' role='participant'/>
                <status code='110'/><status code='201'/></x></presence>
            """)))
        XCTAssertTrue(me.isSelf)
        XCTAssertTrue(me.codes.contains(201), "a room we just created")
        XCTAssertNil(MUC.presence(parse("<presence xmlns='jabber:client' from='friend@example.org/phone'/>")),
                     "an ordinary contact's presence is not a room's")
    }

    func testRemovalReasonsAndRefusedJoins() throws {
        let kicked = try XCTUnwrap(MUC.presence(parse("""
            <presence xmlns='jabber:client' from='room@muc.example.org/me' type='unavailable'>
              <x xmlns='http://jabber.org/protocol/muc#user'><item affiliation='none' role='none'/>
                <status code='110'/><status code='307'/></x></presence>
            """)))
        XCTAssertEqual(MUC.removal(kicked), "kicked")
        let left = try XCTUnwrap(MUC.presence(parse("""
            <presence xmlns='jabber:client' from='room@muc.example.org/me' type='unavailable'>
              <x xmlns='http://jabber.org/protocol/muc#user'><item role='none'/><status code='110'/></x></presence>
            """)))
        XCTAssertNil(MUC.removal(left), "an ordinary leave is not a removal")
        let refused = try XCTUnwrap(MUC.presence(parse("""
            <presence xmlns='jabber:client' from='room@muc.example.org/me' type='error'>
              <error type='auth'><registration-required xmlns='urn:ietf:params:xml:ns:xmpp-stanzas'/></error></presence>
            """)))
        XCTAssertEqual(refused.error, "registration-required")
    }

    func testReadsMediatedAndDirectInvitations() {
        XCTAssertEqual(MUC.invitation(parse("""
            <message xmlns='jabber:client' from='room@muc.example.org'>
              <x xmlns='http://jabber.org/protocol/muc#user'>
                <invite from='alice@example.org/phone'><reason>come along</reason></invite>
                <password>secret</password></x></message>
            """)), MUC.Invitation(room: "room@muc.example.org", inviter: "alice@example.org", reason: "come along",
                                  password: "secret"))
        XCTAssertEqual(MUC.invitation(parse("""
            <message xmlns='jabber:client' from='alice@example.org/phone'>
              <x xmlns='jabber:x:conference' jid='room@muc.example.org' reason='hi'/></message>
            """))?.room, "room@muc.example.org")
        XCTAssertNil(MUC.invitation(parse("<message xmlns='jabber:client' from='a@example.org'><body>x</body></message>")))
    }

    func testBookmarksRoundTrip() throws {
        let bookmark = MUC.Bookmark(room: "room@muc.example.org", name: "Room", nick: "me", autojoin: true, password: nil)
        let publish = MUC.publishBookmark(bookmark, id: "b")
        let item = try XCTUnwrap(publish.child("pubsub", AvatarNS.pubsub)?.child("publish", AvatarNS.pubsub)?
            .child("item", AvatarNS.pubsub))
        let result = StanzaNode("iq", XMPPNS.client, ["type": "result"], [StanzaNode("pubsub", AvatarNS.pubsub, [:], [
            StanzaNode("items", AvatarNS.pubsub, ["node": MUCNS.bookmarks], [item]),
        ])])
        XCTAssertEqual(MUC.bookmarks(try XCTUnwrap(StanzaNode.parse(result.xml))), [bookmark])
        XCTAssertEqual(publish.child("pubsub", AvatarNS.pubsub)?.child("publish-options", AvatarNS.pubsub)?.xml
            .contains("whitelist"), true, "bookmarks stay private")
    }
}
