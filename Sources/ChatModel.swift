import Foundation
import Observation
#if canImport(UIKit)
import UIKit
#endif

// =============================================================================
// 对话状态机：事件流 → UI 状态 + 持久化的唯一翻译点。一次只跑一问（后端并发闸同语义）。
//
// **属主轴（2026-09-01 复审轮立）**：一个 run 的所有写回（欠账/固化 turn）都按
// `activeSessionId` 找它的**属主会话**写，绝不写「当前 session」—— 流式中切换/删除
// 会话时，当前 session 已经不是 run 的家了；两位独立复审者各自撞上同一根轴
// （切走后半截答案写进别人会话、删除后成稿穿越到接位会话）。属主被删 = 写入丢弃
// （用户语义就是丢弃）。
//
// 停止/断线语义（与 web 参考实现对齐）：
//   · 停止 = **同步先固化**（AsyncThrowingStream 被 cancel 是 nil 终止不抛
//     CancellationError，靠 catch 收尾就会静默丢内容——复审实锤），再断连接；
//     后端当前步跑完自停，不再取回。
//   · 意外断流 = 轮询 /api/runs/{id}/events?after_seq 500ms 直到 complete=true；
//     撞闸时拿钥匙串换会话再试**一次**，不盲轮询 302。
//   · 孤儿合成终态（synthetic run_orphaned）当句号不当红错。
// =============================================================================

@MainActor
@Observable
final class ChatModel {
    // 会话
    let store: SessionStore
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

    // 图片附件（已上传拿到 image_id 的才算附上）。
    // ⚠ 发送时**不立刻清空**：连接真建立（run.start）才清 —— 撞闸弹密码、断网失败时
    //   附件都还在，重发不丢图（复审 finding：密码重发丢图、失败后要人重选重传）。
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
    private var pendingAuthorization: AIConsent.Authorization?
    var unsentQuestion: String?

    // Consent is separate from access-gate authentication and applies before every new upload.
    var showAIConsent = false
    private(set) var aiConsentAccepted = AIConsent.isAccepted()

    @discardableResult
    func requireAIConsent() -> Bool {
        aiConsentAccepted = AIConsent.isAccepted()
        if !aiConsentAccepted { showAIConsent = true }
        return aiConsentAccepted
    }

    func acceptAIConsent() {
        AIConsent.accept()
        aiConsentAccepted = true
        showAIConsent = false
        // Deliberately do not send pending text or upload an image on acceptance.
    }

    func authorizationForNewAction() -> AIConsent.Authorization? {
        guard requireAIConsent() else { return nil }
        return try? AIConsent.capture()
    }

    @discardableResult
    func validateAIConsent(_ authorization: AIConsent.Authorization) -> Bool {
        do { try AIConsent.require(authorization); return true }
        catch {
            _ = requireAIConsent()
            failure = ("内容尚未发送", "数据处理授权已经变更，请再次主动发送或选择图片。")
            return false
        }
    }

    private func retainUnsentQuestion(_ text: String) {
        unsentQuestion = text
        _ = requireAIConsent()
    }

    func revokeAIConsent() {
        AIConsent.revoke()
        aiConsentAccepted = false
        if let pendingQuestion { unsentQuestion = pendingQuestion }
        pendingQuestion = nil           // a password-sheet retry must not start a new request
        pendingAuthorization = nil
        showAIConsent = false
        // Already submitted runs may finish; keep their read-only result recovery intact.
    }

    // 当前 run 的属主与快照
    private var streamTask: Task<Void, Never>?
    private var activeSessionId: String?
    private var activeQuestion = ""
    private var activeImageCount = 0
    private var runId: String?
    private var lastSeq: Int = -1
    private var userStopped = false
    private var runFinalized = false
    private var deltasSincePersist = 0

    /// store 注入给验收脚本用临时目录（同 SessionStore.baseDir 的理由）；App 用缺省目录。
    init(store: SessionStore? = nil) {
        self.store = store ?? SessionStore()
        // 起在最近一个会话上（历史即上下文）；一个都没有才新建。
        session = ChatSession(id: UUID().uuidString, serverSessionId: nil,
                              createdAt: Date(), updatedAt: Date())
        if let latest = self.store.sessions.first { session = latest }
        // 还没问第一句之前，首页先用上次后台给的说明文字与词表（演示车道固定用自带的）。
        if !LaneDemo.enabled { ChatStream.restoreUI() }
    }

    /// 终态 → 给人看的标注。answered 不标（正常）；其余如实，别把「有保留」抹成完成。
    /// 后端 `ui.json` 的 vocab 写了哪个终态就用它的名称，包括这里还不认识的新终态；
    /// 下面这份只在后台没写时兜底。
    static func terminalLabel(_ t: String) -> String? {
        let own: String
        switch t {
        case "answered":             own = ""
        case "answered_degraded":    own = "有保留：用到了量纲未验证的工具"
        case "refused_missing_tool": own = "拒答：所需工具当前不可用"
        case "refused_no_evidence":  own = "拒答：语料里没找到依据"
        case "budget_exhausted":     own = "预算耗尽，结果不完整"
        case "verify_failed":        own = "未通过数字核对门"
        case "aborted":              own = "已停止（保留已生成部分）"
        case "error":                own = "运行出错"
        default:                     own = t
        }
        let label = Remote.label(t, own)
        return label.isEmpty ? nil : label
    }

    /// 终态标注前的图标；后台没写时都是同一个提醒图标。
    static func terminalIcon(_ t: String) -> String {
        Remote.icon(t, "exclamationmark.circle")
    }

    // MARK: - 会话管理

    func newSession() {
        stop()                          // 停止会先把旧 run 固化进它自己的属主会话
        clearDraftUI()
        session = store.newSession()
    }

    func switchTo(_ id: String) {
        guard id != session.id else { return }
        stop()
        clearDraftUI()
        if let s = store.sessions.first(where: { $0.id == id }) {
            session = s
            // 切过去的会话若欠着一个没收完的 run，顺手取回。
            if s.pendingRun != nil { Task { await resumePendingIfAny() } }
        }
    }

    func deleteSession(_ id: String) {
        if id == session.id { stop(); clearDraftUI() }   // 正在跑就先停（固化进它，随后一起删）
        store.delete(id)
        if id == session.id { session = store.sessions.first ?? store.newSession() }
    }

    private func clearDraftUI() {
        draftQuestion = nil
        draftAnswer = ""
        draftSteps = []
        notices = []
        failure = nil
        statusLine = ""
    }

    // MARK: - 图片附件

    func attach(_ image: UIImage, authorization: AIConsent.Authorization) async {
        guard validateAIConsent(authorization) else { return }
        uploadingImage = true
        defer { uploadingImage = false }
        do {
            let id = try await Backend.uploadImage(image, authorization: authorization)
            let edge: CGFloat = 120
            let k = edge / max(image.size.width, image.size.height)
            let size = CGSize(width: image.size.width * k, height: image.size.height * k)
            let thumb = UIGraphicsImageRenderer(size: size).image { _ in
                image.draw(in: CGRect(origin: .zero, size: size))
            }
            attachments.append(Attachment(id: id, thumb: thumb))
        } catch is AIConsent.Required {
            _ = validateAIConsent(authorization)
        } catch let e as BackendError {
            if case .gate(let m) = e { askPassword(nil, message: m) }
            else { failure = (T("error.upload.title", "图片传不上去"), e.message) }
        } catch {
            failure = (T("error.upload.title", "图片传不上去"), (error as NSError).localizedDescription)
        }
    }

    func removeAttachment(_ id: String) {
        attachments.removeAll { $0.id == id }
    }

    // MARK: - 发问 / 停止

    func send(_ text: String, authorization supplied: AIConsent.Authorization? = nil) async {
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !streaming else { return }
        guard let authorization = supplied ?? authorizationForNewAction(),
              validateAIConsent(authorization) else {
            retainUnsentQuestion(q)
            return
        }
        failure = nil
        notices = []
        draftQuestion = q
        draftAnswer = ""
        draftSteps = []
        statusLine = T("status.connecting", "连接中…")
        streaming = true
        userStopped = false
        runFinalized = false
        runId = nil
        lastSeq = -1
        deltasSincePersist = 0
        activeSessionId = session.id
        activeQuestion = q
        let imageIds = attachments.map(\.id)
        activeImageCount = imageIds.count

        await Gate.seedFromLaunchArg(session: ChatStream.session)

        let task = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.streamOnce(q, imageIds: imageIds, authorization: authorization)
            } catch is AIConsent.Required {
                self.retainUnsentQuestion(q)
            } catch is CancellationError {
                self.finalizeAborted()
            } catch StreamError.gateBlocked {
                await self.handleGateThenRetry(q, imageIds: imageIds, authorization: authorization)
            } catch {
                if self.userStopped { self.finalizeAborted() }
                else { await self.recoverOrShow(error) }
            }
            // stop() 已同步固化；这里兜的是「cancel 让流 nil 终止、不抛错」的路径。
            if self.userStopped { self.finalizeAborted() }
            self.streaming = false
            self.draftQuestion = nil
            self.statusLine = ""
        }
        streamTask = task
        await task.value
    }

    /// 停止：**先同步固化**已流出内容进属主会话（欠账标 userStopped 并清掉），
    /// 再断开连接（后端当前步后自停）。固化不依赖取消路径 —— AsyncThrowingStream
    /// 被 cancel 是 nil 终止，catch 里收不到（复审实锤，改前已流出内容直接蒸发）。
    func stop() {
        guard streaming || catchingUp else { return }
        userStopped = true
        finalizeAborted()
        streamTask?.cancel()
        streamTask = nil
    }

    /// 密码 sheet 提交后走这里：验过才存钥匙串（存错密码会反复撞限流）。
    /// 附件此刻还在（run.start 前不清），重发自动带上。
    func submitPassword(_ pw: String) async {
        do {
            try await Gate.login(password: pw, session: ChatStream.session)
            Gate.savePassword(pw)
            needGatePassword = false
            if let q = pendingQuestion, let authorization = pendingAuthorization {
                pendingQuestion = nil; pendingAuthorization = nil
                await send(q, authorization: authorization)
            }
        } catch let e as Gate.Failure {
            gateMessage = e.message
        } catch {
            gateMessage = (error as NSError).localizedDescription
        }
    }

    // MARK: - 前台恢复

    /// 回前台/启动时调：**当前会话**欠着没收完的 run 就取回它。
    func resumePendingIfAny() async {
        guard let p = session.pendingRun, !streaming, !catchingUp else { return }
        activeSessionId = session.id
        activeQuestion = p.question
        activeImageCount = 0
        runFinalized = false
        if p.userStopped {
            // 人停的：不取回。stop() 已同步固化过；这里只可能是「固化后进程死在
            // 落盘 pendingRun 清理之前」的残账 —— 按快照补一条。
            draftAnswer = p.partialAnswer
            draftSteps = p.steps
            userStopped = true
            finalizeAborted()
            return
        }
        draftQuestion = p.question
        draftAnswer = p.partialAnswer
        draftSteps = p.steps
        runId = p.runId
        lastSeq = p.lastSeq
        userStopped = false
        await catchUp()
        draftQuestion = nil
        statusLine = ""
    }

    // MARK: - 私有：流式主路径

    private func streamOnce(_ q: String, imageIds: [String],
                            authorization: AIConsent.Authorization) async throws {
        let stream = try await ChatStream.open(message: q,
                                               sessionId: session.serverSessionId,
                                               imageIds: imageIds, authorization: authorization)
        var sawTerminal = false
        for try await w in stream {
            // 每问开头后台带一份界面覆盖项：给了就用，没给或写坏回到自带文案。
            if !LaneDemo.enabled, case .runStart = w.event { ChatStream.adoptUI(w.ui) }
            apply(w)
            if ChatStream.endsRun(w.event) { sawTerminal = true }
            else { persistPendingThrottled(event: w.event) }
        }
        if !sawTerminal && !userStopped {
            // 流正常结束但没见终态 = 断流（后端还在跑或已孤儿）→ 取回。
            await catchUp()
        }
    }

    private func handleGateThenRetry(_ q: String, imageIds: [String],
                                     authorization: AIConsent.Authorization) async {
        guard validateAIConsent(authorization) else { retainUnsentQuestion(q); return }
        if let pw = Gate.password {
            do {
                try await Gate.login(password: pw, session: ChatStream.session)
                try await streamOnce(q, imageIds: imageIds, authorization: authorization)
            } catch is AIConsent.Required {
                retainUnsentQuestion(q)
            } catch let e as Gate.Failure {
                askPassword(q, message: e.message, authorization: authorization)
            } catch StreamError.gateBlocked {
                askPassword(q, message: T("gate.retry.blocked", "拿密码换了会话之后仍被拦 —— 密码可能已经改了"),
                            authorization: authorization)
            } catch is CancellationError {
                finalizeAborted()
            } catch { await recoverOrShow(error) }
        } else {
            askPassword(q, message: T("gate.no.credential", "这台设备还没有闸凭证"), authorization: authorization)
        }
    }

    /// 断流后的分诊：拿到过 run_id 就取回，一个事件都没收到就报错（无从取回）。
    private func recoverOrShow(_ error: Error) async {
        if runId != nil { await catchUp() }
        else {
            // 没发成功的问题退回输入框（ChatView 已清空输入）；附件本就在 run.start 前保留。
            if !activeQuestion.isEmpty { unsentQuestion = activeQuestion }
            show(error)
        }
    }

    /// 轮询取回（web catchup.ts 同款：500ms 间隔，15min 上限，complete=true 收工）。
    /// 撞闸不当瞬态：拿钥匙串换会话重试一次，不行就停下指路（盲轮询 302 十五分钟
    /// 再报「取回超时」= 把人引向错误自救方向 —— 复审 finding）。
    private func catchUp() async {
        guard let rid = runId else { return }
        catchingUp = true
        statusLine = T("status.catchup", "连接断了，正在取回已生成的部分…")
        defer { catchingUp = false }
        var gateRetried = false
        let limit = Remote.seconds("catchup.limit.seconds", 15 * 60, in: 60...3600)
        let poll = Remote.seconds("catchup.poll.seconds", 0.5, in: 0.2...5)
        let deadline = Date().addingTimeInterval(limit)
        while Date() < deadline {
            if Task.isCancelled || userStopped { finalizeAborted(); return }
            do {
                let page = try await ChatStream.catchUpPage(runId: rid, afterSeq: lastSeq)
                var finished = false
                for w in page.events {
                    apply(w)
                    if ChatStream.endsRun(w.event) { finished = true }
                }
                lastSeq = max(lastSeq, page.lastSeq)
                // ⚠ 终态已把 turn 固化、欠账清零 —— 这之后再 persistPending 会把欠账
                // 复活，complete 分支就会再补一条空 turn（2026-09-01 模拟器实测：
                // 同一问出现两条 aborted）。只有还没见终态才继续记欠账。
                if !finished { persistPending() }
                if page.complete {
                    if !finished { finalizeAborted() }   // trace 截断兜底：别让这轮凭空消失
                    return
                }
                if finished { return }
            } catch StreamError.gateBlocked {
                guard !gateRetried, let pw = Gate.password else {
                    failure = (T("error.gate.title", "被访问闸拦住了"),
                               T("error.gate.catchup", "取回需要重新登录 —— 菜单里重设闸密码后，重进这个会话会继续取回。"))
                    return
                }
                gateRetried = true
                do { try await Gate.login(password: pw, session: ChatStream.session) }
                catch {
                    failure = (T("error.gate.title", "被访问闸拦住了"),
                               T("error.gate.catchup.login", "{reason} —— 菜单里重设闸密码后重进本会话。",
                                 ["reason": (error as? Gate.Failure)?.message ?? T("gate.login.failed", "登录失败")]))
                    return
                }
            } catch {
                // 真网络抖动：隔一拍再试（幂等 GET，重试无害）。
            }
            try? await Task.sleep(nanoseconds: UInt64(poll * 1_000_000_000))
        }
        failure = (T("error.catchup.timeout.title", "取回超时"),
                   T("error.catchup.timeout.detail", "后端 {minutes} 分钟没给出终态 —— 稍后从历史里重进这个会话再试。",
                     ["minutes": String(Int((limit / 60).rounded()))]))
    }

    // MARK: - 私有：事件应用与固化（全部按属主会话写）

    private func apply(_ w: WireEvent) {
        if runId == nil, !w.runId.isEmpty { runId = w.runId }
        if w.seq > lastSeq { lastSeq = w.seq }
        switch w.event {
        case .runStart(let sid, let provider):
            if !sid.isEmpty {
                withOwnerSession { if $0.serverSessionId == nil { $0.serverSessionId = sid } }
            }
            attachments = []        // 连接真建立了，这批图确定已交给后端
            statusLine = provider.map { T("status.connected.provider", "已连（{provider}）· 思考中…", ["provider": $0]) }
                ?? T("status.connected", "已连 · 思考中…")
        case .stepStart(let i, _):
            draftSteps.append(StepRecord(index: i))
            statusLine = T("status.step", "第 {n} 步…", ["n": String(i + 1)])
        case .toolCall(let name):
            if draftSteps.isEmpty { draftSteps.append(StepRecord(index: 0)) }
            draftSteps[draftSteps.count - 1].tools
                .append(StepRecord.ToolRecord(name: name))
            statusLine = T("status.tool.running", "{name}…", ["name": name])
        case .toolResult(let name, let ok, let ms):
            if let si = draftSteps.indices.last,
               let ti = draftSteps[si].tools.lastIndex(where: { $0.name == name && $0.ok == nil }) {
                draftSteps[si].tools[ti].ok = ok
                draftSteps[si].tools[ti].durationMs = ms
            }
            statusLine = ok ? T("status.tool.ok", "{name} ✓ {ms}ms", ["name": name, "ms": String(ms)])
                            : T("status.tool.failed", "{name} ✗（继续）", ["name": name])
        case .answerDelta(let t, let reset):
            if reset { draftAnswer = "" }
            draftAnswer += t
        case .notice(let m):
            notices.append(m)
        case .fatal(let m, let orphaned):
            if orphaned || userStopped {
                finalizeAborted()   // 传输层补的句号 / 人停的：固化，不进红色错误态
            } else {
                // **不固化、不清欠账、不断流**：契约保证 error 后必跟 run.end
                // （兜底成稿），到了会覆盖这条 failure；真崩溃则流关闭 → 取回 →
                // 孤儿句号收尾（届时 failure 与 aborted 轮并存，如实）。
                failure = (T("error.interrupted.title", "运行中断"), m)
            }
        case .runEnd(let terminal, let answer, let citations, let wallMs):
            failure = nil           // run.end 是权威终态：此前的 fatal 已被兜底路径接住
            // run.end.answer 是权威成稿：有它就以它为准，覆盖 delta 拼接结果。
            let final = (answer?.isEmpty == false ? answer! : draftAnswer)
            appendTurn(answer: final, terminal: terminal,
                       citations: citations.map {
                           TurnRecord.CitationRecord(kind: $0.kind, source: $0.source, label: $0.label)
                       },
                       wallMs: wallMs)
        }
    }

    /// **写回的唯一通道**：按 activeSessionId 找属主会话。属主是当前 session 就写它
    /// （UI 跟着动）；被切走了就直接写盘上那份；被删了就丢弃（删除语义就是丢弃）。
    private func withOwnerSession(_ mutate: (inout ChatSession) -> Void) {
        guard let id = activeSessionId else { return }
        if session.id == id {
            mutate(&session)
            store.save(session)
        } else if var s = store.sessions.first(where: { $0.id == id }) {
            mutate(&s)
            store.save(s)
        }
    }

    private func appendTurn(answer: String, terminal: String,
                            citations: [TurnRecord.CitationRecord], wallMs: Int) {
        guard !runFinalized else { return }
        runFinalized = true
        let turn = TurnRecord(question: activeQuestion,
                              answer: answer.isEmpty ? T("turn.empty", "（未生成内容）") : answer,
                              terminal: terminal, citations: citations,
                              wallMs: wallMs, steps: draftSteps,
                              notices: notices, imageCount: activeImageCount)
        withOwnerSession {
            $0.turns.append(turn)
            $0.pendingRun = nil
        }
        draftAnswer = ""
        draftSteps = []
    }

    private func finalizeAborted() {
        guard !runFinalized, activeSessionId != nil else { return }
        appendTurn(answer: draftAnswer, terminal: "aborted", citations: [], wallMs: 0)
    }

    /// 把「欠账」落盘 —— 进程被杀/切后台被掐，下次启动才知道去取回什么。
    /// delta 每 20 条落一次（整份会话 JSON 重写，逐 delta 写是纯浪费）；
    /// 结构性事件（步/工具）每次都落。
    private func persistPendingThrottled(event: AgentEvent) {
        if case .answerDelta = event {
            deltasSincePersist += 1
            guard deltasSincePersist >= 20 else { return }
        }
        deltasSincePersist = 0
        persistPending()
    }

    private func persistPending() {
        guard !runFinalized else { return }
        let p = ChatSession.PendingRun(
            runId: runId ?? "", lastSeq: lastSeq, question: activeQuestion,
            partialAnswer: draftAnswer, steps: draftSteps, userStopped: userStopped)
        withOwnerSession { $0.pendingRun = p }
    }

    private func askPassword(_ q: String?, message: String,
                             authorization: AIConsent.Authorization? = nil) {
        pendingQuestion = q
        pendingAuthorization = authorization
        gateMessage = message
        needGatePassword = true
    }

    private func show(_ error: Error) {
        if let e = error as? StreamError {
            switch e {
            case .gateBlocked:          failure = (e.headline, T("error.gate.advice", "请在菜单里重设访问密码后重试。"))
            case .http(let s, let b):   failure = (e.headline, "HTTP \(s)\n\(b)")
            case .network(let m):       failure = (e.headline, m)
            }
        } else {
            failure = (T("error.generic.title", "出错了"), (error as NSError).localizedDescription)
        }
    }
}
