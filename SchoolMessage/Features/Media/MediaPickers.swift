import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import AVFoundation

/// フォトライブラリから受け取った動画.
///
/// `PhotosPicker` は動画を `Data` では渡さない(大きすぎるため).
/// アプリのサンドボックス内にコピーしてから URL を扱う.
struct PickedVideo: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { video in
            SentTransferredFile(video.url)
        } importing: { received in
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.copyItem(at: received.file, to: destination)
            return PickedVideo(url: destination)
        }
    }
}

/// カメラで撮影する(写真・動画).
///
/// SwiftUI にはカメラ撮影の標準ビューが無いため `UIImagePickerController` を包む.
struct CameraPicker: UIViewControllerRepresentable {

    enum Capture {
        case photo(Data)
        case video(URL)
    }

    var onCapture: (Capture) -> Void
    var onCancel: () -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let controller = UIImagePickerController()
        controller.sourceType = .camera
        controller.mediaTypes = [UTType.image.identifier, UTType.movie.identifier]
        controller.videoQuality = .typeMedium
        controller.videoMaximumDuration = MediaLimits.videoMaxDuration
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onCapture: onCapture, onCancel: onCancel)
    }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        private let onCapture: (Capture) -> Void
        private let onCancel: () -> Void

        init(onCapture: @escaping (Capture) -> Void, onCancel: @escaping () -> Void) {
            self.onCapture = onCapture
            self.onCancel = onCancel
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            if let movieURL = info[.mediaURL] as? URL {
                onCapture(.video(movieURL))
                return
            }
            if let image = info[.originalImage] as? UIImage,
               let data = image.jpegData(compressionQuality: 1.0) {
                onCapture(.photo(data))
                return
            }
            onCancel()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onCancel()
        }
    }

    /// カメラが使える端末か(シミュレータでは false).
    static var isAvailable: Bool {
        UIImagePickerController.isSourceTypeAvailable(.camera)
    }
}
