import SwiftUI

struct SettingsView: View {
    @ObservedObject var appearance: AppearanceSettings
    var safetyNumber: String
    var contactVerified: Bool
    var onVerify: () -> Void
    var onLogout: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            Form {
                Section("Appearance") {
                    Picker("Theme", selection: $appearance.preference) {
                        ForEach(AppearancePreference.allCases) { preference in
                            Text(preference.title).tag(preference)
                        }
                    }
                    .pickerStyle(.inline)
                }
                Section("Identity check") {
                    Text("Compare this safety number with your contact in person. It is a SHA-256 fingerprint of both Curve25519 public keys.")
                        .font(.footnote)
                        .foregroundStyle(Color.secondary)
                    Text(safetyNumber.isEmpty ? "Open a conversation to generate a safety number." : safetyNumber)
                        .font(.system(.body, design: .monospaced))
                    if contactVerified {
                        Label("Marked as verified on this device", systemImage: "checkmark.seal")
                    } else {
                        Button("Mark contact as verified", action: onVerify)
                            .disabled(safetyNumber.isEmpty)
                    }
                }
                Section {
                    Button("Log out", role: .destructive, action: onLogout)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

struct LoginView: View {
    @ObservedObject var model: KeyManagementViewModel

    var body: some View {
        NavigationView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Image(systemName: "lock.fill")
                        .font(.title)
                        .foregroundStyle(Color.accentColor)
                    Text("Secure Messaging")
                        .font(.largeTitle.bold())
                        .foregroundStyle(Color.primary)
                    Text("Keys are created on this device. The server stores public keys only, never message contents.")
                        .foregroundStyle(Color.secondary)
                }
                TextField("Username", text: $model.username)
                    .textInputAutocapitalization(.never)
                    .disableAutocorrection(true)
                    .textFieldStyle(.roundedBorder)
                SecureField("Password", text: $model.password)
                    .textFieldStyle(.roundedBorder)
                if let error = model.errorMessage {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(Color.red)
                }
                Button {
                    Task { await model.register() }
                } label: {
                    Text("Create account")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isBusy)
                Button {
                    Task { await model.login() }
                } label: {
                    Text("Log in")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(model.isBusy)
                Spacer()
            }
            .padding(24)
            .background(Color(uiColor: .systemBackground))
            .navigationBarHidden(true)
        }
        .navigationViewStyle(.stack)
    }
}
