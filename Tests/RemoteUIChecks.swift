import Foundation

// 后台覆盖项的三条验收里的两条（第三条「旧客户端照常」在 RemoteUIOldClient.swift）：
//   ① 后台写一个键，客户端不改就变；② 后台写坏，整段回落、其余数据照常解出。
// 走生产路径：ChatModel.send → ChatStream.open（真实解码）→ adoptUI → Remote / T()；
// 只有传输层换成本地 URLProtocol，喂的是后端生产出网路径导出的字节（Tests/fixtures/remote-ui）。
@main
private struct RemoteUIChecks {
    /// 接入之前写死在客户端的终态标注，逐字抄自基线提交的 ChatModel.terminalLabel。
    static let own: [(String, String?)] = [
        ("answered", nil),
        ("answered_degraded", "有保留：用到了量纲未验证的工具"),
        ("refused_missing_tool", "拒答：所需工具当前不可用"),
        ("refused_no_evidence", "拒答：语料里没找到依据"),
        ("budget_exhausted", "预算耗尽，结果不完整"),
        ("verify_failed", "未通过数字核对门"),
        ("aborted", "已停止（保留已生成部分）"),
        ("error", "运行出错"),
        ("some_future_state", "some_future_state"),
    ]
    static let timeoutDetail = "后端 {minutes} 分钟没给出终态 —— 稍后从历史里重进这个会话再试。"

    @MainActor
    static func bundledEverywhere(_ when: String) {
        expect(own.allSatisfy { ChatModel.terminalLabel($0.0) == $0.1 },
               "\(when)：终态标注与接入前逐字相同")
        expect(ChatModel.terminalIcon("aborted") == "exclamationmark.circle" && Remote.tone("aborted") == nil
               && T("empty.title", "问一句试试") == "问一句试试"
               && T("error.catchup.timeout.detail", timeoutDetail, ["minutes": "15"])
                    == "后端 15 分钟没给出终态 —— 稍后从历史里重进这个会话再试。"
               && Remote.seconds("catchup.limit.seconds", 900, in: 60...3600) == 900
               && Remote.seconds("catchup.poll.seconds", 0.5, in: 0.2...5) == 0.5
               && Remote.count("doc.page.chars", 4000, in: 500...20000) == 4000,
               "\(when)：图标、色调、说明文字与阈值都是自带的")
    }

    @MainActor
    static func main() async throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1])
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("hydro-remote-ui-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        AIConsent.accept()
        defer { AIConsent.revoke() }
        ChatStream.session = FrameTransport.session()
        let model = ChatModel(store: SessionStore(baseDir: scratch))

        func ask(_ name: String) async {
            FrameTransport.load(directory, name)
            guard let authorization = model.authorizationForNewAction() else { fatalError("取不到授权") }
            await model.send("合成验收 \(name)", authorization: authorization)
        }
        func relaunch() { Remote.ui = nil; ChatStream.restoreUI() }

        // 解码原语：键不存在 / 不是对象 / 值类型不对。
        expect(ChatStream.decodeUI(nil) == nil, "帧里没有 ui 键 → nil（老后端）")
        if let broken = ChatStream.decodeUI("oops"), let wrong = ChatStream.decodeUI(["copy": ["k": 5]]) {
            expect(broken.value == nil && wrong.value == nil, "ui 不是对象或值类型不对 → 整段作废")
        } else { expect(false, "写坏的 ui 应当解成「有键但作废」") }

        bundledEverywhere("还没连过后端")

        // ① 后台写了几项 → 这一问之后界面就变，客户端一行没改。
        await ask("written")
        expect(model.turns.count == 1 && model.turns[0].terminal == "refused_no_evidence"
               && model.turns[0].answer == "语料里没有这条依据。" && model.failure == nil,
               "written：这一问照常固化成一轮", "turns=\(model.turns.count)")
        expect(ChatModel.terminalLabel("refused_no_evidence") == "没找到依据"
               && ChatModel.terminalIcon("refused_no_evidence") == "questionmark.circle"
               && Remote.tone("refused_no_evidence") == "warn",
               "written：后台改了一个终态的名称、图标、色调，客户端照着显示")
        expect(ChatModel.terminalLabel("paused_for_review") == "等人工复核",
               "written：客户端不认识的新终态也有名字了")
        expect(ChatModel.terminalLabel("aborted") == "已停止（保留已生成部分）"
               && T("empty.body", "自带说明") == "自带说明",
               "written：后台没写的项仍是自带的")
        expect(T("empty.title", "问一句试试") == "先问一句"
               && T("error.catchup.timeout.detail", timeoutDetail, ["minutes": "10"])
                    == "等了 10 分钟还没结果，稍后再进这个会话。",
               "written：说明文字换成后台的，占位符照常填")
        expect(Remote.seconds("catchup.limit.seconds", 900, in: 60...3600) == 600
               && Remote.seconds("catchup.poll.seconds", 0.5, in: 0.2...5) == 5,
               "written：阈值用后台的，超出范围的被夹住")
        relaunch()
        expect(ChatModel.terminalLabel("refused_no_evidence") == "没找到依据" && T("empty.title", "问一句试试") == "先问一句",
               "written：重新启动后、还没问第一句，首页已经用上次后台给的那份")

        // ② 后台把值的类型写错 → 整段回落，这一问的数据照常。
        await ask("malformed")
        expect(model.turns.count == 2 && model.turns[1].terminal == "refused_no_evidence"
               && model.turns[1].answer == "语料里没有这条依据。" && model.failure == nil,
               "malformed：ui 写坏不影响这一问的事件与成稿", "turns=\(model.turns.count)")
        expect(Remote.ui == nil, "malformed：覆盖项整段作废")
        bundledEverywhere("malformed")
        relaunch()
        expect(Remote.ui == nil, "malformed：上一份缓存也清掉了，重启不会复活旧覆盖项")

        // ② 的另一种：ui.json 根本不是 JSON → 后端给空四段。
        await ask("written")
        await ask("broken")
        expect(model.turns.count == 4 && model.turns[3].answer == "语料里没有这条依据。",
               "broken：流照常从头到尾")
        bundledEverywhere("broken")

        // 仓库默认（四段全空）：每一处与接入前逐字相同。
        await ask("empty")
        expect(model.turns.count == 5, "empty：这一问照常固化")
        bundledEverywhere("empty")
        relaunch()
        bundledEverywhere("empty 重启后")
        print("SUMMARY 写一个键即变、写坏整段回落、全空与接入前逐字相同；0 真实网络")
    }
}
