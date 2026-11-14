import XCTest
@testable import GeckoKit

final class XMLStreamParserTests: XCTestCase {
    private let header = "<stream:stream xmlns='jabber:client' xmlns:stream='http://etherx.jabber.org/streams' version='1.0'>"

    /// Feeds `input` in chunks of `chunk` bytes (all at once when nil).
    private func parse(_ input: String, chunk: Int? = nil, max: Int = 10 * 1024 * 1024) throws -> [XMLStreamEvent] {
        try parse(Data(input.utf8), chunk: chunk, max: max)
    }

    private func parse(_ bytes: Data, chunk: Int? = nil, max: Int = 10 * 1024 * 1024) throws -> [XMLStreamEvent] {
        var parser = XMLStreamParser(maxElementBytes: max)
        let size = chunk ?? Swift.max(bytes.count, 1)
        var events: [XMLStreamEvent] = []
        var start = bytes.startIndex
        while start < bytes.endIndex {
            let end = min(start + size, bytes.endIndex)
            events += try parser.feed(bytes[start..<end])
            start = end
        }
        return events
    }

    /// The single first-level element of `body` inside a stream.
    private func element(_ body: String, chunk: Int? = nil) throws -> StanzaNode? {
        guard case let .element(node)? = try parse(header + body, chunk: chunk).last else { return nil }
        return node
    }

    private func assertThrows(_ input: String, _ expected: XMLStreamError, max: Int = 10 * 1024 * 1024,
                              line: UInt = #line) {
        XCTAssertThrowsError(try parse(input, max: max), line: line) {
            XCTAssertEqual($0 as? XMLStreamError, expected, line: line)
        }
    }

    private func assertRestricted(_ input: String, line: UInt = #line) {
        XCTAssertThrowsError(try parse(input), line: line) {
            guard case .restrictedXML? = $0 as? XMLStreamError else {
                return XCTFail("expected restrictedXML, got \($0)", line: line)
            }
        }
    }

    private func assertMalformed(_ input: String, line: UInt = #line) {
        XCTAssertThrowsError(try parse(input), line: line) {
            guard case .malformed? = $0 as? XMLStreamError else {
                return XCTFail("expected malformed, got \($0)", line: line)
            }
        }
    }

    private let serverStream = """
    <?xml version='1.0'?><stream:stream xmlns='jabber:client' \
    xmlns:stream='http://etherx.jabber.org/streams' from='im.example.com' \
    id='++TR84Sm6A3hnt3Q065SnAbbk3Y=' version='1.0' xml:lang='en'>
    <stream:features><starttls xmlns='urn:ietf:params:xml:ns:xmpp-tls'><required/></starttls>\
    <mechanisms xmlns="urn:ietf:params:xml:ns:xmpp-sasl"><mechanism>SCRAM-SHA-1</mechanism>\
    <mechanism>PLAIN</mechanism></mechanisms></stream:features>
    <message from='juliet@im.example.com/balcony' to='romeo@example.net' type='chat' xml:lang='en'>\
    <body>Wherefore art thou, Romeo? 💕</body><body xml:lang='de'>Romeo, wo bist du?</body></message>
    </stream:stream>
    """

    private var serverEvents: [XMLStreamEvent] {
        let tls = "urn:ietf:params:xml:ns:xmpp-tls", sasl = "urn:ietf:params:xml:ns:xmpp-sasl"
        return [
            .opened(attributes: ["from": "im.example.com", "id": "++TR84Sm6A3hnt3Q065SnAbbk3Y=",
                                 "version": "1.0", "xml:lang": "en"], ns: "jabber:client"),
            .element(StanzaNode("features", XMLStreamParser.streamsNS, [:], [
                StanzaNode("starttls", tls, [:], [StanzaNode("required", tls)]),
                StanzaNode("mechanisms", sasl, [:], [
                    StanzaNode("mechanism", sasl, text: "SCRAM-SHA-1"),
                    StanzaNode("mechanism", sasl, text: "PLAIN"),
                ]),
            ])),
            .element(StanzaNode("message", "jabber:client", [
                "from": "juliet@im.example.com/balcony", "to": "romeo@example.net",
                "type": "chat", "xml:lang": "en",
            ], [
                StanzaNode("body", "jabber:client", text: "Wherefore art thou, Romeo? 💕"),
                StanzaNode("body", "jabber:client", ["xml:lang": "de"], text: "Romeo, wo bist du?"),
            ])),
            .closed,
        ]
    }

    func testServerStreamWhole() throws {
        XCTAssertEqual(try parse(serverStream), serverEvents)
    }

    func testServerStreamByteByByteAndOddChunks() throws {
        XCTAssertEqual(try parse(serverStream, chunk: 1), serverEvents)
        XCTAssertEqual(try parse(serverStream, chunk: 7), serverEvents)
    }

    func testEventsArriveAsSoonAsComplete() throws {
        var parser = XMLStreamParser()
        XCTAssertEqual(try parser.feed(Data((header + "<presence/><mess").utf8)).count, 2)
        XCTAssertEqual(try parser.feed(Data("age/>".utf8)), [.element(StanzaNode("message", "jabber:client"))])
        XCTAssertEqual(try parser.feed(Data("</stream:stream>".utf8)), [.closed])
    }

    func testEmojiSplitAcrossFeeds() throws {
        var bytes = Data((header + "<message><body>a").utf8)
        let emoji = Data("😀".utf8)
        var parser = XMLStreamParser()
        _ = try parser.feed(bytes)
        _ = try parser.feed(emoji.prefix(1))
        _ = try parser.feed(emoji.dropFirst().prefix(2))
        _ = try parser.feed(emoji.suffix(1))
        bytes = Data("b</body></message>".utf8)
        let events = try parser.feed(bytes)
        XCTAssertEqual(events.first.flatMap { if case let .element(m) = $0 { m } else { nil } }?
            .child("body", "jabber:client")?.text, "a😀b")
    }

    func testEntitiesInAttributesSplitByteByByte() throws {
        let node = try element("<body a='&lt;&amp;&#x1F600;&quot;' b=\"it&apos;s &#62;\"/>", chunk: 1)
        XCTAssertEqual(node?["a"], "<&😀\"")
        XCTAssertEqual(node?["b"], "it's >")
    }

    func testCharacterReferences() throws {
        XCTAssertEqual(try element("<b>&lt;&gt;&amp;&quot;&apos;&#65;&#x42;&#x1f600;&#10;</b>")?.text, "<>&\"'AB😀\n")
        assertMalformed(header + "<b>&#X43;</b>") // the hex marker is a lowercase x
        assertMalformed(header + "<b>&#0;</b>")
        assertMalformed(header + "<b>&#xD800;</b>")
        assertMalformed(header + "<b>&#+5;</b>")
        assertMalformed(header + "<b>a & b</b>")
        assertMalformed(header + "<b a='<'/>")
    }

    func testCDATAIsText() throws {
        XCTAssertEqual(try element("<b>a<![CDATA[<i>&amp;]]]>c</b>", chunk: 1)?.text, "a<i>&amp;]c")
    }

    func testNamespaceScoping() throws {
        let node = try element("""
        <x:a xmlns:x='urn:1' xmlns:y='urn:y' y:attr='v'><x:b xmlns:x='urn:2'><x:c/></x:b><x:d/>\
        <e xmlns='urn:e'><f/><g xmlns=''/></e><h/></x:a>
        """)
        XCTAssertEqual(node, StanzaNode("a", "urn:1", ["y:attr": "v"], [
            StanzaNode("b", "urn:2", [:], [StanzaNode("c", "urn:2")]),
            StanzaNode("d", "urn:1"),
            StanzaNode("e", "urn:e", [:], [StanzaNode("f", "urn:e"), StanzaNode("g", "")]),
            StanzaNode("h", "jabber:client"),
        ]))
        // x went out of scope with <x:a>.
        assertMalformed(header + "<x:a xmlns:x='urn:1'/><x:z/>")
        assertMalformed(header + "<a q:attr='v'/>")
    }

    func testWhitespaceKeepaliveProducesNoEvent() throws {
        var parser = XMLStreamParser()
        XCTAssertEqual(try parser.feed(Data(header.utf8)).count, 1)
        XCTAssertEqual(try parser.feed(Data(" ".utf8)), [])
        XCTAssertEqual(try parser.feed(Data("\r\n\t ".utf8)), [])
        XCTAssertEqual(try parser.feed(Data(" <r/>\n".utf8)), [.element(StanzaNode("r", "jabber:client"))])
    }

    func testTextKeepsWhitespace() throws {
        XCTAssertEqual(try element("<b> x\n <i/> y </b>")?.text, " x\n  y ")
    }

    func testRestrictedXML() {
        assertRestricted("<!DOCTYPE stream:stream>" + header)
        assertRestricted(header + "<!DOCTYPE x>")
        assertRestricted(header + "<!ENTITY x 'y'>")
        assertRestricted(header + "<!-- hi -->")
        assertRestricted(header + "<m><!-- hi --></m>")
        assertRestricted(header + "<?pi data?>")
        assertRestricted("<?xml-stylesheet href='a'?>" + header)
        assertRestricted("<?xml version='1.0'?><?xml version='1.0'?>" + header)
        assertRestricted(header + "<b>&nbsp;</b>")
        assertRestricted(header + "<b a='&foo;'/>")
    }

    func testMalformed() {
        assertMalformed(header + "<a><b></a></b>")
        assertMalformed(header + "</stream:streamx>")
        assertMalformed(header + "<a b=c/>")
        assertMalformed(header + "<a b='1'c='2'/>")
        assertMalformed(header + "<a b='1' b='2'/>")
        assertMalformed(header + "<a b/>")
        assertMalformed(header + "<1a/>")
        assertMalformed(header + "stray text")
        assertMalformed("<message/>")
        assertMalformed(header + "</stream:stream><a/>")
        assertMalformed(header + "<a>\u{1}</a>")
        var bytes = Data((header + "<b>").utf8)
        bytes.append(contentsOf: [0xF0, 0x9F, 0x98]) // truncated emoji
        bytes.append(contentsOf: Data("</b>".utf8))
        XCTAssertThrowsError(try parse(bytes)) { XCTAssertEqual($0 as? XMLStreamError, .malformed("invalid UTF-8")) }
        XCTAssertThrowsError(try parse(Data(header.utf8) + Data([0x3C, 0xFF, 0x2F, 0x3E]))) {
            XCTAssertEqual($0 as? XMLStreamError, .malformed("invalid UTF-8"))
        }
    }

    func testTooLarge() throws {
        let stanza = "<message><body>" + String(repeating: "x", count: 100) + "</body></message>"
        let max = stanza.utf8.count
        // Exactly at the limit, separated by keepalives that don't count, is fine.
        XCTAssertEqual(try parse(header + stanza + String(repeating: " ", count: 500) + stanza, max: max).count, 3)
        assertThrows(header + "<message><body>" + String(repeating: "x", count: 101) + "</body></message>",
                     .tooLarge, max: max)
        // An endless tag or text is cut off before it is complete.
        var parser = XMLStreamParser(maxElementBytes: 1000)
        _ = try parser.feed(Data(header.utf8))
        XCTAssertThrowsError(try {
            for _ in 0..<100 { _ = try parser.feed(Data("<a b='\(String(repeating: "y", count: 50))".utf8)) }
        }()) { XCTAssertEqual($0 as? XMLStreamError, .tooLarge) }
    }

    func testRoundTripThroughStanzaNodeXML() throws {
        guard case let .element(message) = serverEvents[2], case let .element(features) = serverEvents[1] else {
            return XCTFail("the fixture stream lost its features or message")
        }
        let tricky = try XCTUnwrap(element("<m a='&lt;\"&apos;&amp;'>&lt;&amp;&gt; ok<x:c xmlns:x='urn:c'/></m>"))
        for node in [message, features, tricky] {
            XCTAssertEqual(try element(node.xml), node)
        }
    }
}
