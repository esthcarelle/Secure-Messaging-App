import Foundation

public struct DirectoryUser: Equatable, Sendable {
    public var userId: String
    public var username: String
    public var publicKey: Data

    public init(userId: String, username: String, publicKey: Data) {
        self.userId = userId
        self.username = username
        self.publicKey = publicKey
    }
}

public struct AuthSession: Codable, Equatable, Sendable {
    public var userId: String
    public var username: String
    public var token: String

    public init(userId: String, username: String, token: String) {
        self.userId = userId
        self.username = username
        self.token = token
    }
}

public struct UploadTicket: Codable, Equatable, Sendable {
    public var objectKey: String
    public var uploadUrl: URL
    public var s3FileUrl: String

    public init(objectKey: String, uploadUrl: URL, s3FileUrl: String) {
        self.objectKey = objectKey
        self.uploadUrl = uploadUrl
        self.s3FileUrl = s3FileUrl
    }
}

public struct OutboundAttachment: Sendable {
    public var fileName: String
    public var mimeType: String
    public var fileBytes: Data
    public var thumbnailBytes: Data?

    public init(fileName: String, mimeType: String, fileBytes: Data, thumbnailBytes: Data?) {
        self.fileName = fileName
        self.mimeType = mimeType
        self.fileBytes = fileBytes
        self.thumbnailBytes = thumbnailBytes
    }
}

public enum DirectoryError: Error, Equatable {
    case invalidURL
    case transport(String)
    case status(Int, String)
    case decoding
}

public struct DirectoryClient: Sendable {
    public var baseURL: URL
    public var session: URLSession

    public init(baseURL: URL, session: URLSession = .shared) {
        let absolute = baseURL.absoluteString.hasSuffix("/") ? baseURL.absoluteString : baseURL.absoluteString + "/"
        self.baseURL = URL(string: absolute) ?? baseURL
        self.session = session
    }

    public func register(username: String, password: String, publicKey: Data) async throws -> AuthSession {
        try await postJSON(
            "v1/auth/register",
            body: [
                "username": username,
                "password": password,
                "publicKey": publicKey.base64EncodedString(),
            ],
            token: nil,
            as: AuthSession.self
        )
    }

    public func login(username: String, password: String) async throws -> AuthSession {
        try await postJSON(
            "v1/auth/login",
            body: ["username": username, "password": password],
            token: nil,
            as: AuthSession.self
        )
    }

    public func uploadPublicKey(_ publicKey: Data, token: String) async throws {
        struct Empty: Decodable {}
        _ = try await putJSON(
            "v1/users/me/public-key",
            body: ["publicKey": publicKey.base64EncodedString()],
            token: token,
            as: Empty.self
        )
    }

    public func lookupUser(_ identifier: String, token: String) async throws -> DirectoryUser {
        struct Response: Decodable {
            let userId: String
            let username: String?
            let publicKey: String
        }
        let encoded = identifier.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? identifier
        let response: Response = try await getJSON("v1/users/\(encoded)/public-key", token: token)
        guard let data = Data(base64Encoded: response.publicKey), data.count == CryptoService.boxKeyBytes else {
            throw DirectoryError.decoding
        }
        return DirectoryUser(
            userId: response.userId,
            username: response.username ?? identifier,
            publicKey: data
        )
    }

    public func uploadTicket(byteLength: Int, token: String) async throws -> UploadTicket {
        try await postJSON(
            "v1/media/upload-url",
            body: ["byteLength": byteLength],
            token: token,
            as: UploadTicket.self
        )
    }

    public func downloadURL(objectKey: String, token: String) async throws -> URL {
        struct Response: Decodable { let downloadUrl: URL }
        let response: Response = try await postJSON(
            "v1/media/download-url",
            body: ["objectKey": objectKey],
            token: token,
            as: Response.self
        )
        return response.downloadUrl
    }

    public func putEncryptedBlob(_ data: Data, to uploadURL: URL) async throws {
        var request = URLRequest(url: uploadURL)
        request.httpMethod = "PUT"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        do {
            let (_, response) = try await session.upload(for: request, from: data)
            try validate(response, data: Data())
        } catch let error as DirectoryError {
            throw error
        } catch {
            throw DirectoryError.transport(error.localizedDescription)
        }
    }

    public func getEncryptedBlob(from url: URL) async throws -> Data {
        do {
            let (data, response) = try await session.data(from: url)
            try validate(response, data: data)
            return data
        } catch let error as DirectoryError {
            throw error
        } catch {
            throw DirectoryError.transport(error.localizedDescription)
        }
    }

    private func postJSON<Body: Encodable, Response: Decodable>(
        _ path: String,
        body: Body,
        token: String?,
        as type: Response.Type
    ) async throws -> Response {
        var request = try makeRequest(path, method: "POST", token: token)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        return try await send(request, as: type)
    }

    private func putJSON<Body: Encodable, Response: Decodable>(
        _ path: String,
        body: Body,
        token: String,
        as type: Response.Type
    ) async throws -> Response {
        var request = try makeRequest(path, method: "PUT", token: token)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        return try await send(request, as: type)
    }

    private func getJSON<Response: Decodable>(_ path: String, token: String) async throws -> Response {
        let request = try makeRequest(path, method: "GET", token: token)
        return try await send(request, as: Response.self)
    }

    private func makeRequest(_ path: String, method: String, token: String?) throws -> URLRequest {
        guard let url = URL(string: path, relativeTo: baseURL)?.absoluteURL else {
            throw DirectoryError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func send<Response: Decodable>(_ request: URLRequest, as type: Response.Type) async throws -> Response {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw DirectoryError.transport(error.localizedDescription)
        }
        try validate(response, data: data)
        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw DirectoryError.decoding
        }
    }

    private func validate(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw DirectoryError.transport("no http response") }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw DirectoryError.status(http.statusCode, body)
        }
    }
}

public actor AttachmentManager {
    private let crypto: CryptoService
    private let directory: DirectoryClient

    public init(crypto: CryptoService, directory: DirectoryClient) {
        self.crypto = crypto
        self.directory = directory
    }

    /// Encrypts the file locally, uploads only ciphertext, and wraps the symmetric key to Bob.
    public func sealAndUpload(
        _ attachment: OutboundAttachment,
        senderSecretKey: Data,
        recipientPublicKey: Data,
        token: String
    ) async throws -> AttachmentPayload {
        let encrypted = try crypto.encryptAttachment(attachment.fileBytes)
        let ticket = try await directory.uploadTicket(byteLength: encrypted.wireBytes.count, token: token)
        try await directory.putEncryptedBlob(encrypted.wireBytes, to: ticket.uploadUrl)
        let wrapped = try crypto.wrapSymmetricKey(
            encrypted.key,
            senderSecretKey: senderSecretKey,
            recipientPublicKey: recipientPublicKey
        )
        let thumbnailWire: Data
        if let thumbnail = attachment.thumbnailBytes, !thumbnail.isEmpty {
            thumbnailWire = try crypto.encryptThumbnail(thumbnail, key: encrypted.key)
        } else {
            thumbnailWire = Data()
        }
        return AttachmentPayload(
            s3FileUrl: ticket.s3FileUrl,
            encryptedS3Key: wrapped.ciphertext,
            s3KeyNonce: wrapped.nonce,
            mimeType: attachment.mimeType,
            fileSize: UInt64(attachment.fileBytes.count),
            fileName: attachment.fileName,
            encryptedThumbnailData: thumbnailWire
        )
    }

    /// Downloads the ciphertext blob and decrypts it with the unwrapped secretbox key.
    public func downloadDecrypted(
        _ payload: AttachmentPayload,
        senderPublicKey: Data,
        recipientSecretKey: Data,
        token: String
    ) async throws -> Data {
        guard let objectKey = payload.objectKey else { throw DirectoryError.invalidURL }
        let symmetricKey = try crypto.unwrapSymmetricKey(
            WrappedKey(ciphertext: payload.encryptedS3Key, nonce: payload.s3KeyNonce),
            senderPublicKey: senderPublicKey,
            recipientSecretKey: recipientSecretKey
        )
        let downloadURL = try await directory.downloadURL(objectKey: objectKey, token: token)
        let wire = try await directory.getEncryptedBlob(from: downloadURL)
        let parts = try EncryptedBlob.unpack(wire)
        return try crypto.decryptAttachment(ciphertext: parts.ciphertext, key: symmetricKey, nonce: parts.nonce)
    }

    public func decryptThumbnail(
        _ payload: AttachmentPayload,
        senderPublicKey: Data,
        recipientSecretKey: Data
    ) throws -> Data? {
        guard !payload.encryptedThumbnailData.isEmpty else { return nil }
        let symmetricKey = try crypto.unwrapSymmetricKey(
            WrappedKey(ciphertext: payload.encryptedS3Key, nonce: payload.s3KeyNonce),
            senderPublicKey: senderPublicKey,
            recipientSecretKey: recipientSecretKey
        )
        let parts = try EncryptedBlob.unpack(payload.encryptedThumbnailData)
        return try crypto.decryptAttachment(ciphertext: parts.ciphertext, key: symmetricKey, nonce: parts.nonce)
    }

    }
