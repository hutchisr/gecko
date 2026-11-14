import CommonCrypto
import CryptoKit
import Foundation

/// SASL SCRAM client (RFC 5802, RFC 7677) without channel binding (gs2 header "n,,").
struct SCRAM {
    enum Hash: String, CaseIterable {
        case sha1 = "SCRAM-SHA-1", sha256 = "SCRAM-SHA-256", sha512 = "SCRAM-SHA-512"
    }

    enum Failure: Error, Equatable {
        case malformedChallenge, nonceMismatch, iterationsTooLow, serverSignatureMismatch, serverError(String)
    }

    let hash: Hash
    private let password: String
    private let clientNonce: String
    private let clientFirstBare: String
    /// Expected server signature, known once `clientFinal` has run.
    private var serverSignature: Data?

    init(hash: Hash, username: String, password: String, clientNonce: String = SCRAM.randomNonce()) {
        self.hash = hash
        // ponytail: SASLprep (RFC 4013) approximated as NFKC; full prohibited/bidi tables skipped.
        let user = username.precomposedStringWithCompatibilityMapping
            .replacingOccurrences(of: "=", with: "=3D")
            .replacingOccurrences(of: ",", with: "=2C")
        self.password = password.precomposedStringWithCompatibilityMapping
        self.clientNonce = clientNonce
        clientFirstBare = "n=\(user),r=\(clientNonce)"
    }

    static func randomNonce() -> String {
        Data((0..<24).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
    }

    /// The initial response, sent with <auth mechanism=...>.
    var clientFirst: Data { Data(("n,," + clientFirstBare).utf8) }

    /// Answers the server-first-message; returns client-final-message.
    mutating func clientFinal(serverFirst: Data) throws -> Data {
        guard let text = String(data: serverFirst, encoding: .utf8) else { throw Failure.malformedChallenge }
        let attrs = try Self.attributes(text)
        guard attrs["m"] == nil else { throw Failure.malformedChallenge }
        guard let nonce = attrs["r"], let s = attrs["s"], let i = attrs["i"],
              let salt = Data(base64Encoded: s), let iterations = Int(i)
        else { throw Failure.malformedChallenge }
        guard nonce.hasPrefix(clientNonce), nonce.count > clientNonce.count else { throw Failure.nonceMismatch }
        guard iterations >= 4096 else { throw Failure.iterationsTooLow }

        let salted = pbkdf2(salt: salt, rounds: iterations)
        let clientKey = hmac(salted, Data("Client Key".utf8))
        let storedKey = digest(clientKey)
        let withoutProof = "c=biws,r=\(nonce)"
        let auth = Data("\(clientFirstBare),\(text),\(withoutProof)".utf8)
        let signature = hmac(storedKey, auth)
        let proof = Data(zip(clientKey, signature).map { $0 ^ $1 })
        serverSignature = hmac(hmac(salted, Data("Server Key".utf8)), auth)
        return Data("\(withoutProof),p=\(proof.base64EncodedString())".utf8)
    }

    /// Checks server-final-message (`v=` signature, or `e=` error).
    func verify(serverFinal: Data) throws {
        guard let text = String(data: serverFinal, encoding: .utf8) else { throw Failure.malformedChallenge }
        let attrs = try Self.attributes(text)
        if let e = attrs["e"] { throw Failure.serverError(e) }
        guard let expected = serverSignature, let v = attrs["v"], let got = Data(base64Encoded: v)
        else { throw Failure.malformedChallenge }
        guard got.count == expected.count, zip(got, expected).reduce(0, { $0 | ($1.0 ^ $1.1) }) == 0
        else { throw Failure.serverSignatureMismatch }
    }

    /// Strongest mechanism both sides offer (SHA-512, then 256, then 1), nil when none.
    static func best(offered: [String]) -> Hash? {
        [Hash.sha512, .sha256, .sha1].first { offered.contains($0.rawValue) }
    }

    /// Parses `k=v,k=v` into a map keyed by the single-letter attribute name.
    private static func attributes(_ text: String) throws -> [String: String] {
        var out: [String: String] = [:]
        for part in text.split(separator: ",", omittingEmptySubsequences: false) {
            guard part.count >= 2, part.dropFirst().first == "=" else { throw Failure.malformedChallenge }
            out[String(part.prefix(1))] = String(part.dropFirst(2))
        }
        return out
    }

    private func hmac(_ key: Data, _ data: Data) -> Data {
        let k = SymmetricKey(data: key)
        switch hash {
        case .sha1: return Data(HMAC<Insecure.SHA1>.authenticationCode(for: data, using: k))
        case .sha256: return Data(HMAC<SHA256>.authenticationCode(for: data, using: k))
        case .sha512: return Data(HMAC<SHA512>.authenticationCode(for: data, using: k))
        }
    }

    private func digest(_ data: Data) -> Data {
        switch hash {
        case .sha1: return Data(Insecure.SHA1.hash(data: data))
        case .sha256: return Data(SHA256.hash(data: data))
        case .sha512: return Data(SHA512.hash(data: data))
        }
    }

    private func pbkdf2(salt: Data, rounds: Int) -> Data {
        let (prf, length): (Int, Int) = switch hash {
        case .sha1: (kCCPRFHmacAlgSHA1, 20)
        case .sha256: (kCCPRFHmacAlgSHA256, 32)
        case .sha512: (kCCPRFHmacAlgSHA512, 64)
        }
        let pw = Array(password.utf8)
        var out = [UInt8](repeating: 0, count: length)
        salt.withUnsafeBytes { s in
            _ = pw.withUnsafeBufferPointer { p in
                p.withMemoryRebound(to: Int8.self) { p in
                    CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), p.baseAddress, pw.count,
                                         s.bindMemory(to: UInt8.self).baseAddress, salt.count,
                                         CCPseudoRandomAlgorithm(prf), UInt32(rounds), &out, length)
                }
            }
        }
        return Data(out)
    }
}
