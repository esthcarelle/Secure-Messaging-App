import Foundation

enum AppConfig {
    static let apiBaseURL = URL(string: "http://127.0.0.1:8080")!
    static let mqttHost = "127.0.0.1"
    static let mqttPort: UInt16 = 1883
    static let mqttUsesTLS = false
}
