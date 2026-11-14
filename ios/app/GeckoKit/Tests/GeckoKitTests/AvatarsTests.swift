import XCTest
@testable import GeckoKit

final class AvatarsTests: XCTestCase {
    private let image = Data("not really a png".utf8)

    private func items(_ node: String, _ item: StanzaNode) -> StanzaNode {
        StanzaNode("iq", XMPPNS.client, ["type": "result"], [
            StanzaNode("pubsub", AvatarNS.pubsub, [:], [
                StanzaNode("items", AvatarNS.pubsub, ["node": node], [item]),
            ]),
        ])
    }

    func testDataIsOnlyAcceptedWhenItMatchesItsHash() {
        let id = Avatars.sha1(image)
        let reply = items(AvatarNS.data, StanzaNode("item", AvatarNS.pubsub, ["id": id],
                                                    [StanzaNode("data", AvatarNS.data, text: image.base64EncodedString())]))
        XCTAssertEqual(Avatars.data(reply, id: id), image)
        XCTAssertNil(Avatars.data(reply, id: String(repeating: "0", count: 40)), "a mismatched image must be refused")
    }

    func testMetadataNamesTheCurrentAvatarOrItsRemoval() {
        let current = items(AvatarNS.metadata, StanzaNode("item", AvatarNS.pubsub, ["id": "ABC"], [
            StanzaNode("metadata", AvatarNS.metadata, [:], [StanzaNode("info", AvatarNS.metadata, ["id": "ABC"])]),
        ]))
        XCTAssertEqual(Avatars.metadataID(current), "abc")
        let removed = items(AvatarNS.metadata, StanzaNode("item", AvatarNS.pubsub, ["id": "x"],
                                                           [StanzaNode("metadata", AvatarNS.metadata)]))
        XCTAssertEqual(Avatars.metadataID(removed), "")
        XCTAssertNil(Avatars.metadataID(StanzaNode("iq", XMPPNS.client, ["type": "result"])))
    }

    func testPublishesDataBeforeMetadataUnderTheImageHash() {
        let publishes = Avatars.publish(png: image, width: 10, height: 20)
        let nodes = publishes.compactMap {
            $0.child("pubsub", AvatarNS.pubsub)?.child("publish", AvatarNS.pubsub)?["node"]
        }
        XCTAssertEqual(nodes, [AvatarNS.data, AvatarNS.metadata])
        let info = publishes[1].child("pubsub", AvatarNS.pubsub)?.child("publish", AvatarNS.pubsub)?
            .child("item", AvatarNS.pubsub)?.child("metadata", AvatarNS.metadata)?.child("info", AvatarNS.metadata)
        XCTAssertEqual(info?["id"], Avatars.sha1(image))
        XCTAssertEqual(info?["bytes"], String(image.count))
    }

    func testScalesAPictureDownToTheAvatarSize() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("gecko-avatar-\(UUID()).png")
        defer { try? FileManager.default.removeItem(at: file) }
        let context = try XCTUnwrap(CGContext(data: nil, width: 800, height: 400, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let big = try XCTUnwrap(context.makeImage())
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(file as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, big, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let scaled = try XCTUnwrap(Avatars.scaledPNG(file))
        XCTAssertEqual(scaled.width, 192)
        XCTAssertEqual(scaled.height, 96)
        XCTAssertEqual(scaled.png.prefix(4), Data([0x89, 0x50, 0x4E, 0x47]))
    }

    func testFingerprintDropsTheKeyTypeAndGroupsInEights() {
        let key = Data([0x05] + (0..<32).map { UInt8($0) })
        XCTAssertEqual(omemoFingerprint(key).split(separator: " ").count, 8)
        XCTAssertTrue(omemoFingerprint(key).hasPrefix("00010203 04050607"))
    }
}
