import Foundation

/// A namespaced XML element: just enough XML for the stanzas Swift protocol
/// code exchanges with the XMPP core.
struct StanzaNode: Equatable {
    var name: String
    var ns: String
    var attributes: [String: String]
    var children: [StanzaNode]
    var text: String

    init(_ name: String, _ ns: String, _ attributes: [String: String] = [:],
         _ children: [StanzaNode] = [], text: String = "") {
        self.name = name
        self.ns = ns
        self.attributes = attributes
        self.children = children
        self.text = text
    }

    subscript(_ attribute: String) -> String? { attributes[attribute] }

    func child(_ name: String, _ ns: String) -> StanzaNode? {
        children.first { $0.name == name && $0.ns == ns }
    }

    func children(_ name: String, _ ns: String) -> [StanzaNode] {
        children.filter { $0.name == name && $0.ns == ns }
    }

    /// Declares a namespace wherever an element's differs from its parent's.
    var xml: String { serialized(parentNS: nil) }

    private func serialized(parentNS: String?) -> String {
        var out = "<\(name)"
        if ns != parentNS { out += " xmlns=\"\(Self.escape(ns))\"" }
        for (key, value) in attributes.sorted(by: { $0.key < $1.key }) {
            out += " \(key)=\"\(Self.escape(value))\""
        }
        if children.isEmpty && text.isEmpty { return out + "/>" }
        out += ">" + Self.escape(text)
        for child in children { out += child.serialized(parentNS: ns) }
        return out + "</\(name)>"
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    static func parse(_ xml: String) -> StanzaNode? {
        let builder = Builder()
        let parser = XMLParser(data: Data(xml.utf8))
        parser.shouldProcessNamespaces = true
        parser.delegate = builder
        return parser.parse() ? builder.root : nil
    }

    private final class Builder: NSObject, XMLParserDelegate {
        var root: StanzaNode?
        private var open: [StanzaNode] = []

        func parser(_: XMLParser, didStartElement name: String, namespaceURI: String?,
                    qualifiedName _: String?, attributes: [String: String]) {
            open.append(StanzaNode(name, namespaceURI ?? "", attributes))
        }

        func parser(_: XMLParser, foundCharacters string: String) {
            guard !open.isEmpty else { return }
            open[open.count - 1].text += string
        }

        func parser(_: XMLParser, didEndElement _: String, namespaceURI _: String?,
                    qualifiedName _: String?) {
            let done = open.removeLast()
            if open.isEmpty {
                root = done
            } else {
                open[open.count - 1].children.append(done)
            }
        }
    }
}
