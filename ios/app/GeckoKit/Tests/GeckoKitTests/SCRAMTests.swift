import CryptoKit
import XCTest
@testable import GeckoKit

final class SCRAMTests: XCTestCase {
    private func d(_ s: String) -> Data { Data(s.utf8) }

    func testRFC5802SHA1() throws {
        var s = SCRAM(hash: .sha1, username: "user", password: "pencil", clientNonce: "fyko+d2lbbFgONRv9qkxdawL")
        XCTAssertEqual(s.clientFirst, d("n,,n=user,r=fyko+d2lbbFgONRv9qkxdawL"))
        let final = try s.clientFinal(serverFirst: d("r=fyko+d2lbbFgONRv9qkxdawL3rfcNHYJY1ZVvWVs7j,s=QSXCR+Q6sek8bf92,i=4096"))
        XCTAssertEqual(final, d("c=biws,r=fyko+d2lbbFgONRv9qkxdawL3rfcNHYJY1ZVvWVs7j,p=v0X8v3Bz2T0CJGbJQyF0X+HI4Ts="))
        XCTAssertNoThrow(try s.verify(serverFinal: d("v=rmF9pqV8S7suAoZWja4dJRkFsKQ=")))
        XCTAssertThrowsError(try s.verify(serverFinal: d("v=AmF9pqV8S7suAoZWja4dJRkFsKQ="))) {
            XCTAssertEqual($0 as? SCRAM.Failure, .serverSignatureMismatch)
        }
    }

    func testRFC7677SHA256() throws {
        var s = SCRAM(hash: .sha256, username: "user", password: "pencil", clientNonce: "rOprNGfwEbeRWgbNEkqO")
        let final = try s.clientFinal(serverFirst: d("r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096"))
        XCTAssertEqual(final, d("c=biws,r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,p=dHzbZapWIk4jUhN+Ute9ytag9zjfMHgsqmmiz7AndVQ="))
        XCTAssertNoThrow(try s.verify(serverFinal: d("v=6rriTRBi23WpRR/wtup+mMhUZUn/dB5nLTJRsjl95G4=")))
    }

    func testSHA512SelfConsistent() throws {
        var s = SCRAM(hash: .sha512, username: "user", password: "pencil", clientNonce: "abc")
        let first = "r=abcdef,s=\(Data("salt".utf8).base64EncodedString()),i=4096"
        let final = String(decoding: try s.clientFinal(serverFirst: d(first)), as: UTF8.self)
        XCTAssertTrue(final.hasPrefix("c=biws,r=abcdef,p="))
        // Recompute the server signature independently (PBKDF2 = single block for 64-byte output).
        let pw = SymmetricKey(data: d("pencil"))
        var u = Data(HMAC<SHA512>.authenticationCode(for: d("salt") + Data([0, 0, 0, 1]), using: pw))
        var salted = u
        for _ in 1..<4096 {
            u = Data(HMAC<SHA512>.authenticationCode(for: u, using: pw))
            salted = Data(zip(salted, u).map { $0 ^ $1 })
        }
        let serverKey = Data(HMAC<SHA512>.authenticationCode(for: d("Server Key"), using: SymmetricKey(data: salted)))
        let auth = d("n=user,r=abc,\(first),c=biws,r=abcdef")
        let sig = Data(HMAC<SHA512>.authenticationCode(for: auth, using: SymmetricKey(data: serverKey)))
        XCTAssertNoThrow(try s.verify(serverFinal: d("v=" + sig.base64EncodedString())))
    }

    private func reject(_ first: String, _ failure: SCRAM.Failure) {
        var s = SCRAM(hash: .sha256, username: "u", password: "p", clientNonce: "abc")
        XCTAssertThrowsError(try s.clientFinal(serverFirst: d(first)), first) { XCTAssertEqual($0 as? SCRAM.Failure, failure) }
    }

    func testRejections() {
        reject("r=xyzabc,s=c2FsdA==,i=4096", .nonceMismatch)
        reject("s=c2FsdA==,i=4096", .malformedChallenge)
        reject("r=abcd,i=4096", .malformedChallenge)
        reject("r=abcd,s=c2FsdA==", .malformedChallenge)
        reject("r=abcd,s=!!!,i=4096", .malformedChallenge)
        reject("r=abcd,s=c2FsdA==,i=4095", .iterationsTooLow)
        reject("m=ext,r=abcd,s=c2FsdA==,i=4096", .malformedChallenge)
        let s = SCRAM(hash: .sha256, username: "u", password: "p")
        XCTAssertThrowsError(try s.verify(serverFinal: d("e=invalid-proof"))) {
            XCTAssertEqual($0 as? SCRAM.Failure, .serverError("invalid-proof"))
        }
    }

    func testUsernameEscaping() {
        let s = SCRAM(hash: .sha1, username: "a=b,c", password: "p", clientNonce: "n")
        XCTAssertEqual(s.clientFirst, d("n,,n=a=3Db=2Cc,r=n"))
    }

    func testBest() {
        XCTAssertEqual(SCRAM.best(offered: ["PLAIN", "SCRAM-SHA-1", "SCRAM-SHA-256"]), .sha256)
        XCTAssertEqual(SCRAM.best(offered: ["SCRAM-SHA-512", "SCRAM-SHA-1"]), .sha512)
        XCTAssertEqual(SCRAM.best(offered: ["SCRAM-SHA-1"]), .sha1)
        XCTAssertNil(SCRAM.best(offered: ["PLAIN"]))
    }
}
