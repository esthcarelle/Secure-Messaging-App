import XCTest
@testable import SecureMessagingKit

final class ProtobufTests: XCTestCase {
    func testTextAndEnvelopeRoundTrip() throws {
        let text = TextPayload(textContent: "hello")
        XCTAssertEqual(try TextPayload.parse(text.serialized()), text)

        let envelope = MessageEnvelope(
            messageId: "m1",
            senderId: "alice",
            recipientId: "bob",
            timestamp: 1_700_000_000_123,
            payloadType: .text,
            payloadBytes: Data([0x00, 0xFF, 0x10]),
            nonce: Data(repeating: 0xAB, count: 24),
            hashSignature: Data(repeating: 0xCD, count: 32)
        )
        XCTAssertEqual(try MessageEnvelope.parse(envelope.serialized()), envelope)
    }

    func testAttachmentRoundTripIncludingEmptyThumbnail() throws {
        let payload = AttachmentPayload(
            s3FileUrl: "s3://ciphertext/ciphertext/6f1b1c3e-9a0d-4e1a-9c2b-6a0d9e1c3b11",
            encryptedS3Key: Data([1, 2, 3, 4]),
            s3KeyNonce: Data(repeating: 7, count: 24),
            mimeType: "image/jpeg",
            fileSize: 300,
            fileName: "photo.jpg",
            encryptedThumbnailData: Data()
        )
        let parsed = try AttachmentPayload.parse(payload.serialized())
        XCTAssertEqual(parsed, payload)
        XCTAssertEqual(parsed.objectKey, "ciphertext/6f1b1c3e-9a0d-4e1a-9c2b-6a0d9e1c3b11")
    }

    func testUnknownFieldIsSkipped() throws {
        var bytes = TextPayload(textContent: "kept").serialized()
        bytes.append(0x7A)
        bytes.append(2)
        bytes.append(contentsOf: [UInt8]("hi".utf8))
        XCTAssertEqual(try TextPayload.parse(bytes).textContent, "kept")
    }

    func testTruncatedMessageThrows() {
        XCTAssertThrowsError(try MessageEnvelope.parse(Data([0x0A]))) { error in
            XCTAssertEqual(error as? ProtobufError, .truncated)
        }
    }
}

final class CryptoServiceTests: XCTestCase {
    private let crypto = CryptoService()

    func testTextEnvelopeRoundTrip() throws {
        let alice = try crypto.generateIdentity()
        let bob = try crypto.generateIdentity()
        let envelope = try crypto.sealText(
            "meet at 7",
            messageId: "m-1",
            senderId: "alice",
            recipientId: "bob",
            timestamp: 42,
            senderSecretKey: alice.secretKey,
            recipientPublicKey: bob.publicKey
        )
        let opened = try crypto.openEnvelope(
            packet: envelope.serialized(),
            senderPublicKey: alice.publicKey,
            recipientSecretKey: bob.secretKey
        )
        XCTAssertEqual(try TextPayload.parse(opened.plaintext).textContent, "meet at 7")
        XCTAssertEqual(opened.envelope.hashSignature, crypto.sha256(opened.plaintext))
    }

    func testTamperedHashIsRejected() throws {
        let alice = try crypto.generateIdentity()
        let bob = try crypto.generateIdentity()
        var envelope = try crypto.sealText(
            "secret",
            messageId: "m-2",
            senderId: "alice",
            recipientId: "bob",
            timestamp: 1,
            senderSecretKey: alice.secretKey,
            recipientPublicKey: bob.publicKey
        )
        envelope.hashSignature[0] ^= 0xFF
        XCTAssertThrowsError(
            try crypto.openEnvelope(
                packet: envelope.serialized(),
                senderPublicKey: alice.publicKey,
                recipientSecretKey: bob.secretKey
            )
        ) { error in
            XCTAssertEqual(error as? CryptoError, .integrityCheckFailed)
        }
    }

    func testTamperedCiphertextIsRejected() throws {
        let alice = try crypto.generateIdentity()
        let bob = try crypto.generateIdentity()
        var envelope = try crypto.sealText(
            "secret",
            messageId: "m-3",
            senderId: "alice",
            recipientId: "bob",
            timestamp: 1,
            senderSecretKey: alice.secretKey,
            recipientPublicKey: bob.publicKey
        )
        envelope.payloadBytes[0] ^= 0xFF
        XCTAssertThrowsError(
            try crypto.openEnvelope(
                packet: envelope.serialized(),
                senderPublicKey: alice.publicKey,
                recipientSecretKey: bob.secretKey
            )
        ) { error in
            XCTAssertEqual(error as? CryptoError, .decryptionFailed)
        }
    }

    func testAttachmentKeyWrapRoundTrip() throws {
        let alice = try crypto.generateIdentity()
        let bob = try crypto.generateIdentity()
        let plaintext = Data("image-bytes".utf8)
        let blob = try crypto.encryptAttachment(plaintext)
        let wrapped = try crypto.wrapSymmetricKey(
            blob.key,
            senderSecretKey: alice.secretKey,
            recipientPublicKey: bob.publicKey
        )
        let thumbnail = try crypto.encryptThumbnail(Data("thumb".utf8), key: blob.key)
        let payload = AttachmentPayload(
            s3FileUrl: "s3://bucket/ciphertext/6f1b1c3e-9a0d-4e1a-9c2b-6a0d9e1c3b11",
            encryptedS3Key: wrapped.ciphertext,
            s3KeyNonce: wrapped.nonce,
            mimeType: "image/jpeg",
            fileSize: UInt64(plaintext.count),
            fileName: "a.jpg",
            encryptedThumbnailData: thumbnail
        )
        let envelope = try crypto.sealAttachmentPayload(
            payload,
            messageId: "m-4",
            senderId: "alice",
            recipientId: "bob",
            timestamp: 9,
            senderSecretKey: alice.secretKey,
            recipientPublicKey: bob.publicKey
        )
        let opened = try crypto.openEnvelope(
            packet: envelope.serialized(),
            senderPublicKey: alice.publicKey,
            recipientSecretKey: bob.secretKey
        )
        let decoded = try AttachmentPayload.parse(opened.plaintext)
        let key = try crypto.unwrapSymmetricKey(
            WrappedKey(ciphertext: decoded.encryptedS3Key, nonce: decoded.s3KeyNonce),
            senderPublicKey: alice.publicKey,
            recipientSecretKey: bob.secretKey
        )
        let parts = try EncryptedBlob.unpack(blob.wireBytes)
        let clear = try crypto.decryptAttachment(ciphertext: parts.ciphertext, key: key, nonce: parts.nonce)
        XCTAssertEqual(clear, plaintext)
        let thumbParts = try EncryptedBlob.unpack(decoded.encryptedThumbnailData)
        let thumb = try crypto.decryptAttachment(ciphertext: thumbParts.ciphertext, key: key, nonce: thumbParts.nonce)
        XCTAssertEqual(thumb, Data("thumb".utf8))
    }

    func testSafetyNumberIsOrderIndependent() throws {
        let alice = try crypto.generateIdentity()
        let bob = try crypto.generateIdentity()
        XCTAssertEqual(
            crypto.safetyNumber(localPublicKey: alice.publicKey, remotePublicKey: bob.publicKey),
            crypto.safetyNumber(localPublicKey: bob.publicKey, remotePublicKey: alice.publicKey)
        )
    }
}

final class DatabaseServiceTests: XCTestCase {
    func testMessageAndContactRoundTrip() throws {
        let path = temporaryDatabasePath()
        let key = Data(repeating: 0x11, count: 32)
        let database = try DatabaseService(path: path, key: key)
        let message = StoredMessage(
            messageId: "m",
            conversationId: ConversationID.make("a", "b"),
            senderId: "a",
            recipientId: "b",
            timestampMs: 10,
            payloadType: PayloadType.text.rawValue,
            body: "hi",
            attachmentName: nil,
            attachmentMime: nil,
            attachmentSize: nil,
            attachmentBytes: nil,
            thumbnailBytes: nil,
            deliveryStatus: "sent"
        )
        try database.upsertMessage(message)
        try database.upsertContact(StoredContact(userId: "b", publicKey: Data(repeating: 2, count: 32), safetyVerified: true))
        XCTAssertEqual(try database.messages(conversationId: message.conversationId), [message])
        XCTAssertEqual(try database.contact(userId: "b")?.safetyVerified, true)
        database.close()

        let reopened = try DatabaseService(path: path, key: key)
        XCTAssertEqual(try reopened.messages(conversationId: message.conversationId).first?.body, "hi")
        reopened.close()
    }

    func testWrongKeyDoesNotOpen() throws {
        let path = temporaryDatabasePath()
        let database = try DatabaseService(path: path, key: Data(repeating: 0x22, count: 32))
        database.close()
        XCTAssertThrowsError(try DatabaseService(path: path, key: Data(repeating: 0x33, count: 32)))
    }

    private func temporaryDatabasePath() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("sm-\(UUID().uuidString).db")
            .path
    }
}

final class AttachmentManagerTests: XCTestCase {
    func testUploadAndDownloadRoundTrip() async throws {
        let crypto = CryptoService()
        let alice = try crypto.generateIdentity()
        let bob = try crypto.generateIdentity()
        BlobURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BlobURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let directory = DirectoryClient(baseURL: URL(string: "https://blob.test")!, session: session)
        let manager = AttachmentManager(crypto: crypto, directory: directory)
        let original = Data("plaintext-photo".utf8)
        let payload = try await manager.sealAndUpload(
            OutboundAttachment(
                fileName: "pic.jpg",
                mimeType: "image/jpeg",
                fileBytes: original,
                thumbnailBytes: Data("sm".utf8)
            ),
            senderSecretKey: alice.secretKey,
            recipientPublicKey: bob.publicKey,
            token: "token"
        )
        let downloaded = try await manager.downloadDecrypted(
            payload,
            senderPublicKey: alice.publicKey,
            recipientSecretKey: bob.secretKey,
            token: "token"
        )
        XCTAssertEqual(downloaded, original)
        let thumbnail = try await manager.decryptThumbnail(
            payload,
            senderPublicKey: alice.publicKey,
            recipientSecretKey: bob.secretKey
        )
        XCTAssertEqual(thumbnail, Data("sm".utf8))
        XCTAssertFalse(BlobURLProtocol.storedBlob.isEmpty)
        XCTAssertNotEqual(BlobURLProtocol.storedBlob, original)
    }
}

private final class BlobURLProtocol: URLProtocol {
    static let lock = NSLock()
    static var storedBlob = Data()

    static func reset() {
        lock.lock()
        storedBlob = Data()
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let client else { return }
        let path = url.path
        let method = request.httpMethod ?? "GET"
        let body = Self.readBody(request)

        let status: Int
        let responseBody: Data
        if method == "POST" && path.hasSuffix("/v1/media/upload-url") {
            let ticket: [String: String] = [
                "objectKey": "ciphertext/6f1b1c3e-9a0d-4e1a-9c2b-6a0d9e1c3b11",
                "uploadUrl": "https://blob.test/upload",
                "s3FileUrl": "s3://bucket/ciphertext/6f1b1c3e-9a0d-4e1a-9c2b-6a0d9e1c3b11",
            ]
            responseBody = try! JSONSerialization.data(withJSONObject: ticket)
            status = 200
        } else if method == "PUT" && path.hasSuffix("/upload") {
            Self.lock.lock()
            Self.storedBlob = body
            Self.lock.unlock()
            responseBody = Data()
            status = 200
        } else if method == "POST" && path.hasSuffix("/v1/media/download-url") {
            let ticket = ["downloadUrl": "https://blob.test/download"]
            responseBody = try! JSONSerialization.data(withJSONObject: ticket)
            status = 200
        } else if method == "GET" && path.hasSuffix("/download") {
            Self.lock.lock()
            responseBody = Self.storedBlob
            Self.lock.unlock()
            status = 200
        } else {
            responseBody = Data("missing".utf8)
            status = 404
        }

        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: [
            "Content-Type": "application/json",
        ])!
        client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client.urlProtocol(self, didLoad: responseBody)
        client.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func readBody(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let count = stream.read(buffer, maxLength: 4096)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
