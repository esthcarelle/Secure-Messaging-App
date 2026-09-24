import SwiftUI
import UIKit
import SecureMessagingKit

@MainActor
final class AttachmentViewModel: ObservableObject {
    @Published var isPresentingPicker = false
    @Published var isSending = false

    func send(_ image: UIImage, through chat: ChatViewModel) async {
        guard let file = ImageEncoding.jpeg(image, maxDimension: 2048, quality: 0.7),
              let thumbnail = ImageEncoding.jpeg(image, maxDimension: 320, quality: 0.6)
        else {
            chat.errorMessage = "Could not read that photo."
            return
        }
        isSending = true
        defer { isSending = false }
        await chat.sendAttachment(
            OutboundAttachment(
                fileName: "photo.jpg",
                mimeType: "image/jpeg",
                fileBytes: file,
                thumbnailBytes: thumbnail
            )
        )
    }
}

enum ImageEncoding {
    static func jpeg(_ image: UIImage, maxDimension: CGFloat, quality: CGFloat) -> Data? {
        let longest = max(image.size.width, image.size.height)
        let scale = longest > 0 ? min(1, maxDimension / longest) : 1
        let target = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: target, format: format)
        let rendered = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        return rendered.jpegData(compressionQuality: quality)
    }
}

struct ImagePicker: UIViewControllerRepresentable {
    var onPick: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .photoLibrary
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {
        context.coordinator.parent = self
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        var parent: ImagePicker

        init(parent: ImagePicker) {
            self.parent = parent
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            if let image = info[.originalImage] as? UIImage {
                parent.onPick(image)
            }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}
