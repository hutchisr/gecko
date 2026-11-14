import Foundation
import dnssd

/// One DNS SRV answer (RFC 2782).
struct SRVRecord: Equatable {
    let priority: UInt16
    let weight: UInt16
    let port: UInt16
    let target: String
}

/// A host/port to try when connecting to an XMPP server.
struct XMPPEndpoint: Equatable {
    let host: String
    let port: UInt16
    /// TLS from the first byte (XEP-0368) rather than STARTTLS.
    let directTLS: Bool
}

/// Where to connect for an XMPP domain: RFC 6120 §3.2 SRV lookup with
/// XEP-0368 direct TLS, ordered per RFC 2782.
enum XMPPEndpoints {
    /// Parses the RDATA of one SRV answer (priority, weight, port, uncompressed target name in DNS label format).
    /// The root name comes back as "."; other names without a trailing dot.
    static func record(rdata: Data) -> SRVRecord? {
        let bytes = [UInt8](rdata)
        guard bytes.count >= 7 else { return nil }
        func u16(_ i: Int) -> UInt16 { UInt16(bytes[i]) << 8 | UInt16(bytes[i + 1]) }
        var labels: [String] = []
        var i = 6
        while true {
            guard i < bytes.count else { return nil }
            let length = Int(bytes[i])
            i += 1
            if length == 0 { break }
            // Compression pointers (top bits set) are not allowed in SRV RDATA.
            guard length & 0xC0 == 0, i + length <= bytes.count else { return nil }
            labels.append(String(decoding: bytes[i..<i + length], as: UTF8.self))
            i += length
        }
        guard i == bytes.count else { return nil }
        return SRVRecord(
            priority: u16(0), weight: u16(2), port: u16(4),
            target: labels.isEmpty ? "." : labels.joined(separator: "."))
    }

    /// RFC 2782 order: ascending priority; within a priority, weighted random
    /// selection (weight 0 entries first per the RFC's algorithm).
    /// `random(n)` returns 0...n.
    static func ordered(_ records: [SRVRecord], random: (UInt32) -> UInt32) -> [SRVRecord] {
        var result: [SRVRecord] = []
        for priority in Set(records.map(\.priority)).sorted() {
            // Zero-weight entries first, so they are only picked when the draw is 0.
            var pool = records.filter { $0.priority == priority && $0.weight == 0 }
                + records.filter { $0.priority == priority && $0.weight != 0 }
            while !pool.isEmpty {
                let draw = random(pool.reduce(0) { $0 + UInt32($1.weight) })
                var sum: UInt32 = 0
                let index = pool.firstIndex {
                    sum += UInt32($0.weight)
                    return sum >= draw
                } ?? pool.count - 1
                result.append(pool.remove(at: index))
            }
        }
        return result
    }

    /// Connection attempts in order: `_xmpps-client` and `_xmpp-client` records
    /// merged by priority (direct TLS first on ties), each list RFC-2782-ordered.
    /// A single "." target means that service is unavailable. With no records at
    /// all, the domain itself on 5222 (STARTTLS); with a published ".", nothing.
    /// Trailing dots are stripped from targets.
    static func candidates(
        domain: String, xmpps: [SRVRecord], xmpp: [SRVRecord], random: (UInt32) -> UInt32
    ) -> [XMPPEndpoint] {
        func endpoints(_ records: [SRVRecord], directTLS: Bool) -> [(UInt16, XMPPEndpoint)] {
            if records.count == 1, records[0].target == "." { return [] }
            return ordered(records, random: random).map {
                var host = Substring($0.target)
                while host.hasSuffix(".") { host = host.dropLast() }
                return ($0.priority, XMPPEndpoint(host: String(host), port: $0.port, directTLS: directTLS))
            }
        }
        var tls = endpoints(xmpps, directTLS: true)[...]
        var plain = endpoints(xmpp, directTLS: false)[...]
        if tls.isEmpty, plain.isEmpty {
            // A published "." means the domain offers no XMPP service at all
            // (RFC 6120 §3.2.1): no fallback then.
            let refused = [xmpps, xmpp].contains { $0.count == 1 && $0[0].target == "." }
            return refused ? [] : [XMPPEndpoint(host: domain, port: 5222, directTLS: false)]
        }
        var merged: [XMPPEndpoint] = []
        while !tls.isEmpty || !plain.isEmpty {
            if let t = tls.first, plain.first.map({ t.0 <= $0.0 }) ?? true {
                merged.append(t.1)
                tls.removeFirst()
            } else {
                merged.append(plain.removeFirst().1)
            }
        }
        return merged
    }

    /// Live lookup of both SRV names with dnssd, each with a timeout; a failed
    /// or timed-out query counts as no records. Then `candidates`.
    static func resolve(domain: String, timeout: TimeInterval = 5) async -> [XMPPEndpoint] {
        // ponytail: IDN domains not converted to punycode; callers must pass ASCII domains.
        async let xmpps = query("_xmpps-client._tcp.\(domain)", timeout: timeout)
        async let xmpp = query("_xmpp-client._tcp.\(domain)", timeout: timeout)
        let (tls, plain) = await (xmpps, xmpp)
        return candidates(domain: domain, xmpps: tls, xmpp: plain) { UInt32.random(in: 0...$0) }
    }

    /// State of one in-flight query. Only touched on `queue`, which serialises
    /// the dnssd callback, the timeout and teardown.
    private final class Query: @unchecked Sendable {
        let queue = DispatchQueue(label: "gecko.srv")
        var ref: DNSServiceRef?
        var records: [SRVRecord] = []
        var continuation: CheckedContinuation<[SRVRecord], Never>?

        /// Deallocates the service ref and resumes, at most once.
        func finish() {
            guard let continuation else { return }
            self.continuation = nil
            if let ref { DNSServiceRefDeallocate(ref) }
            ref = nil
            continuation.resume(returning: records)
            Unmanaged.passUnretained(self).release() // balances passRetained in `query`
        }
    }

    private static func query(_ name: String, timeout: TimeInterval) async -> [SRVRecord] {
        let state = Query()
        return await withCheckedContinuation { continuation in
            state.queue.async {
                state.continuation = continuation
                let context = Unmanaged.passRetained(state).toOpaque()
                let callback: DNSServiceQueryRecordReply = { _, flags, _, error, _, rrtype, _, rdlen, rdata, _, context in
                    let state = Unmanaged<Query>.fromOpaque(context!).takeUnretainedValue()
                    if error == kDNSServiceErr_NoError, flags & kDNSServiceFlagsAdd != 0,
                       rrtype == kDNSServiceType_SRV, let rdata,
                       let record = XMPPEndpoints.record(rdata: Data(bytes: rdata, count: Int(rdlen))) {
                        state.records.append(record)
                    }
                    if error != kDNSServiceErr_NoError || flags & kDNSServiceFlagsMoreComing == 0 {
                        state.finish()
                    }
                }
                // ReturnIntermediates delivers NXDOMAIN/no-data promptly as an error
                // instead of waiting for the timeout.
                let status = DNSServiceQueryRecord(
                    &state.ref, DNSServiceFlags(kDNSServiceFlagsReturnIntermediates), 0, name,
                    UInt16(kDNSServiceType_SRV), UInt16(kDNSServiceClass_IN), callback, context)
                guard status == kDNSServiceErr_NoError, let ref = state.ref else {
                    state.ref = nil
                    state.finish()
                    return
                }
                DNSServiceSetDispatchQueue(ref, state.queue)
                state.queue.asyncAfter(deadline: .now() + timeout) { state.finish() }
            }
        }
    }
}
