import CryptoKit
import Foundation

/// Why a minisign key or signature was refused.
public enum MinisignError: Error, Equatable, LocalizedError {
    case malformedPublicKey
    case malformedSignature
    case unsupportedAlgorithm
    /// The signature was made with another key; both are key IDs as minisign prints them.
    case wrongKey(expected: String, found: String)
    case badSignature
    case badTrustedComment

    public var errorDescription: String? {
        switch self {
        case .malformedPublicKey:
            return "the update signing key couldn't be read"
        case .malformedSignature:
            return "the signature couldn't be read"
        case .unsupportedAlgorithm:
            return "the signature uses an algorithm minisign doesn't define"
        case let .wrongKey(expected, found):
            return "the signature is from key \(found), not the Symphony key \(expected)"
        case .badSignature:
            return "the signature doesn't match the download"
        case .badTrustedComment:
            return "the signature's trusted comment was altered"
        }
    }
}

/// A minisign Ed25519 public key: `Ed`, an 8-byte key ID and the 32-byte key, in base64.
public struct MinisignPublicKey: Equatable {
    public let keyID: Data
    public let key: Data

    /// Reads the base64 key line, or a whole `minisign.pub` file with its untrusted comment.
    public init(_ text: String) throws {
        let line = text.split(whereSeparator: \.isNewline)
            .map { String($0).trimmingWhitespace() }
            .first { !$0.isEmpty && !$0.hasPrefix(Minisign.untrustedCommentPrefix) }
        guard let line, let bytes = Data(base64Encoded: line), bytes.count == 42,
            bytes.prefix(2) == Minisign.legacyAlgorithm
        else { throw MinisignError.malformedPublicKey }
        keyID = bytes.subdata(in: 2 ..< 10)
        key = bytes.subdata(in: 10 ..< 42)
    }

    /// The key ID as minisign prints it, for example `70A99C922E457B6B`.
    public var keyIDString: String { Minisign.keyIDString(keyID) }
}

/// A `.minisig` file: the signature of the file (or of its BLAKE2b-512 hash), a trusted comment, and a signature
/// over both that binds the comment to the file.
public struct MinisignSignature: Equatable {
    public enum Algorithm: Equatable {
        /// `Ed`: the signature covers the file itself.
        case legacy
        /// `ED`: the signature covers the file's BLAKE2b-512 hash, minisign's default.
        case prehashed
    }

    public let algorithm: Algorithm
    public let keyID: Data
    public let signature: Data
    public let trustedComment: String
    public let globalSignature: Data

    public init(_ text: String) throws {
        let lines = text.split(whereSeparator: \.isNewline).map { String($0).trimmingWhitespace() }
        guard lines.count >= 4, lines[0].hasPrefix(Minisign.untrustedCommentPrefix),
            let bytes = Data(base64Encoded: lines[1]), bytes.count == 74,
            lines[2].hasPrefix(Minisign.trustedCommentPrefix),
            let global = Data(base64Encoded: lines[3]), global.count == 64
        else { throw MinisignError.malformedSignature }

        switch bytes.prefix(2) {
        case Minisign.legacyAlgorithm:
            algorithm = .legacy
        case Minisign.prehashedAlgorithm:
            algorithm = .prehashed
        default:
            throw MinisignError.unsupportedAlgorithm
        }
        keyID = bytes.subdata(in: 2 ..< 10)
        signature = bytes.subdata(in: 10 ..< 74)
        trustedComment = String(lines[2].dropFirst(Minisign.trustedCommentPrefix.count))
        globalSignature = global
    }
}

/// Verifies minisign signatures with CryptoKit, without the minisign tool.
public enum Minisign {
    static let untrustedCommentPrefix = "untrusted comment:"
    static let trustedCommentPrefix = "trusted comment: "
    static let legacyAlgorithm = Data("Ed".utf8)
    static let prehashedAlgorithm = Data("ED".utf8)

    /// Throws unless `signature` was made over `message` by `publicKey`, trusted comment included.
    public static func verify(_ message: Data, signature: MinisignSignature, publicKey: MinisignPublicKey) throws {
        guard signature.keyID == publicKey.keyID else {
            throw MinisignError.wrongKey(expected: publicKey.keyIDString, found: keyIDString(signature.keyID))
        }
        guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey.key) else {
            throw MinisignError.malformedPublicKey
        }
        let signed = signature.algorithm == .prehashed ? Blake2b.hash(message) : message
        guard key.isValidSignature(signature.signature, for: signed) else { throw MinisignError.badSignature }
        let comment = signature.signature + Data(signature.trustedComment.utf8)
        guard key.isValidSignature(signature.globalSignature, for: comment) else {
            throw MinisignError.badTrustedComment
        }
    }

    /// minisign prints key IDs as the little-endian number they encode, in upper-case hex.
    static func keyIDString(_ keyID: Data) -> String {
        keyID.reversed().map { String(format: "%02X", $0) }.joined()
    }
}
