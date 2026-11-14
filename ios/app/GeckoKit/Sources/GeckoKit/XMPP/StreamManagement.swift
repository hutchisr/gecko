import Foundation

/// Stanza counting and acknowledgement for one stream-managed session
/// (XEP-0198). Counters wrap at 2^32 as the XEP specifies.
struct StreamManagement {
    /// Stanzas received from the server; what `<a h=>` and `<resume h=>` report.
    private(set) var handled: UInt32 = 0
    /// Our stanzas the server has not acknowledged yet, oldest first.
    private(set) var unacked: [StanzaNode] = []
    private var acked: UInt32 = 0

    static func isStanza(_ node: StanzaNode) -> Bool {
        node.ns == XMPPNS.client && (node.name == "message" || node.name == "presence" || node.name == "iq")
    }

    static let request = StanzaNode("r", XMPPNS.sm)

    /// Something we wrote to the stream.
    mutating func sent(_ node: StanzaNode) {
        if Self.isStanza(node) { unacked.append(node) }
    }

    /// Something the server wrote; returns the answer to send, if one is due.
    mutating func received(_ node: StanzaNode) -> StanzaNode? {
        if Self.isStanza(node) {
            handled &+= 1
        } else if node.ns == XMPPNS.sm, node.name == "r" {
            return StanzaNode("a", XMPPNS.sm, ["h": String(handled)])
        } else if node.ns == XMPPNS.sm, node.name == "a", let h = node["h"].flatMap(UInt32.init) {
            acknowledge(h)
        }
        return nil
    }

    /// The server has received `h` of our stanzas in total.
    mutating func acknowledge(_ h: UInt32) {
        let newly = Int(h &- acked)
        // A count beyond what is outstanding is the server's error; trust it
        // only as far as there is something to drop.
        unacked.removeFirst(min(newly, unacked.count))
        acked = h
    }

    /// The session resumed with the server having received `h` of our
    /// stanzas; returns those to send again (sending them counts them anew).
    mutating func resumed(at h: UInt32) -> [StanzaNode] {
        acknowledge(h)
        defer { unacked = [] }
        return unacked
    }
}
