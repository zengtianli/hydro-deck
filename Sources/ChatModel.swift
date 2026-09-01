import Foundation
import Observation
import UIKit

// =============================================================================
// 对话状态机：事件流 → UI 状态 + 持久化的唯一翻译点。一次只跑一问（后端并发闸同语义）。
//
// 停止/断线语义（与 web 参考实现 useAgentRun.ts 对齐）：
//   · 人点停止 = 取消连接，后端当前步跑完自停；已流出的部分固化成 aborted turn
//     （否则下一次发送把这轮整段抹掉 —— web 端踩过）。不再取回。
//   · 意外断流 = 进「取回中」，轮询 /api/runs/{id}/events?after_seq 500ms 直到
//     complete=true；孤儿合成终态（synthetic run_orphaned）当句号不当红错。
//   · 切后台回来 = 若上次有没收完的 run（pendingRun 落了盘），自动取回。
// =============================================================================

@MainActor
@Observable
final class ChatModel {
    // 会话
    let store = SessionStore()
    private(set) var session: ChatSession
    var turns: [TurnRecord] { session.turns }

    // 流式中的这一问
    var streaming = false
    var catchingUp = false
    var draftQuestion: String?
    var draftAnswer = ""
    var draftSteps: [StepRecord] = []
    var statusLine = ""
    var notices: [String] = []
    var failure: (headline: String, detail: String)?

    // 图片附件（已上传拿到 image_id 的才算附上）
    struct Attachment: Identifiable, Equatable {
        let id: String              // image_id
        let thumb: UIImage
    }
    var attachments: [Attachment] = []
    var uploadingImage = false

    // 闸
    var needGatePassword = false
    var gateMessage = ""
    private var pendingQuestion: String?

    private var streamTask: Task<Void, Never>?
    private var runId: String?
    private var lastSeq: Int = -1
    private var userStopped = false

    init() {
        // 起在最近一个会话上（历史即上下文）；一个都没有才新建。
        session = ChatSession(id: UUID().uuidString, serverSessionId: nil,
                              createdAt: Date(), updatedAt: Date())
        if let latest = store.sessions.first { session = latest }
    }

    /// 终态 → 给人看的标注。answered 不标（正常）；其余如实，别把「有保留」抹成完成。
    static func terminalLabel(_ t: String) -> String? {
        switch t {
        case "answered":             return nil
        case "answered_degraded":    return "有保留：用到了量纲未验证的工具"
        case "refused_missing_tool": return "拒答：所需工具当前不可用"
        case "refused_no_evidence":  return "拒答：语料里没找到依据"
        case "budget_exhausted":     return "预算耗尽，结果不完整"
        case "verify_failed":        return "未通过数字核对门"
        case "aborted":              return "已停止（保留已生成部分）"
        case "error":                return "运行出错"
        default:                     return t
        }
    }

    // MARK: - 会话管理

    func newSession() {
        stop()
        session = store.newSession()
        failure = nil
        notices = []
    }

    func switchTo(_ id: String) {
        guard id != session.id else { return }
        stop()
        if let s = store.sessions.first(where: { $0.id == id }) {
            session = s
            failure = nil
            notices = []
            // 切过去的会话若欠着一个没收完的 run，顺手取回。
            if s.pendingRun != nil { Task { await resumePendingIfAny() } }
        }
    }

    func deleteSession(_ id: String) {
        store.delete(id)
        if id == session.id { session = store.sessions.first ?? store.newSession() }
    }

    // MARK: - 图片附件

    func attach(_ image: UIImage) async {
        uploadingImage = true
        defer { uploadingImage = false }
        do {
            let id = try await Backend.uploadImage(image)
            let edge: CGFloat = 120
            let k = edge / max(image.size.width, image.size.height)
            let size = CGSize(width: image.size.width * k, height: image.size.height * k)
            let thumb = UIGraphicsImageRenderer(size: size).image { _ in
                image.draw(in: CGRect(origin: .zero, size: size))
            }
            attachments.append(Attachment(id: id, thumb: thumb))
        } catch let e as BackendError {
            if case .gate(let m) = e { askPassword(nil, message: m) }
            else { failure = ("图片传不上去", e.message) }
        } catch {
            failure = ("图片传不上去", (error as NSError).localizedDescription)
        }
    }

    func removeAttachment(_ id: String) {
        attachments.removeAll { $0.id == id }
    }

    // MARK: - 发问 / 停止

    func send(_ text: String) async {
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !streaming else { return }
        failure = nil
        notices = []
        draftQuestion = q
        draftAnswer = ""
        draftSteps = []
        statusLine = "连接中…"
        streaming = true
        userStopped = false
        runId = nil
        lastSeq = -1
        let imageIds = attachments.map(\.id)
        let nImages = imageIds.count
        attachments = []          // 发出即清空（web 端漏了这步，同一批图会粘到下一问）

        await Gate.seedFromLaunchArg(session: ChatStream.session)

        let task = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.streamOnce(q, imageIds: imageIds, nImages: nImages)
            } catch is CancellationError {
                self.finalizeAborted(q, nImages: nImages)
            } catch StreamError.gateBlocked {
                await self.handleGateThenRetry(q, imageIds: imageIds, nImages: nImages)
            } catch {
                if self.userStopped { self.finalizeAborted(q, nImages: nImages) }
                else { await self.recoverOrShow(error, question: q, nImages: nImages) }
            }
            self.streaming = false
            self.draftQuestion = nil
            self.statusLine = ""
        }
        streamTask = task
        await task.value
    }

    /// 停止：断开连接（后端当前步后自停），已流出部分固化成 aborted turn。
    func stop() {
        guard streaming || catchingUp else { return }
        userStopped = true
        streamTask?.cancel()
        streamTask = nil
    }

    /// 密码 sheet 提交后走这里：验过才存钥匙串（存错密码会反复撞限流）。
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

    // MARK: - 前台恢复

    /// 回前台/启动时调：上次有没收完的 run 就取回它。
    func resumePendingIfAny() async {
        guard let p = session.pendingRun, !streaming, !catchingUp else { return }
        if p.userStopped {
            // 人停的：不取回，直接按当时快照固化（若上次进程死在固化之前）。
            appendTurn(question: p.question, answer: p.partialAnswer,
                       terminal: "aborted", citations: [], wallMs: 0,
                       steps: p.steps, nImages: 0)
            return
        }
        draftQuestion = p.question
        draftAnswer = p.partialAnswer
        draftSteps = p.steps
        runId = p.runId
        lastSeq = p.lastSeq
        userStopped = false
        await catchUp(question: p.question, nImages: 0)
        draftQuestion = nil
    }

    // MARK: - 私有：流式主路径

    private func streamOnce(_ q: String, imageIds: [String], nImages: Int) async throws {
        let stream = try await ChatStream.open(message: q,
                                               sessionId: session.serverSessionId,
                                               imageIds: imageIds)
        var sawTerminal = false
        for try await w in stream {
            try Task.checkCancellation()
            apply(w, question: q, nImages: nImages)
            if ChatStream.isTerminal(w.event) { sawTerminal = true }
            else { persistPendingThrottled(q, event: w.event) }
        }
        // 流正常结束但没见终态 = 断流（后端还在跑或已孤儿）→ 取回。
        if !sawTerminal && !userStopped {
            await catchUp(question: q, nImages: nImages)
        }
    }

    private func handleGateThenRetry(_ q: String, imageIds: [String], nImages: Int) async {
        if let pw = Gate.password {
            do {
                try await Gate.login(password: pw, session: ChatStream.session)
                try await streamOnce(q, imageIds: imageIds, nImages: nImages)
            } catch let e as Gate.Failure {
                askPassword(q, message: e.message)
            } catch StreamError.gateBlocked {
                askPassword(q, message: "拿密码换了会话之后仍被拦 —— 密码可能已经改了")
            } catch is CancellationError {
                finalizeAborted(q, nImages: nImages)
            } catch { await recoverOrShow(error, question: q, nImages: nImages) }
        } else {
            askPassword(q, message: "这台设备还没有闸凭证")
        }
    }

    /// 断流后的分诊：拿到过 run_id 就取回，一个事件都没收到就报错（无从取回）。
    private func recoverOrShow(_ error: Error, question: String, nImages: Int) async {
        if runId != nil {
            await catchUp(question: question, nImages: nImages)
        } else {
            show(error)
        }
    }

    /// 轮询取回（web catchup.ts 同款：500ms 间隔，15min 上限，complete=true 收工）。
    private func catchUp(question: String, nImages: Int) async {
        guard let rid = runId else { return }
        catchingUp = true
        statusLine = "连接断了，正在取回已生成的部分…"
        defer { catchingUp = false }
        let deadline = Date().addingTimeInterval(15 * 60)
        while Date() < deadline {
            if Task.isCancelled || userStopped { finalizeAborted(question, nImages: nImages); return }
            do {
                let page = try await ChatStream.catchUpPage(runId: rid, afterSeq: lastSeq)
                var finished = false
                for w in page.events {
                    apply(w, question: question, nImages: nImages)
                    if ChatStream.isTerminal(w.event) { finished = true }
                }
                lastSeq = max(lastSeq, page.lastSeq)
                // ⚠ 终态已把 turn 固化、欠账清零 —— 这之后再 persistPending 会把欠账
                // 复活，complete 分支就会再补一条空 turn（2026-09-01 模拟器实测：
                // 同一问出现两条 aborted）。只有还没见终态才继续记欠账。
                if !finished { persistPending(question) }
                if page.complete {
                    // complete 但事件里没有终态（理论上只在 trace 截断时出现）→
                    // 按已流出内容固化一条，别让这轮凭空消失。
                    if !finished && session.pendingRun != nil {
                        appendTurn(question: question, answer: draftAnswer,
                                   terminal: "aborted", citations: [], wallMs: 0,
                                   steps: draftSteps, nImages: nImages)
                    }
                    return
                }
                if finished { return }
            } catch {
                // 取回自己也断了：短暂网络问题，隔一拍再试（幂等 GET，重试无害）。
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        failure = ("取回超时", "后端 15 分钟没给出终态 —— 稍后从历史里重进这个会话再试。")
    }

    // MARK: - 私有：事件应用与固化

    private func apply(_ w: WireEvent, question: String, nImages: Int) {
        if runId == nil, !w.runId.isEmpty { runId = w.runId }
        if w.seq > lastSeq { lastSeq = w.seq }
        switch w.event {
        case .runStart(let sid, let provider):
            if session.serverSessionId == nil, !sid.isEmpty { session.serverSessionId = sid }
            statusLine = provider.map { "已连（\($0)）· 思考中…" } ?? "已连 · 思考中…"
        case .stepStart(let i, _):
            draftSteps.append(StepRecord(index: i))
            statusLine = "第 \(i + 1) 步…"
        case .toolCall(let name):
            if draftSteps.isEmpty { draftSteps.append(StepRecord(index: 0)) }
            draftSteps[draftSteps.count - 1].tools
                .append(StepRecord.ToolRecord(name: name))
            statusLine = "\(name)…"
        case .toolResult(let name, let ok, let ms):
            if let si = draftSteps.indices.last,
               let ti = draftSteps[si].tools.lastIndex(where: { $0.name == name && $0.ok == nil }) {
                draftSteps[si].tools[ti].ok = ok
                draftSteps[si].tools[ti].durationMs = ms
            }
            statusLine = ok ? "\(name) ✓ \(ms)ms" : "\(name) ✗（继续）"
        case .answerDelta(let t, let reset):
            if reset { draftAnswer = "" }
            draftAnswer += t
        case .notice(let m):
            notices.append(m)
        case .fatal(let m, let orphaned):
            if orphaned || userStopped {
                // 传输层补的句号 / 人停的：按已流出内容固化，不进红色错误态。
                appendTurn(question: question, answer: draftAnswer,
                           terminal: "aborted", citations: [], wallMs: 0,
                           steps: draftSteps, nImages: nImages)
            } else {
                failure = ("运行中断", m)
                session.pendingRun = nil
                store.save(session)
            }
        case .runEnd(let terminal, let answer, let citations, let wallMs):
            // run.end.answer 是权威成稿：有它就以它为准，覆盖 delta 拼接结果。
            let final = (answer?.isEmpty == false ? answer! : draftAnswer)
            appendTurn(question: question,
                       answer: final.isEmpty ? "（无答案）" : final,
                       terminal: terminal,
                       citations: citations.map {
                           TurnRecord.CitationRecord(kind: $0.kind, source: $0.source, label: $0.label)
                       },
                       wallMs: wallMs, steps: draftSteps, nImages: nImages)
        }
    }

    private func appendTurn(question: String, answer: String, terminal: String,
                            citations: [TurnRecord.CitationRecord], wallMs: Int,
                            steps: [StepRecord], nImages: Int) {
        session.turns.append(TurnRecord(question: question,
                                        answer: answer.isEmpty ? "（未生成内容）" : answer,
                                        terminal: terminal, citations: citations,
                                        wallMs: wallMs, steps: steps,
                                        notices: notices, imageCount: nImages))
        session.pendingRun = nil
        draftAnswer = ""
        draftSteps = []
        store.save(session)
    }

    private func finalizeAborted(_ q: String, nImages: Int) {
        guard session.pendingRun != nil || !draftAnswer.isEmpty || draftQuestion != nil else { return }
        appendTurn(question: q, answer: draftAnswer, terminal: "aborted",
                   citations: [], wallMs: 0, steps: draftSteps, nImages: nImages)
    }

    /// 把「欠账」落盘 —— 进程被杀/切后台被掐，下次启动才知道去取回什么。
    /// delta 每 20 条落一次（整份会话 JSON 重写，逐 delta 写是纯浪费）；
    /// 结构性事件（步/工具/终态前后）每次都落。
    private var deltasSincePersist = 0
    private func persistPendingThrottled(_ q: String, event: AgentEvent) {
        if case .answerDelta = event {
            deltasSincePersist += 1
            guard deltasSincePersist >= 20 else { return }
        }
        deltasSincePersist = 0
        persistPending(q)
    }

    private func persistPending(_ q: String) {
        session.pendingRun = ChatSession.PendingRun(
            runId: runId ?? "", lastSeq: lastSeq, question: q,
            partialAnswer: draftAnswer, steps: draftSteps, userStopped: userStopped)
        store.save(session)
    }

    private func askPassword(_ q: String?, message: String) {
        pendingQuestion = q
        gateMessage = message
        needGatePassword = true
    }

    private func show(_ error: Error) {
        if let e = error as? StreamError {
            switch e {
            case .gateBlocked:          failure = (e.headline, "在 Mac 上跑一次 bash seed-gate.sh，或在菜单里重设闸密码。")
            case .http(let s, let b):   failure = (e.headline, "HTTP \(s)\n\(b)")
            case .network(let m):       failure = (e.headline, m)
            }
        } else {
            failure = ("出错了", (error as NSError).localizedDescription)
        }
    }
}
