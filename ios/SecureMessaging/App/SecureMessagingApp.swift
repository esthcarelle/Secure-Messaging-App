import SwiftUI

@main
struct SecureMessagingApp: App {
    @StateObject private var appearance = AppearanceSettings()
    @StateObject private var session = KeyManagementViewModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appearance)
                .environmentObject(session)
                .preferredColorScheme(appearance.preference.colorScheme)
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var session: KeyManagementViewModel
    @EnvironmentObject private var appearance: AppearanceSettings

    var body: some View {
        Group {
            if let chat = session.chat {
                ChatView(
                    model: chat,
                    attachments: session.attachments,
                    brokerWarning: session.brokerWarning,
                    onLogout: { session.logout() }
                )
            } else {
                LoginView(model: session)
            }
        }
        .preferredColorScheme(appearance.preference.colorScheme)
    }
}
