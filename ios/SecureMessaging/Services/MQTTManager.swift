import Foundation
import CocoaMQTT
import SecureMessagingKit

enum MQTTError: Error {
    case notConnected
    case rejected
    case queueFull
}

/// QoS 1 client for `users/{userId}/messages` and `users/{userId}/ack`.
/// `cleanSession` is false so the broker can queue offline deliveries.
final class MQTTManager {
    var onMessage: ((String, Data) -> Void)?

    private var client: CocoaMQTT?
    private var connectWaiter: CheckedContinuation<Void, Error>?
    private var connectTimeout: Task<Void, Never>?
    private var publishWaiters: [UInt16: CheckedContinuation<Void, Error>] = [:]
    private let lock = NSLock()
    private var userId = ""

    func connect(userId: String, token: String) async throws {
        self.userId = userId
        let mqtt = CocoaMQTT(clientID: userId, host: AppConfig.mqttHost, port: AppConfig.mqttPort)
        mqtt.username = userId
        mqtt.password = token
        mqtt.keepAlive = 60
        mqtt.cleanSession = false
        mqtt.autoReconnect = true
        mqtt.enableSSL = AppConfig.mqttUsesTLS
        mqtt.didConnectAck = { [weak self] _, ack in
            guard let self else { return }
            if ack == .accept {
                mqtt.subscribe(MQTTTopics.incoming(userId: userId), qos: .qos1)
                mqtt.subscribe(MQTTTopics.ack(userId: userId), qos: .qos1)
                self.finishConnect(.success(()))
            } else {
                self.finishConnect(.failure(MQTTError.rejected))
            }
        }
        mqtt.didPublishAck = { [weak self] _, id in
            self?.finishPublish(id: id)
        }
        mqtt.didReceiveMessage = { [weak self] _, message, _ in
            let data = Data(message.payload)
            self?.onMessage?(message.topic, data)
        }
        mqtt.didDisconnect = { [weak self] _, error in
            self?.finishConnect(.failure(error ?? MQTTError.notConnected))
        }
        client = mqtt
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let timeout = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 12_000_000_000)
                self?.finishConnect(.failure(MQTTError.notConnected))
            }
            lock.lock()
            connectWaiter = continuation
            connectTimeout?.cancel()
            connectTimeout = timeout
            lock.unlock()
            if !mqtt.connect(timeout: 10) {
                finishConnect(.failure(MQTTError.notConnected))
            }
        }
    }

    func publish(topic: String, payload: Data) async throws {
        guard let client else { throw MQTTError.notConnected }
        let message = CocoaMQTTMessage(topic: topic, payload: [UInt8](payload), qos: .qos1, retained: false)
        let identifier = client.publish(message)
        guard identifier > 0 else { throw MQTTError.queueFull }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            lock.lock()
            publishWaiters[UInt16(identifier)] = continuation
            lock.unlock()
        }
    }

    func disconnect() {
        client?.disconnect()
        client = nil
        finishConnect(.failure(MQTTError.notConnected))
    }

    private func finishConnect(_ result: Result<Void, Error>) {
        lock.lock()
        let waiter = connectWaiter
        connectWaiter = nil
        let timeout = connectTimeout
        connectTimeout = nil
        lock.unlock()
        timeout?.cancel()
        waiter?.resume(with: result)
    }

    private func finishPublish(id: UInt16) {
        lock.lock()
        let waiter = publishWaiters.removeValue(forKey: id)
        lock.unlock()
        waiter?.resume()
    }
}
