import Foundation

public enum PayloadType: Int, Sendable, Equatable {
    case unspecified = 0
    case text = 1
    case attachment = 2
    case historyRequest = 3
    case historyRecord = 4
}

public struct MessageEnvelope: Equatable, Sendable {
    public var messageId: String
    public var senderId: String
    public var recipientId: String
    public var timestamp: Int64
    public var payloadType: PayloadType
    public var payloadBytes: Data
    public var nonce: Data
    public var hashSignature: Data

    public init(
        messageId: String,
        senderId: String,
        recipientId: String,
        timestamp: Int64,
        payloadType: PayloadType,
        payloadBytes: Data,
        nonce: Data,
        hashSignature: Data
    ) {
        self.messageId = messageId
        self.senderId = senderId
        self.recipientId = recipientId
        self.timestamp = timestamp
        self.payloadType = payloadType
        self.payloadBytes = payloadBytes
        self.nonce = nonce
        self.hashSignature = hashSignature
    }

    public func serialized() -> Data {
        var sink = ProtoSink()
        sink.writeString(1, messageId)
        sink.writeString(2, senderId)
        sink.writeString(3, recipientId)
        sink.writeInt64(4, timestamp)
        if payloadType != .unspecified {
            sink.writeVarintField(5, UInt64(payloadType.rawValue))
        }
        sink.writeBytes(6, payloadBytes)
        sink.writeBytes(7, nonce)
        sink.writeBytes(8, hashSignature)
        return sink.data
    }

    public static func parse(_ data: Data) throws -> MessageEnvelope {
        try ProtoLimits.check(data)
        var reader = ProtoReader(data: data)
        var messageId = ""
        var senderId = ""
        var recipientId = ""
        var timestamp: Int64 = 0
        var payloadType = PayloadType.unspecified
        var payloadBytes = Data()
        var nonce = Data()
        var hashSignature = Data()

        while !reader.isAtEnd {
            let key = try reader.readVarint()
            let field = Int(key >> 3)
            let wire = Int(key & 0x7)
            guard field > 0 else { throw ProtobufError.invalidField }
            switch (field, wire) {
            case (1, 2): messageId = try reader.readString()
            case (2, 2): senderId = try reader.readString()
            case (3, 2): recipientId = try reader.readString()
            case (4, 0): timestamp = Int64(bitPattern: try reader.readVarint())
            case (5, 0):
                let raw = try reader.readVarint()
                guard raw <= UInt64(Int.max), let parsed = PayloadType(rawValue: Int(raw)) else {
                    throw ProtobufError.invalidPayloadType
                }
                payloadType = parsed
            case (6, 2): payloadBytes = try reader.readLengthDelimited()
            case (7, 2): nonce = try reader.readLengthDelimited()
            case (8, 2): hashSignature = try reader.readLengthDelimited()
            default: try reader.skip(wireType: wire)
            }
        }

        return MessageEnvelope(
            messageId: messageId,
            senderId: senderId,
            recipientId: recipientId,
            timestamp: timestamp,
            payloadType: payloadType,
            payloadBytes: payloadBytes,
            nonce: nonce,
            hashSignature: hashSignature
        )
    }
}

public struct TextPayload: Equatable, Sendable {
    public var textContent: String

    public init(textContent: String) {
        self.textContent = textContent
    }

    public func serialized() -> Data {
        var sink = ProtoSink()
        sink.writeString(1, textContent)
        return sink.data
    }

    public static func parse(_ data: Data) throws -> TextPayload {
        try ProtoLimits.check(data)
        var reader = ProtoReader(data: data)
        var textContent = ""
        while !reader.isAtEnd {
            let key = try reader.readVarint()
            let field = Int(key >> 3)
            let wire = Int(key & 0x7)
            guard field > 0 else { throw ProtobufError.invalidField }
            if field == 1 && wire == 2 {
                textContent = try reader.readString()
            } else {
                try reader.skip(wireType: wire)
            }
        }
        return TextPayload(textContent: textContent)
    }
}

public struct AttachmentPayload: Equatable, Sendable {
    public var s3FileUrl: String
    public var encryptedS3Key: Data
    public var s3KeyNonce: Data
    public var mimeType: String
    public var fileSize: UInt64
    public var fileName: String
    public var encryptedThumbnailData: Data

    public init(
        s3FileUrl: String,
        encryptedS3Key: Data,
        s3KeyNonce: Data,
        mimeType: String,
        fileSize: UInt64,
        fileName: String,
        encryptedThumbnailData: Data
    ) {
        self.s3FileUrl = s3FileUrl
        self.encryptedS3Key = encryptedS3Key
        self.s3KeyNonce = s3KeyNonce
        self.mimeType = mimeType
        self.fileSize = fileSize
        self.fileName = fileName
        self.encryptedThumbnailData = encryptedThumbnailData
    }

    public func serialized() -> Data {
        var sink = ProtoSink()
        sink.writeString(1, s3FileUrl)
        sink.writeBytes(2, encryptedS3Key)
        sink.writeBytes(3, s3KeyNonce)
        sink.writeString(4, mimeType)
        sink.writeUInt64(5, fileSize)
        sink.writeString(6, fileName)
        sink.writeBytes(7, encryptedThumbnailData)
        return sink.data
    }

    public static func parse(_ data: Data) throws -> AttachmentPayload {
        try ProtoLimits.check(data)
        var reader = ProtoReader(data: data)
        var s3FileUrl = ""
        var encryptedS3Key = Data()
        var s3KeyNonce = Data()
        var mimeType = ""
        var fileSize: UInt64 = 0
        var fileName = ""
        var encryptedThumbnailData = Data()

        while !reader.isAtEnd {
            let key = try reader.readVarint()
            let field = Int(key >> 3)
            let wire = Int(key & 0x7)
            guard field > 0 else { throw ProtobufError.invalidField }
            switch (field, wire) {
            case (1, 2): s3FileUrl = try reader.readString()
            case (2, 2): encryptedS3Key = try reader.readLengthDelimited()
            case (3, 2): s3KeyNonce = try reader.readLengthDelimited()
            case (4, 2): mimeType = try reader.readString()
            case (5, 0): fileSize = try reader.readVarint()
            case (6, 2): fileName = try reader.readString()
            case (7, 2): encryptedThumbnailData = try reader.readLengthDelimited()
            default: try reader.skip(wireType: wire)
            }
        }

        return AttachmentPayload(
            s3FileUrl: s3FileUrl,
            encryptedS3Key: encryptedS3Key,
            s3KeyNonce: s3KeyNonce,
            mimeType: mimeType,
            fileSize: fileSize,
            fileName: fileName,
            encryptedThumbnailData: encryptedThumbnailData
        )
    }

    /// Object key inside `s3://bucket/ciphertext/<uuid>`.
    public var objectKey: String? {
        guard let url = URL(string: s3FileUrl), url.scheme == "s3" else { return nil }
        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard path.hasPrefix("ciphertext/") else { return nil }
        return path
    }
}

public struct HistoryRecord: Equatable, Sendable {
    public var messageId: String
    public var senderId: String
    public var recipientId: String
    public var timestampMs: Int64
    public var payloadType: Int
    public var body: String
    public var attachmentName: String
    public var attachmentMime: String

    public init(
        messageId: String,
        senderId: String,
        recipientId: String,
        timestampMs: Int64,
        payloadType: Int,
        body: String,
        attachmentName: String,
        attachmentMime: String
    ) {
        self.messageId = messageId
        self.senderId = senderId
        self.recipientId = recipientId
        self.timestampMs = timestampMs
        self.payloadType = payloadType
        self.body = body
        self.attachmentName = attachmentName
        self.attachmentMime = attachmentMime
    }

    public func serialized() -> Data {
        var sink = ProtoSink()
        sink.writeString(1, messageId)
        sink.writeString(2, senderId)
        sink.writeString(3, recipientId)
        sink.writeInt64(4, timestampMs)
        sink.writeString(5, body)
        sink.writeString(6, attachmentName)
        sink.writeString(7, attachmentMime)
        if payloadType != 0 {
            sink.writeVarintField(8, UInt64(payloadType))
        }
        return sink.data
    }

    public static func parse(_ data: Data) throws -> HistoryRecord {
        try ProtoLimits.check(data)
        var reader = ProtoReader(data: data)
        var messageId = ""
        var senderId = ""
        var recipientId = ""
        var timestampMs: Int64 = 0
        var body = ""
        var attachmentName = ""
        var attachmentMime = ""
        var payloadType = 0
        while !reader.isAtEnd {
            let key = try reader.readVarint()
            let field = Int(key >> 3)
            let wire = Int(key & 0x7)
            guard field > 0 else { throw ProtobufError.invalidField }
            switch (field, wire) {
            case (1, 2): messageId = try reader.readString()
            case (2, 2): senderId = try reader.readString()
            case (3, 2): recipientId = try reader.readString()
            case (4, 0): timestampMs = Int64(bitPattern: try reader.readVarint())
            case (5, 2): body = try reader.readString()
            case (6, 2): attachmentName = try reader.readString()
            case (7, 2): attachmentMime = try reader.readString()
            case (8, 0): payloadType = Int(try reader.readVarint())
            default: try reader.skip(wireType: wire)
            }
        }
        return HistoryRecord(
            messageId: messageId,
            senderId: senderId,
            recipientId: recipientId,
            timestampMs: timestampMs,
            payloadType: payloadType,
            body: body,
            attachmentName: attachmentName,
            attachmentMime: attachmentMime
        )
    }
}

public enum ProtobufError: Error, Equatable, Sendable {
    case truncated
    case invalidWireType
    case invalidUTF8
    case invalidField
    case invalidPayloadType
    case fieldOverflow
    case messageTooLarge
}

enum ProtoLimits {
    static let maxMessageBytes = 2_000_000

    static func check(_ data: Data) throws {
        if data.count > maxMessageBytes {
            throw ProtobufError.messageTooLarge
        }
    }
}

struct ProtoSink {
    var data = Data()

    mutating func writeString(_ field: Int, _ value: String) {
        guard !value.isEmpty, let utf8 = value.data(using: .utf8) else { return }
        writeBytes(field, utf8)
    }

    mutating func writeBytes(_ field: Int, _ value: Data) {
        guard !value.isEmpty else { return }
        writeTag(field: field, wire: 2)
        writeVarint(UInt64(value.count))
        data.append(value)
    }

    mutating func writeInt64(_ field: Int, _ value: Int64) {
        guard value != 0 else { return }
        writeVarintField(field, UInt64(bitPattern: value))
    }

    mutating func writeUInt64(_ field: Int, _ value: UInt64) {
        guard value != 0 else { return }
        writeVarintField(field, value)
    }

    mutating func writeVarintField(_ field: Int, _ value: UInt64) {
        writeTag(field: field, wire: 0)
        writeVarint(value)
    }

    private mutating func writeTag(field: Int, wire: Int) {
        writeVarint(UInt64(field << 3 | wire))
    }

    private mutating func writeVarint(_ value: UInt64) {
        var remaining = value
        repeat {
            var byte = UInt8(remaining & 0x7F)
            remaining >>= 7
            if remaining != 0 { byte |= 0x80 }
            data.append(byte)
        } while remaining != 0
    }
}

struct ProtoReader {
    let data: Data
    var index = 0

    var isAtEnd: Bool { index >= data.count }
    var remaining: Int { data.count - index }

    mutating func readVarint() throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        for _ in 0..<10 {
            let byte = try readByte()
            let payload = UInt64(byte & 0x7F)
            if shift == 63 && payload > 1 { throw ProtobufError.fieldOverflow }
            result |= payload << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
        }
        throw ProtobufError.fieldOverflow
    }

    mutating func readString() throws -> String {
        let bytes = try readLengthDelimited()
        guard let string = String(data: bytes, encoding: .utf8) else {
            throw ProtobufError.invalidUTF8
        }
        return string
    }

    mutating func readLengthDelimited() throws -> Data {
        let count = try readLength()
        return try readData(count)
    }

    mutating func skip(wireType: Int) throws {
        switch wireType {
        case 0:
            _ = try readVarint()
        case 1:
            _ = try readData(8)
        case 2:
            let count = try readLength()
            _ = try readData(count)
        case 5:
            _ = try readData(4)
        default:
            throw ProtobufError.invalidWireType
        }
    }

    private mutating func readLength() throws -> Int {
        let value = try readVarint()
        guard value <= UInt64(remaining), value <= UInt64(ProtoLimits.maxMessageBytes) else {
            throw ProtobufError.truncated
        }
        return Int(value)
    }

    private mutating func readByte() throws -> UInt8 {
        guard index < data.count else { throw ProtobufError.truncated }
        let byte = data[index]
        index += 1
        return byte
    }

    private mutating func readData(_ count: Int) throws -> Data {
        guard count <= remaining else { throw ProtobufError.truncated }
        let start = index
        index += count
        return data.subdata(in: start..<index)
    }
}
