import Foundation
import SecureMessagingKit

@MainActor
final class KeyManagementViewModel: ObservableObject {
    @Published var username = ""
    @Published var password = ""
    @Published var userId: String?
    @Published var chat: ChatViewModel?
    @Published var isBusy = false
    @Published var errorMessage: String?
    @Published var brokerWarning: String?

    let attachments = AttachmentViewModel()

    private let crypto = CryptoService()
    private let keychain = KeychainStore()
    private let directory: DirectoryClient
    private let mqtt = MQTTManager()
    private let attachmentManager: AttachmentManager
    private var database: DatabaseService?
    private var secretKey: Data?
    private var publicKey: Data?
    private var token: String?

    init() {
        let client = DirectoryClient(baseURL: AppConfig.apiBaseURL)
        directory = client
        attachmentManager = AttachmentManager(crypto: crypto, directory: client)
        Task { await restore() }
    }

    func register() async {
        await authenticate(isRegistration: true)
    }

    func login() async {
        await authenticate(isRegistration: false)
    }

    func logout() {
        mqtt.disconnect()
        try? keychain.delete(account: Account.token)
        token = nil
        userId = nil
        chat = nil
        password = ""
    }

    func restore() async {
        guard let storedUser = try? keychain.string(account: Account.userId),
              let storedName = try? keychain.string(account: Account.username),
              let storedToken = try? keychain.string(account: Account.token),
              let secret = try? keychain.data(account: Account.secret),
              let publicKey = try? keychain.data(account: Account.publicKey)
        else { return }
        username = storedName
        do {
            try await startSession(userId: storedUser, username: storedName, token: storedToken, secret: secret, publicKey: publicKey)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func authenticate(isRegistration: Bool) async {
        let trimmedName = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedName.count >= 3, password.count >= 8 else {
            errorMessage = "Use a username of at least 3 characters and a password of at least 8."
            return
        }
        isBusy = true
        defer { isBusy = false }
        errorMessage = nil
        do {
            if isRegistration {
                let identity = try crypto.generateIdentity()
                let session = try await directory.register(username: trimmedName, password: password, publicKey: identity.publicKey)
                clearLocalHistory()
                try persistIdentity(identity, session: session)
                try await startSession(
                    userId: session.userId,
                    username: session.username,
                    token: session.token,
                    secret: identity.secretKey,
                    publicKey: identity.publicKey
                )
            } else {
                let session = try await directory.login(username: trimmedName, password: password)
                if let secret = try keychain.data(account: Account.secret),
                   let storedPublic = try keychain.data(account: Account.publicKey),
                   let storedUser = try keychain.string(account: Account.userId),
                   storedUser == session.userId {
                    try keychain.setString(session.token, account: Account.token)
                    try await startSession(
                        userId: session.userId,
                        username: session.username,
                        token: session.token,
                        secret: secret,
                        publicKey: storedPublic
                    )
                } else {
                    let identity = try crypto.generateIdentity()
                    try await directory.uploadPublicKey(identity.publicKey, token: session.token)
                    clearLocalHistory()
                    try persistIdentity(identity, session: session)
                    try await startSession(
                        userId: session.userId,
                        username: session.username,
                        token: session.token,
                        secret: identity.secretKey,
                        publicKey: identity.publicKey
                    )
                }
            }
        } catch let DirectoryError.status(code, body) {
            errorMessage = "Server responded \(code). \(body)"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func persistIdentity(_ identity: IdentityKeyPair, session: AuthSession) throws {
        try keychain.set(identity.secretKey, account: Account.secret)
        try keychain.set(identity.publicKey, account: Account.publicKey)
        try keychain.setString(session.userId, account: Account.userId)
        try keychain.setString(session.username, account: Account.username)
        try keychain.setString(session.token, account: Account.token)
    }

    private func startSession(
        userId: String,
        username: String,
        token: String,
        secret: Data,
        publicKey: Data
    ) async throws {
        let database = try openDatabase()
        self.database = database
        self.userId = userId
        self.token = token
        self.secretKey = secret
        self.publicKey = publicKey
        let model = ChatViewModel(
            userId: userId,
            token: token,
            secretKey: secret,
            publicKey: publicKey,
            crypto: crypto,
            database: database,
            directory: directory,
            mqtt: mqtt,
            attachments: attachmentManager
        )
        chat = model
        await MessageNotifier.shared.requestAuthorization()
        mqtt.onMessage = { [weak self] topic, data in
            Task { @MainActor in
                await self?.chat?.ingest(topic: topic, packet: data)
            }
        }
        do {
            try await mqtt.connect(userId: userId, token: token)
            brokerWarning = nil
        } catch {
            brokerWarning = "Signed in. The MQTT broker is not reachable, so live delivery is paused."
        }
        self.username = username
    }

    private func clearLocalHistory() {
        database = nil
        if let base = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        ) {
            try? FileManager.default.removeItem(at: base.appendingPathComponent("SecureMessaging", isDirectory: true))
        }
    }

    private func openDatabase() throws -> DatabaseService {
        if let database { return database }
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let folder = base.appendingPathComponent("SecureMessaging", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let key = try keychain.databaseKey()
        return try DatabaseService(path: folder.appendingPathComponent("messages.db").path, key: key)
    }
}

private enum Account {
    static let secret = "identity.secret"
    static let publicKey = "identity.public"
    static let userId = "session.userId"
    static let username = "session.username"
    static let token = "session.token"
}
