import XCTest
@testable import GeckoKit

final class CallRoutingTests: XCTestCase {
    private func message(_ xml: String) throws -> StanzaNode { try XCTUnwrap(StanzaNode.parse(xml)) }

    func testOnlyOneToOneCallMessagesReachCallSignalling() throws {
        let propose = "<propose xmlns='urn:xmpp:jingle-message:0' id='s1'/>"
        let live = try message("<message xmlns='jabber:client' from='a@x.org/p' type='chat'>\(propose)</message>")
        XCTAssertEqual(SwiftCore.callMessage(live, account: "me@x.org")?["from"], "a@x.org/p")

        let plain = try message("<message xmlns='jabber:client' from='a@x.org/p'><body>hi</body></message>")
        XCTAssertNil(SwiftCore.callMessage(plain, account: "me@x.org"))
        let room = try message("<message xmlns='jabber:client' from='r@muc.x.org/n' type='groupchat'>\(propose)</message>")
        XCTAssertNil(SwiftCore.callMessage(room, account: "me@x.org"))

        let carbon = """
            <message xmlns='jabber:client' from='%@'><received xmlns='urn:xmpp:carbons:2'>
              <forwarded xmlns='urn:xmpp:forward:0'><message xmlns='jabber:client' from='a@x.org/p' type='chat'>\
            \(propose)</message></forwarded></received></message>
            """
        let ours = try message(String(format: carbon, "me@x.org"))
        XCTAssertEqual(SwiftCore.callMessage(ours, account: "me@x.org")?["from"], "a@x.org/p", "our other devices' copy")
        let spoofed = try message(String(format: carbon, "mallory@x.org"))
        XCTAssertNil(SwiftCore.callMessage(spoofed, account: "me@x.org"), "carbons only from our own account")
    }
}
