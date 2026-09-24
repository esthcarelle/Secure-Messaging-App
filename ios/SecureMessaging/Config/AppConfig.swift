import Foundation

enum AppConfig {
    static let apiBaseURL = URL(string: "https://api-production-1cfa4.up.railway.app")!
    static let mqttHost = "acela.proxy.rlwy.net"
    static let mqttPort: UInt16 = 52882
    static let mqttUsesTLS = false
}
