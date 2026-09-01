import Foundation
import Observation

// =============================================================================
// 对话状态机。一次只跑一问（后端并发闸也是这个语义），事件流 → UI 状态的唯一翻译点。
// =============================================================================

@MainActor
@Observable
final class ChatModel {
    struct Turn: Identifiable {
        let id = UUID()
        let question: String
        var answer: String
        var terminal: String
        var citations: [Citation]
        var wallMs: Int
    }

    var turns: [Turn] = []
    var sessionId: String?

    // 流式中的这一问
    var streaming = false
    var draftQuestion: String?
    var draftAnswer = ""
    var statusLine = ""            // 「第 2 步 · kb.read_doc …」
    var notices: [String] = []     // nonfatal 提示（路由降级 / 重述轮），只显示不进错误态
    var failure: (headline: String, detail: String)?

    // 闸
    var needGatePassword = false
    var gateMessage = ""
    private var pendingQuestion: String?

    /// 终态 → 给人看的标注。answered 不标（正常）；其余如实，别把「有保留」抹成完成。
    static func terminalLabel(_ t: String) -> String? {
        switch t {
        case "answered":             return nil
        case "answered_degraded":    return "有保留：用到了量纲未验证的工具"
        case "refused_missing_tool": return "拒答：所需工具当前不可用"
        case "refused_no_evidence":  return "拒答：语料里没找到依据"
        case "budget_exhausted":     return "预算耗尽，结果不完整"
        case "verify_failed":        return "未通过数字核对门"
        case "error":                return "运行出错"
        default:                     return t
        }
    }

    func send(_ text: String) async {
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !streaming else { return }
        failure = nil
        notices = []
        draftQuestion = q
        draftAnswer = ""
        statusLine = "连接中…"
        streaming = true
        defer { streaming = false; draftQuestion = nil; statusLine = "" }

        await Gate.seedFromLaunchArg(session: ChatStream.session)

        do {
            try await streamOnce(q)
        } catch StreamError.gateBlocked {
            // 撞闸：钥匙串里有密码就换一次会话重试**一次**；没有就向人要。
            if let pw = Gate.password {
                do {
                    try await Gate.login(password: pw, session: ChatStream.session)
                    try await streamOnce(q)
                } catch let e as Gate.Failure {
                    askPassword(q, message: e.message)
                } catch StreamError.gateBlocked {
                    askPassword(q, message: "拿密码换了会话之后仍被拦 —— 密码可能已经改了")
                } catch { show(error) }
            } else {
                askPassword(q, message: "这台设备还没有闸凭证")
            }
        } catch { show(error) }
    }

    /// 密码 sheet 提交后走这里：验过才存钥匙串（存了错密码会反复撞限流）。
    func submitPassword(_ pw: String) async {
        do {
            try await Gate.login(password: pw, session: ChatStream.session)
            Gate.savePassword(pw)
            needGatePassword = false
            if let q = pendingQuestion { pendingQuestion = nil; await send(q) }
        } catch let e as Gate.Failure {
            gateMessage = e.message
        } catch {
            gateMessage = (error as NSError).localizedDescription
        }
    }

    // MARK: - 私有

    private func streamOnce(_ q: String) async throws {
        var streamedTools = 0
        for try await ev in try await ChatStream.open(message: q, sessionId: sessionId) {
            switch ev {
            case .runStart(let sid, let provider):
                sessionId = sid
                statusLine = provider.map { "已连（\($0)）· 思考中…" } ?? "已连 · 思考中…"
            case .stepStart(let i, _):
                statusLine = "第 \(i + 1) 步…"
            case .toolCall(let name):
                streamedTools += 1
                statusLine = "第 \(streamedTools) 次工具 · \(name)…"
            case .toolResult(let name, let ok, let ms):
                statusLine = ok ? "\(name) ✓ \(ms)ms" : "\(name) ✗（继续）"
            case .answerDelta(let t, let reset):
                if reset { draftAnswer = "" }
                draftAnswer += t
            case .notice(let m):
                notices.append(m)
            case .fatal(let m):
                failure = ("运行中断", m)
            case .runEnd(let terminal, let answer, let citations, let wallMs):
                // run.end.answer 是权威成稿：有它就以它为准，覆盖 delta 拼接结果。
                let final = answer ?? draftAnswer
                turns.append(Turn(question: q, answer: final.isEmpty ? "（无答案）" : final,
                                  terminal: terminal, citations: citations, wallMs: wallMs))
                draftAnswer = ""
            }
        }
    }

    private func askPassword(_ q: String, message: String) {
        pendingQuestion = q
        gateMessage = message
        needGatePassword = true
    }

    private func show(_ error: Error) {
        if let e = error as? StreamError {
            switch e {
            case .gateBlocked:          failure = (e.headline, "在 Mac 上跑一次 bash seed-gate.sh，或在设置里输入闸密码。")
            case .http(let s, let b):   failure = (e.headline, "HTTP \(s)\n\(b)")
            case .network(let m):       failure = (e.headline, m)
            }
        } else {
            failure = ("出错了", (error as NSError).localizedDescription)
        }
    }
}
