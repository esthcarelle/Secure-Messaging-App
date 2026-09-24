import SwiftUI

struct ChatView: View {
    @ObservedObject var model: ChatViewModel
    @ObservedObject var attachments: AttachmentViewModel
    @EnvironmentObject private var appearance: AppearanceSettings
    var brokerWarning: String?
    var onLogout: () -> Void

    @State private var showsSettings = false

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                if let brokerWarning {
                    Text(brokerWarning)
                        .font(.footnote)
                        .foregroundStyle(Color.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Color(uiColor: .secondarySystemBackground))
                }
                recipientField
                messageList
            }
            .background(Color(uiColor: .systemBackground))
            .navigationTitle("Messages")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Label("Encrypted", systemImage: "lock.fill")
                        .font(.caption)
                        .foregroundStyle(Color.secondary)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        model.reload()
                        showsSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Settings")
                }
            }
            .safeAreaInset(edge: .bottom) { composer }
            .sheet(isPresented: $showsSettings) {
                SettingsView(
                    appearance: appearance,
                    safetyNumber: model.safetyNumber,
                    contactVerified: model.contactVerified,
                    onVerify: { model.markContactVerified() },
                    onLogout: {
                        showsSettings = false
                        onLogout()
                    }
                )
            }
            .sheet(isPresented: $attachments.isPresentingPicker) {
                ImagePicker { image in
                    Task { await attachments.send(image, through: model) }
                }
            }
            .alert("Message", isPresented: errorIsPresented) {
                Button("OK", role: .cancel) { model.errorMessage = nil }
            } message: {
                Text(model.errorMessage ?? "")
            }
        }
        .navigationViewStyle(.stack)
    }

    private var recipientField: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField("Username or user id", text: $model.recipientId)
                    .textInputAutocapitalization(.never)
                    .disableAutocorrection(true)
                    .font(.subheadline)
                Button("Open") {
                    Task { await model.openRecipient() }
                }
                .font(.subheadline.weight(.semibold))
                .disabled(model.isSending)
            }
            if !model.recipientStatus.isEmpty {
                Text(model.recipientStatus)
                    .font(.footnote)
                    .foregroundStyle(Color.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 10) {
                    if model.messages.isEmpty {
                        Text("Messages are encrypted on this device before they are sent.")
                            .font(.footnote)
                            .foregroundStyle(Color.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.top, 32)
                            .padding(.horizontal, 24)
                    }
                    ForEach(model.messages) { item in
                        MessageBubbleView(item: item)
                            .id(item.id)
                            .padding(.horizontal, 12)
                    }
                }
                .padding(.vertical, 12)
            }
            .onChange(of: model.messages.count) { _ in
                if let last = model.messages.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 10) {
            Button {
                attachments.isPresentingPicker = true
            } label: {
                Image(systemName: "photo")
                    .font(.title3)
            }
            .disabled(attachments.isSending || model.isSending)
            .accessibilityLabel("Send photo")

            TextField("Message", text: $model.draft)
                .textFieldStyle(.roundedBorder)

            Button {
                Task { await model.sendText() }
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
            }
            .disabled(model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isSending)
            .accessibilityLabel("Send")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color(uiColor: .systemBackground))
    }

    private var errorIsPresented: Binding<Bool> {
        Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )
    }
}
