import SwiftUI

@main
struct HydroDeckApp: App {
    var body: some Scene {
        WindowGroup {
            ChatView()
                // 亮色固定：答案是长文本 + 表格，户外看省眼；与站群产物规范一致。
                .preferredColorScheme(.light)
        }
    }
}
