import SwiftUI

struct MessageBubbleView: View {
    let item: ChatItem

    var body: some View {
        HStack {
            if item.isOutgoing { Spacer(minLength: 48) }
            VStack(alignment: item.isOutgoing ? .trailing : .leading, spacing: 4) {
                bubble
                Text(caption)
                    .font(.caption2)
                    .foregroundStyle(Color.secondary)
            }
            if !item.isOutgoing { Spacer(minLength: 48) }
        }
    }

    private var bubble: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch item.kind {
            case .text(let text):
                Text(text)
                    .foregroundStyle(item.isOutgoing ? Color.white : Color.primary)
            case .attachment(let name, _, let image):
                if let image, let uiImage = UIImage(data: image) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .scaledToFill()
                        .frame(maxWidth: 220, maxHeight: 220)
                        .clipped()
                        .cornerRadius(12)
                }
                Text(name)
                    .font(.footnote)
                    .foregroundStyle(item.isOutgoing ? Color.white : Color.primary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(item.isOutgoing ? Color("BubbleSender") : Color("BubbleRecipient"))
        .cornerRadius(18)
    }

    private var caption: String {
        let time = item.timestamp.formatted(date: .omitted, time: .shortened)
        return item.isOutgoing ? "\(time) · \(item.status)" : time
    }
}
