import CryptoKit
import Foundation
import Sodium

public struct IdentityKeyPair: Equatable, Sendable {
    public let publicKey: Data
    public let secretKey: Data

    public init(publicKey: Data, secretKey: Data) {
        self.publicKey = publicKey
        self.secretKey = secretKey
    }
}

public struct EncryptedBlob: Equatable, Sendable {
    public let key: Data
    public let nonce: Data
    public let ciphertext: Data

    public init(key: Data, nonce: Data, ciphertext: Data) {
        self.key = key
        self.nonce = nonce
        self.ciphertext = ciphertext
    }

    /// On-disk and on-S3 layout: 24-byte nonce || secretbox ciphertext.
    public var wireBytes: Data {
        nonce + ciphertext
    }

    public static func unpack(_ wire: Data) throws -> (nonce: Data, ciphertext: Data) {
        guard wire.count > CryptoService.secretNonceBytes + CryptoService.macBytes else {
            throw CryptoError.invalidNonceLength
        }
        let nonce = wire.prefix(CryptoService.secretNonceBytes)
        let ciphertext = wire.dropFirst(CryptoService.secretNonceBytes)
        return (Data(nonce), Data(ciphertext))
    }
}

public struct WrappedKey: Equatable, Sendable {
    public let ciphertext: Data
    public let nonce: Data

    public init(ciphertext: Data, nonce: Data) {
        self.ciphertext = ciphertext
        self.nonce = nonce
    }
}

public struct OpenedPayload: Equatable, Sendable {
    public let envelope: MessageEnvelope
    public let plaintext: Data

    public init(envelope: MessageEnvelope, plaintext: Data) {
        self.envelope = envelope
        self.plaintext = plaintext
    }
}

public enum CryptoError: Error, Equatable, Sendable {
    case keyGenerationFailed
    case randomFailed
    case invalidKeyLength
    case invalidNonceLength
    case encryptionFailed
    case decryptionFailed
    case integrityCheckFailed
    case payloadTooLarge
}

/// Libsodium crypto_box / crypto_secretbox plus CryptoKit SHA-256.
/// Long-term Curve25519 keys do not provide post-compromise forward secrecy.
public final class CryptoService: @unchecked Sendable {
    public static let boxKeyBytes = 32
    public static let boxNonceBytes = 24
    public static let secretKeyBytes = 32
    public static let secretNonceBytes = 24
    public static let macBytes = 16
    public static let maxPlaintextBytes = 25 * 1024 * 1024

    private let sodium = Sodium()
    private let lock = NSLock()

    public init() {}

    public func generateIdentity() throws -> IdentityKeyPair {
        try withLock {
            guard let pair = sodium.box.keyPair(),
                  pair.publicKey.count == Self.boxKeyBytes,
                  pair.secretKey.count == Self.boxKeyBytes
            else { throw CryptoError.keyGenerationFailed }
            return IdentityKeyPair(publicKey: Data(pair.publicKey), secretKey: Data(pair.secretKey))
        }
    }

    public func sha256(_ data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }

    /// Stable comparison string for an in-person identity check. Sorting the keys
    /// makes the number identical on both devices.
    public func safetyNumber(localPublicKey: Data, remotePublicKey: Data) -> String {
        let material = [localPublicKey, remotePublicKey]
            .sorted { $0.lexicographicallyPrecedes($1) }
            .reduce(into: Data()) { $0.append($1) }
        let digest = sha256(material)
        let groups = stride(from: 0, to: 16, by: 2).map { index -> String in
            let value = UInt16(digest[index]) << 8 | UInt16(digest[index + 1])
            return String(format: "%05d", Int(value))
        }
        return groups.joined(separator: " ")
    }

    public func sealText(
        _ text: String,
        messageId: String,
        senderId: String,
        recipientId: String,
        timestamp: Int64,
        senderSecretKey: Data,
        recipientPublicKey: Data
    ) throws -> MessageEnvelope {
        let packed = TextPayload(textContent: text).serialized()
        return try sealPacked(
            packed,
            payloadType: .text,
            messageId: messageId,
            senderId: senderId,
            recipientId: recipientId,
            timestamp: timestamp,
            senderSecretKey: senderSecretKey,
            recipientPublicKey: recipientPublicKey
        )
    }

    public func sealAttachmentPayload(
        _ payload: AttachmentPayload,
        messageId: String,
        senderId: String,
        recipientId: String,
        timestamp: Int64,
        senderSecretKey: Data,
        recipientPublicKey: Data
    ) throws -> MessageEnvelope {
        try sealPacked(
            payload.serialized(),
            payloadType: .attachment,
            messageId: messageId,
            senderId: senderId,
            recipientId: recipientId,
            timestamp: timestamp,
            senderSecretKey: senderSecretKey,
            recipientPublicKey: recipientPublicKey
        )
    }

    public func openEnvelope(
        packet: Data,
        senderPublicKey: Data,
        recipientSecretKey: Data
    ) throws -> OpenedPayload {
        let envelope = try MessageEnvelope.parse(packet)
        let plaintext = try openBox(
            ciphertext: envelope.payloadBytes,
            senderPublicKey: senderPublicKey,
            recipientSecretKey: recipientSecretKey,
            nonce: envelope.nonce
        )
        let fingerprint = sha256(plaintext)
        guard constantTimeEqual(fingerprint, envelope.hashSignature) else {
            throw CryptoError.integrityCheckFailed
        }
        return OpenedPayload(envelope: envelope, plaintext: plaintext)
    }

    public func encryptAttachment(_ plaintext: Data) throws -> EncryptedBlob {
        try guardSize(plaintext)
        return try withLock {
            let key = sodium.secretBox.key()
            let nonce = sodium.secretBox.nonce()
            guard key.count == Self.secretKeyBytes, nonce.count == Self.secretNonceBytes else {
                throw CryptoError.randomFailed
            }
            guard let ciphertext = sodium.secretBox.seal(
                message: [UInt8](plaintext),
                secretKey: key,
                nonce: nonce
            ) else { throw CryptoError.encryptionFailed }
            return EncryptedBlob(key: Data(key), nonce: Data(nonce), ciphertext: Data(ciphertext))
        }
    }

    /// Secretbox under an existing file key. The returned bytes are nonce || ciphertext.
    public func encryptThumbnail(_ plaintext: Data, key: Data) throws -> Data {
        try guardSize(plaintext)
        guard key.count == Self.secretKeyBytes else { throw CryptoError.invalidKeyLength }
        return try withLock {
            let nonce = sodium.secretBox.nonce()
            guard nonce.count == Self.secretNonceBytes else { throw CryptoError.randomFailed }
            guard let ciphertext = sodium.secretBox.seal(
                message: [UInt8](plaintext),
                secretKey: [UInt8](key),
                nonce: nonce
            ) else { throw CryptoError.encryptionFailed }
            return Data(nonce) + Data(ciphertext)
        }
    }

    public func decryptAttachment(ciphertext: Data, key: Data, nonce: Data) throws -> Data {
        try guardSize(ciphertext)
        guard key.count == Self.secretKeyBytes else { throw CryptoError.invalidKeyLength }
        guard nonce.count == Self.secretNonceBytes else { throw CryptoError.invalidNonceLength }
        return try withLock {
            guard let plaintext = sodium.secretBox.open(
                authenticatedCipherText: [UInt8](ciphertext),
                secretKey: [UInt8](key),
                nonce: [UInt8](nonce)
            ) else { throw CryptoError.decryptionFailed }
            return Data(plaintext)
        }
    }

    public func wrapSymmetricKey(
        _ symmetricKey: Data,
        senderSecretKey: Data,
        recipientPublicKey: Data
    ) throws -> WrappedKey {
        guard symmetricKey.count == Self.secretKeyBytes else { throw CryptoError.invalidKeyLength }
        let nonce = try randomBoxNonce()
        let ciphertext = try sealBox(
            plaintext: symmetricKey,
            recipientPublicKey: recipientPublicKey,
            senderSecretKey: senderSecretKey,
            nonce: nonce
        )
        return WrappedKey(ciphertext: ciphertext, nonce: nonce)
    }

    public func unwrapSymmetricKey(
        _ wrapped: WrappedKey,
        senderPublicKey: Data,
        recipientSecretKey: Data
    ) throws -> Data {
        let key = try openBox(
            ciphertext: wrapped.ciphertext,
            senderPublicKey: senderPublicKey,
            recipientSecretKey: recipientSecretKey,
            nonce: wrapped.nonce
        )
        guard key.count == Self.secretKeyBytes else { throw CryptoError.invalidKeyLength }
        return key
    }

    // MARK: - Pipeline

    public func seal(
        _ plaintext: Data,
        payloadType: PayloadType,
        messageId: String,
        senderId: String,
        recipientId: String,
        timestamp: Int64,
        senderSecretKey: Data,
        recipientPublicKey: Data
    ) throws -> MessageEnvelope {
        try sealPacked(
            plaintext,
            payloadType: payloadType,
            messageId: messageId,
            senderId: senderId,
            recipientId: recipientId,
            timestamp: timestamp,
            senderSecretKey: senderSecretKey,
            recipientPublicKey: recipientPublicKey
        )
    }

    private func sealPacked(
        _ plaintext: Data,
        payloadType: PayloadType,
        messageId: String,
        senderId: String,
        recipientId: String,
        timestamp: Int64,
        senderSecretKey: Data,
        recipientPublicKey: Data
    ) throws -> MessageEnvelope {
        // 1. Pack already happened. 2. Hash the plaintext payload bytes.
        let fingerprint = sha256(plaintext)
        // 3. Encrypt the packed payload to the recipient's Curve25519 key.
        let nonce = try randomBoxNonce()
        let ciphertext = try sealBox(
            plaintext: plaintext,
            recipientPublicKey: recipientPublicKey,
            senderSecretKey: senderSecretKey,
            nonce: nonce
        )
        return MessageEnvelope(
            messageId: messageId,
            senderId: senderId,
            recipientId: recipientId,
            timestamp: timestamp,
            payloadType: payloadType,
            payloadBytes: ciphertext,
            nonce: nonce,
            hashSignature: fingerprint
        )
    }

    private func sealBox(
        plaintext: Data,
        recipientPublicKey: Data,
        senderSecretKey: Data,
        nonce: Data
    ) throws -> Data {
        guard recipientPublicKey.count == Self.boxKeyBytes,
              senderSecretKey.count == Self.boxKeyBytes
        else { throw CryptoError.invalidKeyLength }
        guard nonce.count == Self.boxNonceBytes else { throw CryptoError.invalidNonceLength }
        return try withLock {
            guard let ciphertext = sodium.box.seal(
                message: [UInt8](plaintext),
                recipientPublicKey: [UInt8](recipientPublicKey),
                senderSecretKey: [UInt8](senderSecretKey),
                nonce: [UInt8](nonce)
            ) else { throw CryptoError.encryptionFailed }
            return Data(ciphertext)
        }
    }

    private func openBox(
        ciphertext: Data,
        senderPublicKey: Data,
        recipientSecretKey: Data,
        nonce: Data
    ) throws -> Data {
        guard senderPublicKey.count == Self.boxKeyBytes,
              recipientSecretKey.count == Self.boxKeyBytes
        else { throw CryptoError.invalidKeyLength }
        guard nonce.count == Self.boxNonceBytes else { throw CryptoError.invalidNonceLength }
        return try withLock {
            guard let plaintext = sodium.box.open(
                authenticatedCipherText: [UInt8](ciphertext),
                senderPublicKey: [UInt8](senderPublicKey),
                recipientSecretKey: [UInt8](recipientSecretKey),
                nonce: [UInt8](nonce)
            ) else { throw CryptoError.decryptionFailed }
            return Data(plaintext)
        }
    }

    private func randomBoxNonce() throws -> Data {
        try withLock {
            let nonce = sodium.box.nonce()
            guard nonce.count == Self.boxNonceBytes else { throw CryptoError.randomFailed }
            return Data(nonce)
        }
    }

    private func guardSize(_ data: Data) throws {
        if data.count > Self.maxPlaintextBytes { throw CryptoError.payloadTooLarge }
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    private func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for (left, right) in zip(lhs, rhs) {
            difference |= left ^ right
        }
        return difference == 0
    }
}

public enum MQTTTopics {
    public static func incoming(userId: String) -> String {
        "users/\(userId)/messages"
    }

    public static func ack(userId: String) -> String {
        "users/\(userId)/ack"
    }

    public static func history(userId: String) -> String {
        "users/\(userId)/history"
    }
}

public enum ConversationID {
    public static func make(_ first: String, _ second: String) -> String {
        [first, second].sorted().joined(separator: "|")
    }
}
