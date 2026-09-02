import SwiftUI

@main
struct HydroDeckApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
                // 亮色固定：答案是长文本 + 表格，户外看省眼；与站群产物规范一致。
                .preferredColorScheme(.light)
        }
    }
}

// =============================================================================
// 根：按宽度分两种骨架，同一个 ChatModel（会话/流式/持久化全在它里面，两边共享）。
//
// regular（iPad 全屏 / Mac）→ NavigationSplitView：左栏会话列表常驻，右栏聊天。
// compact（iPhone / iPad 分屏）→ 原 ChatView 原样：打开即聊，历史从工具条入口弹 sheet。
//
// 为什么不用 NavigationSplitView 的自动折叠：它在 compact 下默认先显示侧栏（或带一颗
// 返回侧栏的「<」），iPhone 外观会变；而「打开即聊」是这个 app 的产品皮肤，不能动。
// =============================================================================

struct RootView: View {
    @State private var model = ChatModel()
    @Environment(\.horizontalSizeClass) private var hSize

    var body: some View {
        if hSize == .regular {
            WideLayout(model: model)
        } else {
            ChatView(model: model)
        }
    }
}

private struct WideLayout: View {
    @Bindable var model: ChatModel
    @State private var columns: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            SessionSidebar(model: model)
                .navigationSplitViewColumnWidth(min: 220, ideal: 280, max: 360)
        } detail: {
            ChatView(model: model, sidebarPresent: true)
        }
        .navigationSplitViewStyle(.balanced)
    }
}
