import CryptoKit
import XCTest
@testable import SymphonyBarCore

/// Test vectors made with minisign 0.12:
///
///     minisign -G -W -p test.pub -s test.key
///     printf 'Symphony update test vector\n' > msg.txt
///     minisign -S -s test.key -m msg.txt -t "Symphony 0.0.1.42 build 42 commit abc" -x prehashed.minisig
///     minisign -S -l -s test.key -m msg.txt -t "legacy vector" -x legacy.minisig
enum MinisignVectors {
    static let message = Data("Symphony update test vector\n".utf8)

    static let publicKeyFile = """
        untrusted comment: minisign public key 70A99C922E457B6B
        RWRre0UukpypcMGDGTkdLySlhadvnn8pZxp11Sm9htPohKrPzg1nt00D
        """

    /// Another key, ID E3E2952EA3702B20.
    static let otherPublicKey = "RWQgK3CjLpXi46HdI5hSLeXzFAfu6Rz+mzaDTl/1k10S36cdezz7dl5x"

    static let prehashed = """
        untrusted comment: signature from minisign secret key
        RURre0UukpypcBJ0UOoXgQgidYmdndi3ougpYCvJgxaCAAImcC8donoLnZN2wHbC9brHFkMNUJy8sxeAr+5z9LxdJ5oIJlCpTg4=
        trusted comment: Symphony 0.0.1.42 build 42 commit abc
        Zg0aTmblRe8fZGOYJ6fUip6zkTVDHBmV/6uHTkhV6pr2hV2/ZRiv6E1yBHwNTNdL5+eov0dto4FwPnKaRNd9Cw==

        """

    static let legacy = """
        untrusted comment: signature from minisign secret key
        RWRre0UukpypcLlZ1SXO0cJXFUTnwJ7UK16fEOM6LPRMe+xWXSgq8Errv1TTxqH8bJINYX2esnbOnz/yUFrYb5jkpE60Fx0rYgU=
        trusted comment: legacy vector
        ossIYcWP/TPzGmeLqyKupE9QnDk+QJryjBmDNhMN9Od/ovtXUHs52mzzUmjFOoAs7oOQVAdnRx5Z1ali5JZuCw==

        """
}

/// Signs like `minisign -S` with a fresh CryptoKit key, for downloads made during a test.
struct TestMinisignKey {
    let privateKey = Curve25519.Signing.PrivateKey()
    let keyID = Data((0 ..< 8).map { _ in UInt8.random(in: 0 ... 255) })

    func publicKey() throws -> MinisignPublicKey {
        try MinisignPublicKey((Data("Ed".utf8) + keyID + privateKey.publicKey.rawRepresentation).base64EncodedString())
    }

    func sign(_ data: Data, trustedComment: String = "timestamp:0") throws -> String {
        let signature = try privateKey.signature(for: Blake2b.hash(data))
        let global = try privateKey.signature(for: signature + Data(trustedComment.utf8))
        return """
            untrusted comment: signature from a test key
            \((Data("ED".utf8) + keyID + signature).base64EncodedString())
            trusted comment: \(trustedComment)
            \(global.base64EncodedString())

            """
    }
}

final class MinisignTests: XCTestCase {
    private func key() throws -> MinisignPublicKey {
        try MinisignPublicKey(MinisignVectors.publicKeyFile)
    }

    func testParsesThePublicKeyFileAndBareKey() throws {
        let key = try key()

        XCTAssertEqual(key.keyIDString, "70A99C922E457B6B")
        XCTAssertEqual(key.key.count, 32)
        XCTAssertEqual(try MinisignPublicKey("  RWRre0UukpypcMGDGTkdLySlhadvnn8pZxp11Sm9htPohKrPzg1nt00D\n"), key)
    }

    func testParsesTheSignatureFile() throws {
        let prehashed = try MinisignSignature(MinisignVectors.prehashed)
        let legacy = try MinisignSignature(MinisignVectors.legacy)

        XCTAssertEqual(prehashed.algorithm, .prehashed)
        XCTAssertEqual(prehashed.trustedComment, "Symphony 0.0.1.42 build 42 commit abc")
        XCTAssertEqual(Minisign.keyIDString(prehashed.keyID), "70A99C922E457B6B")
        XCTAssertEqual(prehashed.signature.count, 64)
        XCTAssertEqual(legacy.algorithm, .legacy)
        XCTAssertEqual(legacy.trustedComment, "legacy vector")
    }

    func testVerifiesMinisignsPrehashedAndLegacySignatures() throws {
        let key = try key()

        XCTAssertNoThrow(try Minisign.verify(MinisignVectors.message, signature: MinisignSignature(MinisignVectors.prehashed), publicKey: key))
        XCTAssertNoThrow(try Minisign.verify(MinisignVectors.message, signature: MinisignSignature(MinisignVectors.legacy), publicKey: key))
    }

    func testRefusesAnAlteredMessage() throws {
        let altered = Data("Symphony update test vector!\n".utf8)

        for vector in [MinisignVectors.prehashed, MinisignVectors.legacy] {
            XCTAssertThrowsError(try Minisign.verify(altered, signature: MinisignSignature(vector), publicKey: key())) {
                XCTAssertEqual($0 as? MinisignError, .badSignature)
            }
        }
    }

    func testRefusesAnAlteredTrustedComment() throws {
        let altered = MinisignVectors.prehashed.replacingOccurrences(of: "build 42", with: "build 43")

        XCTAssertThrowsError(try Minisign.verify(MinisignVectors.message, signature: MinisignSignature(altered), publicKey: key())) {
            XCTAssertEqual($0 as? MinisignError, .badTrustedComment)
        }
    }

    func testRefusesASignatureFromAnotherKey() throws {
        let other = try MinisignPublicKey(MinisignVectors.otherPublicKey)

        XCTAssertThrowsError(
            try Minisign.verify(MinisignVectors.message, signature: MinisignSignature(MinisignVectors.prehashed), publicKey: other)
        ) {
            XCTAssertEqual($0 as? MinisignError, .wrongKey(expected: "E3E2952EA3702B20", found: "70A99C922E457B6B"))
        }
    }

    func testRefusesMalformedInput() {
        for text in ["", "not base64", "untrusted comment: only a comment", String(MinisignVectors.otherPublicKey.dropLast(4))] {
            XCTAssertThrowsError(try MinisignPublicKey(text)) { XCTAssertEqual($0 as? MinisignError, .malformedPublicKey) }
        }

        let lines = MinisignVectors.prehashed.split(separator: "\n").map(String.init)
        for text in [
            "",
            lines.dropLast().joined(separator: "\n"),
            lines.dropFirst().joined(separator: "\n"),
            [lines[0], lines[1], "comment: x", lines[3]].joined(separator: "\n"),
            [lines[0], String(lines[1].dropLast(8)), lines[2], lines[3]].joined(separator: "\n"),
        ] {
            XCTAssertThrowsError(try MinisignSignature(text)) { XCTAssertEqual($0 as? MinisignError, .malformedSignature) }
        }

        var bytes = Data(base64Encoded: lines[1])!
        bytes.replaceSubrange(0 ..< 2, with: Data("Xx".utf8))
        let unknown = [lines[0], bytes.base64EncodedString(), lines[2], lines[3]].joined(separator: "\n")
        XCTAssertThrowsError(try MinisignSignature(unknown)) { XCTAssertEqual($0 as? MinisignError, .unsupportedAlgorithm) }
    }

    func testBlake2bMatchesKnownHashes() {
        func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

        XCTAssertEqual(
            hex(Blake2b.hash(Data())),
            "786a02f742015903c6c6fd852552d272912f4740e15847618a86e217f71f5419d25e1031afee585313896444934eb04b903a685b1448b755d56f701afe9be2ce"
        )
        XCTAssertEqual(
            hex(Blake2b.hash(Data("abc".utf8))),
            "ba80a53f981c4d0d6a2797b69f12f6e94c212f14685ac4b74b12bb6fdbffa2d17d87c5392aab792dc252d5de4533cc9518d38aa8dbf1925ab92386edd4009923"
        )
        // Six full blocks: the last full block is the final one.
        XCTAssertEqual(
            hex(Blake2b.hash(Data((0 ..< 768).map { UInt8($0 % 256) }))),
            "323e97a7a859ee63c9013debb0ca995811e73117a2f574723416e596ebc184e37a59b66d2f597df4a7c1b0d1d41a1a7f28774f46a6864d56c57b9d6c5f7302fb"
        )
    }

    func testSignaturesMadeByTheTestKeyVerify() throws {
        let key = TestMinisignKey()
        let data = Data("a zip".utf8)

        XCTAssertNoThrow(try Minisign.verify(data, signature: MinisignSignature(key.sign(data)), publicKey: key.publicKey()))
    }
}
