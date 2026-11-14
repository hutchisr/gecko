import XCTest
@testable import GeckoKit

final class FileSharingTests: XCTestCase {
    func testEncryptedFilesRoundTripThroughTheirLink() throws {
        let data = Data((0..<5000).map { UInt8($0 % 251) })
        let (sealed, secret) = try FileSharing.encrypt(data)
        XCTAssertEqual(sealed.count, data.count + 16, "ciphertext and tag")
        let link = FileSharing.aesgcmLink(try XCTUnwrap(URL(string: "https://up.example.org/abc/photo%20one.jpg")), secret)
        XCTAssertTrue(link.hasPrefix("aesgcm://up.example.org/abc/photo%20one.jpg#"))
        let parsed = try XCTUnwrap(FileSharing.parseAesgcm(link))
        XCTAssertEqual(parsed.url.absoluteString, "https://up.example.org/abc/photo%20one.jpg")
        XCTAssertEqual(try FileSharing.decrypt(sealed, parsed.secret), data)
        XCTAssertEqual(FileSharing.name(of: link), "photo one.jpg")
        var tampered = sealed
        tampered[tampered.startIndex] ^= 1
        XCTAssertThrowsError(try FileSharing.decrypt(tampered, parsed.secret), "a changed file must not open")
    }

    func testReadsTheLinkLayoutOfExistingClients() throws {
        // 12-byte IV then 32-byte key, as in the Vala core's stored links.
        let fragment = String(repeating: "11", count: 12) + String(repeating: "22", count: 32)
        let parsed = try XCTUnwrap(FileSharing.parseAesgcm("aesgcm://h.example.org/f.mov#\(fragment)"))
        XCTAssertEqual(parsed.secret.iv, Data(repeating: 0x11, count: 12))
        XCTAssertEqual(parsed.secret.key, Data(repeating: 0x22, count: 32))
        XCTAssertNil(FileSharing.parseAesgcm("aesgcm://h.example.org/f.mov#abcd"))
    }

    func testRecognisesMessagesThatOnlyShareAFile() {
        let url = "https://up.example.org/a/cat.png"
        XCTAssertEqual(FileSharing.sharedLink(body: url, oob: url), url)
        XCTAssertNil(FileSharing.sharedLink(body: url, oob: nil), "a plain link someone typed stays a message")
        XCTAssertNil(FileSharing.sharedLink(body: "look \(url)", oob: url))
        let encrypted = "aesgcm://up.example.org/a/cat.png#" + String(repeating: "ab", count: 44)
        XCTAssertEqual(FileSharing.sharedLink(body: encrypted, oob: nil), encrypted)
    }

    func testReadsUploadServiceAndSlot() throws {
        let info = try XCTUnwrap(StanzaNode.parse("""
            <iq xmlns='jabber:client' type='result'><query xmlns='http://jabber.org/protocol/disco#info'>
              <feature var='urn:xmpp:http:upload:0'/>
              <x xmlns='jabber:x:data' type='result'>
                <field var='FORM_TYPE' type='hidden'><value>urn:xmpp:http:upload:0</value></field>
                <field var='max-file-size'><value>104857600</value></field></x></query></iq>
            """))
        XCTAssertEqual(FileSharing.maxSize(info), .some(104_857_600))
        let slot = try XCTUnwrap(FileSharing.slot(try XCTUnwrap(StanzaNode.parse("""
            <iq xmlns='jabber:client' type='result'><slot xmlns='urn:xmpp:http:upload:0'>
              <put url='https://up.example.org/put/1'><header name='Authorization'>Basic x</header>
                <header name='X-Evil'>no</header></put>
              <get url='https://up.example.org/get/1'/></slot></iq>
            """))))
        XCTAssertEqual(slot.headers, ["Authorization": "Basic x"], "only the headers XEP-0363 allows")
        XCTAssertNil(FileSharing.slot(try XCTUnwrap(StanzaNode.parse("""
            <iq xmlns='jabber:client' type='result'><slot xmlns='urn:xmpp:http:upload:0'>
              <put url='http://up.example.org/put/1'/><get url='http://up.example.org/get/1'/></slot></iq>
            """))), "uploads only over HTTPS")
    }
}
