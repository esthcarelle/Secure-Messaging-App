import Foundation
import SQLCipher

public struct StoredMessage: Equatable, Sendable {
    public var messageId: String
    public var conversationId: String
    public var senderId: String
    public var recipientId: String
    public var timestampMs: Int64
    public var payloadType: Int
    public var body: String?
    public var attachmentName: String?
    public var attachmentMime: String?
    public var attachmentSize: Int64?
    public var attachmentBytes: Data?
    public var thumbnailBytes: Data?
    public var deliveryStatus: String

    public init(
        messageId: String,
        conversationId: String,
        senderId: String,
        recipientId: String,
        timestampMs: Int64,
        payloadType: Int,
        body: String?,
        attachmentName: String?,
        attachmentMime: String?,
        attachmentSize: Int64?,
        attachmentBytes: Data?,
        thumbnailBytes: Data?,
        deliveryStatus: String
    ) {
        self.messageId = messageId
        self.conversationId = conversationId
        self.senderId = senderId
        self.recipientId = recipientId
        self.timestampMs = timestampMs
        self.payloadType = payloadType
        self.body = body
        self.attachmentName = attachmentName
        self.attachmentMime = attachmentMime
        self.attachmentSize = attachmentSize
        self.attachmentBytes = attachmentBytes
        self.thumbnailBytes = thumbnailBytes
        self.deliveryStatus = deliveryStatus
    }
}

public struct StoredContact: Equatable, Sendable {
    public var userId: String
    public var publicKey: Data
    public var safetyVerified: Bool

    public init(userId: String, publicKey: Data, safetyVerified: Bool) {
        self.userId = userId
        self.publicKey = publicKey
        self.safetyVerified = safetyVerified
    }
}

public enum DatabaseError: Error, Equatable {
    case invalidKeyLength
    case sqlCipherUnavailable
    case openFailed(String)
    case sqlite(String)
    case notFound
}

/// SQLCipher database. The 256-bit raw key is supplied by the caller (Keychain on iOS).
/// Page encryption is AES-256 via SQLCipher's raw-key pragma, which is the SQL form of sqlite3_key.
public final class DatabaseService: @unchecked Sendable {
    private var db: OpaquePointer?
    private let lock = NSLock()
    private let destructor = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public init(path: String, key: Data) throws {
        guard key.count == 32 else { throw DatabaseError.invalidKeyLength }
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(path, &handle, flags, nil)
        guard rc == SQLITE_OK, let handle else {
            let message = handle.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            if let handle { sqlite3_close(handle) }
            throw DatabaseError.openFailed(message)
        }
        db = handle
        do {
            try applyKey(key)
            try migrate()
        } catch {
            sqlite3_close(handle)
            db = nil
            throw error
        }
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    public func close() {
        lock.lock()
        defer { lock.unlock() }
        if let db {
            sqlite3_close(db)
            self.db = nil
        }
    }

    public func upsertMessage(_ message: StoredMessage) throws {
        try withDB { db in
            let sql = """
            INSERT INTO messages (
                message_id, conversation_id, sender_id, recipient_id, timestamp_ms,
                payload_type, body, attachment_name, attachment_mime, attachment_size,
                attachment_bytes, thumbnail_bytes, delivery_status
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(message_id) DO UPDATE SET
                delivery_status = excluded.delivery_status,
                attachment_bytes = COALESCE(excluded.attachment_bytes, messages.attachment_bytes),
                thumbnail_bytes = COALESCE(excluded.thumbnail_bytes, messages.thumbnail_bytes)
            """
            let stmt = try prepare(db, sql)
            defer { sqlite3_finalize(stmt) }
            try bind(stmt, 1, message.messageId)
            try bind(stmt, 2, message.conversationId)
            try bind(stmt, 3, message.senderId)
            try bind(stmt, 4, message.recipientId)
            sqlite3_bind_int64(stmt, 5, message.timestampMs)
            sqlite3_bind_int64(stmt, 6, Int64(message.payloadType))
            try bind(stmt, 7, message.body)
            try bind(stmt, 8, message.attachmentName)
            try bind(stmt, 9, message.attachmentMime)
            if let size = message.attachmentSize {
                sqlite3_bind_int64(stmt, 10, size)
            } else {
                sqlite3_bind_null(stmt, 10)
            }
            try bind(stmt, 11, message.attachmentBytes)
            try bind(stmt, 12, message.thumbnailBytes)
            try bind(stmt, 13, message.deliveryStatus)
            try stepDone(stmt)
        }
    }

    public func messages(conversationId: String) throws -> [StoredMessage] {
        try withDB { db in
            let sql = """
            SELECT message_id, conversation_id, sender_id, recipient_id, timestamp_ms,
                   payload_type, body, attachment_name, attachment_mime, attachment_size,
                   attachment_bytes, thumbnail_bytes, delivery_status
            FROM messages
            WHERE conversation_id = ?
            ORDER BY timestamp_ms ASC
            """
            let stmt = try prepare(db, sql)
            defer { sqlite3_finalize(stmt) }
            try bind(stmt, 1, conversationId)
            var rows: [StoredMessage] = []
            while true {
                let rc = sqlite3_step(stmt)
                if rc == SQLITE_DONE { break }
                guard rc == SQLITE_ROW else { throw DatabaseError.sqlite(errorMessage(db)) }
                rows.append(readMessage(stmt))
            }
            return rows
        }
    }

    public func messageExists(messageId: String) throws -> Bool {
        try withDB { db in
            let stmt = try prepare(db, "SELECT 1 FROM messages WHERE message_id = ?")
            defer { sqlite3_finalize(stmt) }
            try bind(stmt, 1, messageId)
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_ROW { return true }
            if rc == SQLITE_DONE { return false }
            throw DatabaseError.sqlite(errorMessage(db))
        }
    }

    public func updateDeliveryStatus(messageId: String, status: String) throws {
        try withDB { db in
            let stmt = try prepare(db, "UPDATE messages SET delivery_status = ? WHERE message_id = ?")
            defer { sqlite3_finalize(stmt) }
            try bind(stmt, 1, status)
            try bind(stmt, 2, messageId)
            try stepDone(stmt)
        }
    }

    public func upsertContact(_ contact: StoredContact) throws {
        try withDB { db in
            let sql = """
            INSERT INTO contacts (user_id, public_key, safety_verified)
            VALUES (?, ?, ?)
            ON CONFLICT(user_id) DO UPDATE SET
                safety_verified = CASE
                    WHEN contacts.public_key = excluded.public_key
                    THEN MAX(contacts.safety_verified, excluded.safety_verified)
                    ELSE excluded.safety_verified
                END,
                public_key = excluded.public_key
            """
            let stmt = try prepare(db, sql)
            defer { sqlite3_finalize(stmt) }
            try bind(stmt, 1, contact.userId)
            try bind(stmt, 2, contact.publicKey)
            sqlite3_bind_int64(stmt, 3, contact.safetyVerified ? 1 : 0)
            try stepDone(stmt)
        }
    }

    public func contact(userId: String) throws -> StoredContact? {
        try withDB { db in
            let stmt = try prepare(db, "SELECT user_id, public_key, safety_verified FROM contacts WHERE user_id = ?")
            defer { sqlite3_finalize(stmt) }
            try bind(stmt, 1, userId)
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { return nil }
            guard rc == SQLITE_ROW else { throw DatabaseError.sqlite(errorMessage(db)) }
            guard let id = columnText(stmt, 0), let key = columnBlob(stmt, 1) else { return nil }
            return StoredContact(userId: id, publicKey: key, safetyVerified: sqlite3_column_int64(stmt, 2) != 0)
        }
    }

    // MARK: - SQLCipher

    private func applyKey(_ key: Data) throws {
        let hex = key.map { String(format: "%02X", $0) }.joined()
        try exec("PRAGMA key = \"x'\(hex)'\";")
        guard let version = try queryText("PRAGMA cipher_version;"), !version.isEmpty else {
            throw DatabaseError.sqlCipherUnavailable
        }
        // Touch the schema so a wrong key fails here instead of on the next query.
        _ = try queryText("SELECT count(*) FROM sqlite_master;")
    }

    private func migrate() throws {
        try exec(
            """
            CREATE TABLE IF NOT EXISTS messages (
                message_id TEXT PRIMARY KEY,
                conversation_id TEXT NOT NULL,
                sender_id TEXT NOT NULL,
                recipient_id TEXT NOT NULL,
                timestamp_ms INTEGER NOT NULL,
                payload_type INTEGER NOT NULL,
                body TEXT,
                attachment_name TEXT,
                attachment_mime TEXT,
                attachment_size INTEGER,
                attachment_bytes BLOB,
                thumbnail_bytes BLOB,
                delivery_status TEXT NOT NULL
            );
            CREATE INDEX IF NOT EXISTS messages_conversation
                ON messages(conversation_id, timestamp_ms);
            CREATE TABLE IF NOT EXISTS contacts (
                user_id TEXT PRIMARY KEY,
                public_key BLOB NOT NULL,
                safety_verified INTEGER NOT NULL DEFAULT 0
            );
            """
        )
    }

    private func withDB<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        guard let db else { throw DatabaseError.openFailed("database is closed") }
        return try body(db)
    }

    private func exec(_ sql: String) throws {
        guard let db else { throw DatabaseError.openFailed("database is closed") }
        var error: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &error)
        if rc != SQLITE_OK {
            let message = error.map { String(cString: $0) } ?? errorMessage(db)
            sqlite3_free(error)
            throw DatabaseError.sqlite(message)
        }
    }

    private func queryText(_ sql: String) throws -> String? {
        guard let db else { throw DatabaseError.openFailed("database is closed") }
        let stmt = try prepare(db, sql)
        defer { sqlite3_finalize(stmt) }
        let rc = sqlite3_step(stmt)
        if rc == SQLITE_ROW { return columnText(stmt, 0) }
        if rc == SQLITE_DONE { return nil }
        throw DatabaseError.sqlite(errorMessage(db))
    }

    private func prepare(_ db: OpaquePointer, _ sql: String) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw DatabaseError.sqlite(errorMessage(db))
        }
        return stmt
    }

    private func stepDone(_ stmt: OpaquePointer) throws {
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE else {
            throw DatabaseError.sqlite(db.map(errorMessage) ?? "step failed")
        }
    }

    private func bind(_ stmt: OpaquePointer, _ index: Int32, _ text: String?) throws {
        if let text {
            let rc = text.withCString { sqlite3_bind_text(stmt, index, $0, -1, destructor) }
            guard rc == SQLITE_OK else { throw DatabaseError.sqlite("bind text") }
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    private func bind(_ stmt: OpaquePointer, _ index: Int32, _ blob: Data?) throws {
        if let blob {
            let rc = blob.withUnsafeBytes { raw -> Int32 in
                sqlite3_bind_blob(stmt, index, raw.baseAddress, Int32(blob.count), destructor)
            }
            guard rc == SQLITE_OK else { throw DatabaseError.sqlite("bind blob") }
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    private func readMessage(_ stmt: OpaquePointer) -> StoredMessage {
        StoredMessage(
            messageId: columnText(stmt, 0) ?? "",
            conversationId: columnText(stmt, 1) ?? "",
            senderId: columnText(stmt, 2) ?? "",
            recipientId: columnText(stmt, 3) ?? "",
            timestampMs: sqlite3_column_int64(stmt, 4),
            payloadType: Int(sqlite3_column_int64(stmt, 5)),
            body: columnText(stmt, 6),
            attachmentName: columnText(stmt, 7),
            attachmentMime: columnText(stmt, 8),
            attachmentSize: sqlite3_column_type(stmt, 9) == SQLITE_NULL ? nil : sqlite3_column_int64(stmt, 9),
            attachmentBytes: columnBlob(stmt, 10),
            thumbnailBytes: columnBlob(stmt, 11),
            deliveryStatus: columnText(stmt, 12) ?? "pending"
        )
    }

    private func columnText(_ stmt: OpaquePointer, _ index: Int32) -> String? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL, let cString = sqlite3_column_text(stmt, index) else {
            return nil
        }
        return String(cString: cString)
    }

    private func columnBlob(_ stmt: OpaquePointer, _ index: Int32) -> Data? {
        guard sqlite3_column_type(stmt, index) == SQLITE_BLOB else { return nil }
        let count = Int(sqlite3_column_bytes(stmt, index))
        guard count > 0, let pointer = sqlite3_column_blob(stmt, index) else { return nil }
        return Data(bytes: pointer, count: count)
    }

    private func errorMessage(_ db: OpaquePointer) -> String {
        String(cString: sqlite3_errmsg(db))
    }
}
