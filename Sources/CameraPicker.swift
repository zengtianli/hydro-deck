import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// =============================================================================
// 拍照直传（相册走 PhotosPicker，这里只管相机）。
// 用系统 UIImagePickerController：聊天附图要的是「随手一拍」，不是 wrong-book
// 那种找边+去透视的文档扫描 —— 别把重家伙搬过来。
// 模拟器没相机：isSourceTypeAvailable(.camera)=false → 按钮不渲染（wrong-book 同款判据）。
// =============================================================================

#if !os(iOS)
// Mac 没有 UIImagePickerController，也没有「随手一拍」这个场景（相册/文件走 PhotosPicker 那条路）。
// 只保留同名类型让调用点不变：available=false → 按钮不渲染（与模拟器同一条路）。
struct CameraPicker: View {
    let onImage: (UIImage?) -> Void
    static var available: Bool { false }
    var body: some View { EmptyView() }
}
#else
struct CameraPicker: UIViewControllerRepresentable {
    let onImage: (UIImage?) -> Void

    static var available: Bool {
        // 模拟器上 isSourceTypeAvailable 也可能报 true 而实际没相机（wrong-book 在
        // VNDocumentCamera 上实测同型坑，2026-09-01 模拟器截图里按钮真出现了）→ 显式排除。
        #if targetEnvironment(simulator)
        return false
        #else
        return UIImagePickerController.isSourceTypeAvailable(.camera)
        #endif
    }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let c = UIImagePickerController()
        c.sourceType = .camera
        c.delegate = context.coordinator
        return c
    }

    func updateUIViewController(_ vc: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onImage: onImage) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate,
                             UINavigationControllerDelegate {
        let onImage: (UIImage?) -> Void
        init(onImage: @escaping (UIImage?) -> Void) { self.onImage = onImage }

        // 三个出口都必须回调（取消/失败回 nil），否则界面卡在拍照页（wrong-book 教训）。
        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            picker.dismiss(animated: true)
            onImage(info[.originalImage] as? UIImage)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            picker.dismiss(animated: true)
            onImage(nil)
        }
    }
}
#endif
