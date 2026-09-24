import SwiftUI

enum AppearancePreference: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "System Default"
        case .light: return "Always Light"
        case .dark: return "Always Dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

@MainActor
final class AppearanceSettings: ObservableObject {
    @Published var preference: AppearancePreference {
        didSet {
            UserDefaults.standard.set(preference.rawValue, forKey: Self.storageKey)
        }
    }

    private static let storageKey = "appearance.preference"

    init() {
        let stored = UserDefaults.standard.string(forKey: Self.storageKey) ?? AppearancePreference.system.rawValue
        preference = AppearancePreference(rawValue: stored) ?? .system
    }
}
