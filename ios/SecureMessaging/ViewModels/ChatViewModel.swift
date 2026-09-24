import SwiftUI
import SecureMessagingKit

struct ChatItem: Identifiable, Equatable {
    enum Kind: Equatable {
        case text(String)
        case attachment(name: String, mime: String, image: Data?)
    }

    var id: String
    var isOutgoing: Bool
    var timestamp: Date
    var kind: Kind
    var status: String
}

@MainActor
final class ChatViewModel: ObservableObject {
    @Published var recipientId = ""
    @Published var recipientStatus = ""
    @Published var draft = ""
    @Published var messages: [ChatItem] = []
    @Published var errorMessage: String?
    @Published var isSending = false
    @Published var safetyNumber = ""
    @Published var contactVerified = false

    let userId: String
    private let token: String
    private let secretKey: Data
    private let publicKey: Data
    private let crypto: CryptoService
    private let database: DatabaseService
    private let directory: DirectoryClient
    private let mqtt: MQTTManager
    private let attachments: AttachmentManager

    init(
        userId: String,
        token: String,
        secretKey: Data,
        publicKey: Data,
        crypto: CryptoService,
        database: DatabaseService,
        directory: DirectoryClient,
        mqtt: MQTTManager,
        attachments: AttachmentManager
    ) {
        self.userId = userId
        self.token = token
        self.secretKey = secretKey
        self.publicKey = publicKey
        self.crypto = crypto
        self.database = database
        self.directory = directory
        self.mqtt = mqtt
        self.attachments = attachments
    }

    func openRecipient() async {
        let entered = recipientId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !entered.isEmpty else {
            errorMessage = "Enter a username or user id."
            return
        }
        isSending = true
        defer { isSending = false }
        do {
            let user = try await resolveRecipient(entered)
            recipientStatus = "Chat with \(user.username) is ready."
            reload()
        } catch {
            recipientStatus = ""
            errorMessage = explain(error)
        }
    }

    func reload() {
        let conversation = ConversationID.make(userId, recipientId)
        guard !recipientId.isEmpty else {
            messages = []
            recipientStatus = ""
            return
        }
        do {
            let rows = try database.messages(conversationId: conversation)
            messages = rows.map(display)
            if let contact = try database.contact(userId: recipientId) {
                contactVerified = contact.safetyVerified
                safetyNumber = crypto.safetyNumber(localPublicKey: publicKey, remotePublicKey: contact.publicKey)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func sendText() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard !recipientId.isEmpty else {
            errorMessage = "Enter the recipient user id first."
            return
        }
        draft = ""
        await publish(payloadType: .text, plaintext: TextPayload(textContent: text).serialized(), preview: text, attachment: nil)
    }

    func sendAttachment(_ attachment: OutboundAttachment) async {
        guard !recipientId.isEmpty else {
            errorMessage = "Enter the recipient user id first."
            return
        }
        isSending = true
        defer { isSending = false }
        do {
            let recipientKey = try await fetchRecipientKey()
            let payload = try await attachments.sealAndUpload(
                attachment,
                senderSecretKey: secretKey,
                recipientPublicKey: recipientKey,
                token: token
            )
            await publish(
                payloadType: .attachment,
                plaintext: payload.serialized(),
                preview: attachment.fileName,
                attachment: (
                    name: attachment.fileName,
                    mime: attachment.mimeType,
                    size: Int64(attachment.fileBytes.count),
                    bytes: attachment.fileBytes,
                    thumbnail: attachment.thumbnailBytes
                )
            )
        } catch {
            errorMessage = explain(error)
        }
    }

    func ingest(topic: String, packet: Data) async {
        if topic == MQTTTopics.ack(userId: userId) {
            guard let messageId = String(data: packet, encoding: .utf8) else { return }
            try? database.updateDeliveryStatus(messageId: messageId, status: "delivered")
            reload()
            return
        }
        guard topic == MQTTTopics.incoming(userId: userId) else { return }
        await receive(packet)
    }

    func markContactVerified() {
        guard !recipientId.isEmpty, let contact = try? database.contact(userId: recipientId) else { return }
        try? database.upsertContact(StoredContact(userId: contact.userId, publicKey: contact.publicKey, safetyVerified: true))
        reload()
    }

    private func publish(
        payloadType: PayloadType,
        plaintext: Data,
        preview: String,
        attachment: (name: String, mime: String, size: Int64, bytes: Data, thumbnail: Data?)?
    ) async {
        guard !recipientId.isEmpty else {
            errorMessage = "Enter the recipient user id first."
            return
        }
        isSending = true
        defer { isSending = false }
        let messageId = UUID().uuidString
        let timestamp = Int64(Date().timeIntervalSince1970 * 1000)
        do {
            let recipientKey = try await fetchRecipientKey()
            let envelope: MessageEnvelope
            if payloadType == .text {
                let text = try TextPayload.parse(plaintext).textContent
                envelope = try crypto.sealText(
                    text,
                    messageId: messageId,
                    senderId: userId,
                    recipientId: recipientId,
                    timestamp: timestamp,
                    senderSecretKey: secretKey,
                    recipientPublicKey: recipientKey
                )
            } else {
                let payload = try AttachmentPayload.parse(plaintext)
                envelope = try crypto.sealAttachmentPayload(
                    payload,
                    messageId: messageId,
                    senderId: userId,
                    recipientId: recipientId,
                    timestamp: timestamp,
                    senderSecretKey: secretKey,
                    recipientPublicKey: recipientKey
                )
            }
            try database.upsertMessage(
                StoredMessage(
                    messageId: messageId,
                    conversationId: ConversationID.make(userId, recipientId),
                    senderId: userId,
                    recipientId: recipientId,
                    timestampMs: timestamp,
                    payloadType: payloadType.rawValue,
                    body: payloadType == .text ? preview : nil,
                    attachmentName: attachment?.name,
                    attachmentMime: attachment?.mime,
                    attachmentSize: attachment?.size,
                    attachmentBytes: attachment?.bytes,
                    thumbnailBytes: attachment?.thumbnail,
                    deliveryStatus: "pending"
                )
            )
            reload()
            try await mqtt.publish(topic: MQTTTopics.incoming(userId: recipientId), payload: envelope.serialized())
            try database.updateDeliveryStatus(messageId: messageId, status: "sent")
            reload()
        } catch {
            try? database.updateDeliveryStatus(messageId: messageId, status: "failed")
            reload()
            errorMessage = explain(error)
        }
    }

    private func receive(_ packet: Data) async {
        do {
            let peeked = try MessageEnvelope.parse(packet)
            guard peeked.recipientId == userId else { return }
            if try database.messageExists(messageId: peeked.messageId) { return }
            let senderKey = try await directory.lookupUser(peeked.senderId, token: token).publicKey
            try database.upsertContact(StoredContact(userId: peeked.senderId, publicKey: senderKey, safetyVerified: false))
            let opened = try crypto.openEnvelope(
                packet: packet,
                senderPublicKey: senderKey,
                recipientSecretKey: secretKey
            )
            var body: String?
            var name: String?
            var mime: String?
            var size: Int64?
            var bytes: Data?
            var thumbnail: Data?
            var status = "delivered"
            if opened.envelope.payloadType == .text {
                body = try TextPayload.parse(opened.plaintext).textContent
            } else if opened.envelope.payloadType == .attachment {
                let payload = try AttachmentPayload.parse(opened.plaintext)
                name = payload.fileName
                mime = payload.mimeType
                size = Int64(payload.fileSize)
                thumbnail = try? await attachments.decryptThumbnail(
                    payload,
                    senderPublicKey: senderKey,
                    recipientSecretKey: secretKey
                )
                do {
                    bytes = try await attachments.downloadDecrypted(
                        payload,
                        senderPublicKey: senderKey,
                        recipientSecretKey: secretKey,
                        token: token
                    )
                } catch {
                    status = "failed"
                    errorMessage = explain(error)
                }
            }
            try database.upsertMessage(
                StoredMessage(
                    messageId: opened.envelope.messageId,
                    conversationId: ConversationID.make(userId, opened.envelope.senderId),
                    senderId: opened.envelope.senderId,
                    recipientId: userId,
                    timestampMs: opened.envelope.timestamp,
                    payloadType: opened.envelope.payloadType.rawValue,
                    body: body,
                    attachmentName: name,
                    attachmentMime: mime,
                    attachmentSize: size,
                    attachmentBytes: bytes,
                    thumbnailBytes: thumbnail,
                    deliveryStatus: status
                )
            )
            let ack = Data(opened.envelope.messageId.utf8)
            try? await mqtt.publish(topic: MQTTTopics.ack(userId: opened.envelope.senderId), payload: ack)
            reload()
        } catch {
            errorMessage = explain(error)
        }
    }

    private func fetchRecipientKey() async throws -> Data {
        try await resolveRecipient(recipientId).publicKey
    }

    private func resolveRecipient(_ identifier: String) async throws -> DirectoryUser {
        let user = try await directory.lookupUser(identifier, token: token)
        recipientId = user.userId
        try database.upsertContact(
            StoredContact(userId: user.userId, publicKey: user.publicKey, safetyVerified: false)
        )
        return user
    }

    private func display(_ row: StoredMessage) -> ChatItem {
        let kind: ChatItem.Kind
        if row.payloadType == PayloadType.attachment.rawValue {
            kind = .attachment(
                name: row.attachmentName ?? "Attachment",
                mime: row.attachmentMime ?? "application/octet-stream",
                image: row.attachmentBytes ?? row.thumbnailBytes
            )
        } else {
            kind = .text(row.body ?? "")
        }
        return ChatItem(
            id: row.messageId,
            isOutgoing: row.senderId == userId,
            timestamp: Date(timeIntervalSince1970: Double(row.timestampMs) / 1000),
            kind: kind,
            status: row.deliveryStatus
        )
    }

    private func explain(_ error: Error) -> String {
        switch error {
        case CryptoError.integrityCheckFailed:
            return "A message failed its SHA-256 integrity check and was discarded."
        case CryptoError.decryptionFailed:
            return "A message could not be decrypted."
        case let DirectoryError.status(code, body):
            return "Server responded \(code). \(body)"
        default:
            return error.localizedDescription
        }
    }
}
