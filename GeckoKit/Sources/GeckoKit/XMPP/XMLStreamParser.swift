import Foundation

/// What a chunk of an XMPP XML stream completed (RFC 6120 §4).
enum XMLStreamEvent: Equatable {
    /// The `<stream:stream>` open tag: its attributes (qualified names as
    /// written, e.g. "xml:lang", "from", "id", "version") and its default
    /// namespace ("jabber:client").
    case opened(attributes: [String: String], ns: String)
    /// A complete first-level child of the stream root (a stanza, features,
    /// sasl/starttls elements...).
    case element(StanzaNode)
    case closed
}

/// `.restrictedXML` maps to the `<restricted-xml/>` stream error,
/// `.malformed` to `<not-well-formed/>`, `.tooLarge` to `<policy-violation/>`.
enum XMLStreamError: Error, Equatable {
    case malformed(String)
    case restrictedXML(String)
    case tooLarge
}

/// Incremental byte-level parser for one XMPP stream: the XML subset of
/// RFC 6120 §11 (no comments, PIs other than a leading XML declaration, DTDs
/// or custom entities). Bytes may be split anywhere; each byte is looked at a
/// bounded number of times. A stream restart needs a new parser.
///
/// ponytail: no end-of-line or attribute-value whitespace normalization
/// (XML 1.0 §2.11, §3.3.3); text and values are kept byte-for-byte.
struct XMLStreamParser {
    static let streamsNS = "http://etherx.jabber.org/streams"
    private static let xmlNS = "http://www.w3.org/XML/1998/namespace"

    private enum Mode { case text, tag, pi, bang, cdata }

    private let maxElementBytes: Int
    private var mode = Mode.text
    /// The open quote inside a tag, 0 outside attribute values.
    private var quote: UInt8 = 0
    /// Bytes after `<` of the tag, PI or CDATA section being read.
    private var token: [UInt8] = []
    /// Raw character data of the innermost open element since its last markup.
    private var text: [UInt8] = []
    /// Bytes of the current first-level element (or stream header) so far.
    private var size = 0
    /// Namespace declarations per open element; "" is the default namespace.
    private var scopes: [[String: String]] = [["xml": Self.xmlNS]]
    /// Open elements below the stream root, with their qualified names.
    private var stack: [(name: String, node: StanzaNode)] = []
    /// Qualified name of the stream root while it is open.
    private var streamName: String?
    /// Any markup seen, after which an XML declaration is no longer allowed.
    private var started = false
    private var closed = false
    private var events: [XMLStreamEvent] = []

    init(maxElementBytes: Int = 10 * 1024 * 1024) {
        self.maxElementBytes = maxElementBytes
    }

    /// Feeds bytes exactly as read from the socket; returns every event they
    /// complete, in order.
    mutating func feed(_ bytes: Data) throws -> [XMLStreamEvent] {
        defer { events.removeAll(keepingCapacity: true) }
        for b in bytes {
            if b < 0x20 && !Self.isSpace(b) { throw XMLStreamError.malformed("control character \(b)") }
            let betweenElements = stack.isEmpty && mode == .text
            if betweenElements { size = 0 }
            if !betweenElements || b == UInt8(ascii: "<") {
                size += 1
                if size > maxElementBytes { throw XMLStreamError.tooLarge }
            }
            switch mode {
            case .text:
                if b == UInt8(ascii: "<") {
                    try flushText()
                    if closed { throw XMLStreamError.malformed("markup after the stream closed") }
                    mode = .tag
                } else if !stack.isEmpty {
                    text.append(b)
                } else if !Self.isSpace(b) {
                    throw XMLStreamError.malformed("text outside a stanza")
                }
            case .tag:
                if quote != 0 {
                    if b == quote { quote = 0 }
                } else if b == UInt8(ascii: "\"") || b == UInt8(ascii: "'") {
                    quote = b
                } else if b == UInt8(ascii: ">") {
                    try endOfTag()
                    continue
                } else if token.isEmpty && b == UInt8(ascii: "?") {
                    mode = .pi
                } else if token.isEmpty && b == UInt8(ascii: "!") {
                    mode = .bang
                }
                token.append(b)
            case .pi:
                token.append(b)
                if b == UInt8(ascii: ">") && token[token.count - 2] == UInt8(ascii: "?") {
                    try endOfPI()
                }
            case .bang:
                token.append(b)
                guard b == Self.cdataOpen[token.count - 1] else {
                    throw XMLStreamError.restrictedXML("comment, DTD or markup declaration")
                }
                if token.count == Self.cdataOpen.count {
                    mode = .cdata
                    token.removeAll(keepingCapacity: true)
                }
            case .cdata:
                token.append(b)
                if token.count >= 3 && token.suffix(3).elementsEqual("]]>".utf8) {
                    guard !stack.isEmpty else { throw XMLStreamError.malformed("CDATA outside a stanza") }
                    stack[stack.count - 1].node.text += try Self.utf8(token.dropLast(3))
                    mode = .text
                    token.removeAll(keepingCapacity: true)
                }
            }
        }
        return events
    }

    private static let cdataOpen = Array("![CDATA[".utf8)

    private mutating func flushText() throws {
        guard !text.isEmpty else { return }
        stack[stack.count - 1].node.text += try Self.decode(text[...])
        text.removeAll(keepingCapacity: true)
    }

    private mutating func endOfPI() throws {
        // `token` is "?target ...?>"; only `<?xml ...?>` before anything else.
        let target = token.dropFirst().prefix(4)
        guard !started, target.prefix(3).elementsEqual("xml".utf8),
              target.count == 4, Self.isSpace(target.last!) || target.last == UInt8(ascii: "?")
        else { throw XMLStreamError.restrictedXML("processing instruction") }
        started = true
        mode = .text
        token.removeAll(keepingCapacity: true)
    }

    private mutating func endOfTag() throws {
        let tag = token
        token.removeAll(keepingCapacity: true)
        mode = .text
        started = true
        if tag.first == UInt8(ascii: "/") {
            try endTag(tag.dropFirst())
        } else {
            try startTag(tag)
        }
    }

    private mutating func startTag(_ tag: [UInt8]) throws {
        let selfClosing = tag.last == UInt8(ascii: "/")
        let body = selfClosing ? tag.dropLast() : tag[...]
        var i = body.startIndex
        let qname = try Self.name(body, &i)
        var attributes: [String: String] = [:]
        var declarations: [String: String] = [:]
        while true {
            let spaced = Self.skipSpace(body, &i)
            if i == body.endIndex { break }
            guard spaced else { throw XMLStreamError.malformed("no space before attribute in <\(qname)>") }
            let key = try Self.name(body, &i)
            Self.skipSpace(body, &i)
            guard i < body.endIndex, body[i] == UInt8(ascii: "=") else {
                throw XMLStreamError.malformed("attribute \(key) without value")
            }
            i += 1
            Self.skipSpace(body, &i)
            guard i < body.endIndex, body[i] == UInt8(ascii: "\"") || body[i] == UInt8(ascii: "'"),
                  let close = body[(i + 1)...].firstIndex(of: body[i])
            else { throw XMLStreamError.malformed("unquoted attribute \(key)") }
            let value = try Self.decode(body[(i + 1)..<close])
            i = close + 1
            let duplicate: String?
            if key == "xmlns" {
                duplicate = declarations.updateValue(value, forKey: "")
            } else if key.hasPrefix("xmlns:") {
                guard !value.isEmpty else { throw XMLStreamError.malformed("empty namespace for \(key)") }
                duplicate = declarations.updateValue(value, forKey: String(key.dropFirst(6)))
            } else {
                duplicate = attributes.updateValue(value, forKey: key)
            }
            guard duplicate == nil else { throw XMLStreamError.malformed("duplicate attribute \(key)") }
        }

        scopes.append(declarations)
        let (prefix, local) = Self.split(qname)
        let ns: String
        if let prefix {
            guard let uri = namespace(prefix) else { throw XMLStreamError.malformed("unbound prefix in <\(qname)>") }
            ns = uri
        } else {
            ns = namespace("") ?? ""
        }
        for key in attributes.keys {
            if let p = Self.split(key).prefix, namespace(p) == nil {
                throw XMLStreamError.malformed("unbound prefix in attribute \(key)")
            }
        }

        if streamName == nil {
            guard local == "stream", ns == Self.streamsNS, !selfClosing else {
                throw XMLStreamError.malformed("expected <stream:stream>, got <\(qname)>")
            }
            streamName = qname
            events.append(.opened(attributes: attributes, ns: namespace("") ?? ""))
        } else if selfClosing {
            scopes.removeLast()
            deliver(StanzaNode(local, ns, attributes))
        } else {
            stack.append((qname, StanzaNode(local, ns, attributes)))
        }
    }

    private mutating func endTag(_ tag: ArraySlice<UInt8>) throws {
        var end = tag.endIndex
        while end > tag.startIndex && Self.isSpace(tag[end - 1]) { end -= 1 }
        let qname = try Self.utf8(tag[..<end])
        if let top = stack.last {
            guard top.name == qname else {
                throw XMLStreamError.malformed("</\(qname)> closes <\(top.name)>")
            }
            stack.removeLast()
            scopes.removeLast()
            deliver(top.node)
        } else if qname == streamName {
            scopes.removeLast()
            streamName = nil
            closed = true
            events.append(.closed)
        } else {
            throw XMLStreamError.malformed("unexpected </\(qname)>")
        }
    }

    /// Hands a finished element to its parent, or out as an event at first level.
    private mutating func deliver(_ node: StanzaNode) {
        if stack.isEmpty {
            events.append(.element(node))
        } else {
            stack[stack.count - 1].node.children.append(node)
        }
    }

    private func namespace(_ prefix: String) -> String? {
        for scope in scopes.reversed() {
            if let uri = scope[prefix] { return uri }
        }
        return nil
    }

    // MARK: - Lexical helpers

    private static func isSpace(_ b: UInt8) -> Bool {
        b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D
    }

    /// Bytes allowed in an XML name; non-ASCII is accepted as-is once valid UTF-8.
    private static func isNameByte(_ b: UInt8) -> Bool {
        b >= 0x80 || (0x30...0x3A).contains(b) || (0x41...0x5A).contains(b & 0xDF)
            || b == UInt8(ascii: "-") || b == UInt8(ascii: ".") || b == UInt8(ascii: "_")
    }

    @discardableResult
    private static func skipSpace(_ s: ArraySlice<UInt8>, _ i: inout Int) -> Bool {
        let start = i
        while i < s.endIndex && isSpace(s[i]) { i += 1 }
        return i > start
    }

    /// Reads a qualified name: at most one colon, neither first nor last.
    private static func name(_ s: ArraySlice<UInt8>, _ i: inout Int) throws -> String {
        let start = i
        while i < s.endIndex && isNameByte(s[i]) { i += 1 }
        let bytes = s[start..<i]
        let colons = bytes.filter { $0 == UInt8(ascii: ":") }.count
        guard let first = bytes.first, !(0x30...0x39).contains(first),
              first != UInt8(ascii: "-"), first != UInt8(ascii: "."),
              colons == 0 || (colons == 1 && first != UInt8(ascii: ":") && bytes.last != UInt8(ascii: ":"))
        else { throw XMLStreamError.malformed("bad name") }
        return try utf8(bytes)
    }

    private static func split(_ qname: String) -> (prefix: String?, local: String) {
        guard let colon = qname.firstIndex(of: ":") else { return (nil, qname) }
        return (String(qname[..<colon]), String(qname[qname.index(after: colon)...]))
    }

    private static func utf8(_ bytes: some Collection<UInt8>) throws -> String {
        let invalid = transcode(bytes.makeIterator(), from: UTF8.self, to: UTF32.self,
                                stoppingOnError: true) { _ in }
        if invalid { throw XMLStreamError.malformed("invalid UTF-8") }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Decodes character data or an attribute value: the five predefined
    /// entities and character references; any other entity is restricted.
    private static func decode(_ raw: ArraySlice<UInt8>) throws -> String {
        guard raw.contains(UInt8(ascii: "&")) || raw.contains(UInt8(ascii: "<")) else { return try utf8(raw) }
        var out: [UInt8] = []
        out.reserveCapacity(raw.count)
        var i = raw.startIndex
        while i < raw.endIndex {
            let b = raw[i]
            if b == UInt8(ascii: "<") { throw XMLStreamError.malformed("'<' in attribute value") }
            guard b == UInt8(ascii: "&") else {
                out.append(b)
                i += 1
                continue
            }
            guard let semi = raw[i...].firstIndex(of: UInt8(ascii: ";")) else {
                throw XMLStreamError.malformed("unterminated entity")
            }
            let ref = raw[(i + 1)..<semi]
            i = semi + 1
            switch String(decoding: ref, as: UTF8.self) {
            case "lt": out.append(UInt8(ascii: "<"))
            case "gt": out.append(UInt8(ascii: ">"))
            case "amp": out.append(UInt8(ascii: "&"))
            case "quot": out.append(UInt8(ascii: "\""))
            case "apos": out.append(UInt8(ascii: "'"))
            case let r where r.hasPrefix("#"):
                let hex = r.hasPrefix("#x")
                let digits = r.dropFirst(hex ? 2 : 1)
                guard digits.utf8.allSatisfy({ (0x30...0x39).contains($0) || hex && (0x61...0x66).contains($0 | 0x20) }),
                      let value = UInt32(digits, radix: hex ? 16 : 10), isXMLChar(value),
                      let scalar = Unicode.Scalar(value)
                else { throw XMLStreamError.malformed("bad character reference &\(r);") }
                UTF8.encode(scalar) { out.append($0) }
            case let r where !ref.isEmpty && ref.allSatisfy(isNameByte):
                throw XMLStreamError.restrictedXML("entity &\(r);")
            default:
                throw XMLStreamError.malformed("bare '&'")
            }
        }
        return try utf8(out)
    }

    private static func isXMLChar(_ v: UInt32) -> Bool {
        v == 0x9 || v == 0xA || v == 0xD || (0x20...0xD7FF).contains(v)
            || (0xE000...0xFFFD).contains(v) || (0x10000...0x10FFFF).contains(v)
    }
}
