import Foundation

// =============================================================================
// hydro-agent 的 SSE 客户端 + 断线取回（catch-up）。
//
// 契约 SSOT = 后端 `obs/events.py`（判别字段 `type`，业务字段在 `payload`）。
// 帧形状（后端 `app/sse.py::encode_frame`）：`event:` / `data:` / `id:` 三行 + 空行；
// 心跳是 `: ping` 注释帧（10s 一发），冒号开头 = SSE 注释，直接丢。
//
// **白名单消费**：只解 enum 里列的事件，未知 type 静默忽略。三条硬语义
// （后端 2026-09-01 立的结构轴）：
//   · answer.delta.reset == true → 新一稿第一段，清掉已累积正文再接
//   · error.nonfatal == true    → 提示性事件，run 照常继续，不进错误态
//   · run.end.answer            → 权威成稿，覆盖 delta 拼接结果
//
// **停止/断线语义**（web 参考实现 useAgentRun.ts + 后端 app/sse.py 的取消协议）：
//   没有 cancel 端点 —— 客户端断开连接，后端在**当前步跑完后**自停；
//   已生成部分从 GET /api/runs/{id}/events?after_seq=N 轮询取回（500ms 间隔），
//   complete=true 收工。孤儿 run 的合成终态带 synthetic:true + kind=run_orphaned，
//   那是传输层补的句号，不是 agent 报错，别当红色错误渲染。
// =============================================================================

struct Citation: Identifiable, Equatable {
    let id = UUID()
    let kind: String        // rag | tool
    let source: String      // rag → doc_id（kb.read_doc 同一命名空间，可回原文）
    let label: String?
}

enum AgentEvent {
    case runStart(sessionId: String, provider: String?)
    case stepStart(index: Int, kind: String)
    case toolCall(name: String)
    case toolResult(name: String, ok: Bool, durationMs: Int)
    case answerDelta(text: String, reset: Bool)
    case notice(message: String)                       // error 且 nonfatal
    case fatal(message: String, orphaned: Bool)        // error 且 !nonfatal（终态）
    case runEnd(terminal: String, answer: String?, citations: [Citation], wallMs: Int)
}

/// 一帧解出来的事件 + 续传游标。seq 用于断线后 after_seq 续传。
struct WireEvent {
    let seq: Int
    let runId: String
    let event: AgentEvent
}

enum StreamError: Error {
    case gateBlocked                    // 302 落到 /_gate/ 登录页
    case http(status: Int, body: String)
    case network(String)

    var headline: String {
        switch self {
        case .gateBlocked:          return "被访问闸拦住了"
        case .http(let s, _):       return "后端返回 HTTP \(s)"
        case .network:              return "连不上后端"
        }
    }
}

enum ChatStream {
    static let base = "https://hydro-agent.tianli.cyou"

    /// 共享 session：cookie jar 跨启动保留（闸会话 cookie 住这里）。
    static let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.httpCookieStorage = .shared
        c.httpShouldSetCookies = true
        // 流式请求的 request timeout 是「空闲间隔」不是总时长；后端 10s 一跳心跳，
        // 60s 收不到任何字节才算断（web 端 STALL_MS=90s，这里更紧一点即可）。
        c.timeoutIntervalForRequest = 60
        c.timeoutIntervalForResource = 600
        return URLSession(configuration: c)
    }()

    /// 发一问，返回事件流。撞闸时抛 `StreamError.gateBlocked`，
    /// 由调用方决定「拿钥匙串密码换会话重试一次」还是「向人要密码」——
    /// 重试策略不写死在这层（day-deck 的教训：只准重试一次）。
    static func open(message: String, sessionId: String?, imageIds: [String] = [])
        async throws -> AsyncThrowingStream<WireEvent, Error>
    {
        var req = URLRequest(url: URL(string: base + "/api/chat/stream")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        var body: [String: Any] = ["message": message, "paradigm": "react"]
        if let sid = sessionId { body["session_id"] = sid }
        if !imageIds.isEmpty { body["image_ids"] = imageIds }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, resp) = try await session.bytes(for: req)
        if Gate.blocked(resp) { throw StreamError.gateBlocked }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
        guard code == 200 else {
            var tail = ""
            for try await line in bytes.lines { tail += line; if tail.count > 300 { break } }
            throw StreamError.http(status: code, body: String(tail.prefix(300)))
        }

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data:") else { continue }   // event:/id:/`: ping` 都不用
                        let json = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                        guard let d = try? JSONSerialization.jsonObject(with: Data(json.utf8))
                                as? [String: Any],
                              let ev = decode(d) else { continue }
                        continuation.yield(ev)
                        // 只有 run.end 才提前收线。error（含 nonfatal=false）**不是**流终态：
                        // 后端契约是「异常也必须发 error 再发 run.end」（runner.py），
                        // fatal 后面往往跟着兜底成稿的 run.end —— 在这断线等于把救回来的
                        // 答案扔了（复审实锤）。真崩溃后端自己会关连接，循环自然结束。
                        if case .runEnd = ev.event { break }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: StreamError.network((error as NSError).localizedDescription))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - 断线取回

    struct CatchUpPage {
        let events: [WireEvent]
        let complete: Bool
        let lastSeq: Int
    }

    /// 取一页补发事件。轮询循环（500ms、上限、终止条件）由调用方掌握 ——
    /// 这层只做一次幂等 GET，方便按页喂 UI。
    static func catchUpPage(runId: String, afterSeq: Int) async throws -> CatchUpPage {
        let esc = runId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? runId
        let url = URL(string: base + "/api/runs/\(esc)/events?after_seq=\(afterSeq)")!
        let (data, resp) = try await session.data(from: url)
        if Gate.blocked(resp) { throw StreamError.gateBlocked }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
        guard code == 200 else {
            throw StreamError.http(status: code,
                                   body: String(String(data: data, encoding: .utf8)?.prefix(300) ?? ""))
        }
        guard let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let complete = d["complete"] as? Bool else {
            throw StreamError.network("events 响应解不出 complete 字段")
        }
        let evs = (d["events"] as? [[String: Any]] ?? []).compactMap(decode)
        return CatchUpPage(events: evs,
                           complete: complete,
                           lastSeq: d["last_seq"] as? Int ?? afterSeq)
    }

    /// 这条事件是否**收束了整个 run**（run.end，或孤儿合成句号）。
    /// 非孤儿的 fatal 不算：契约保证它后面还有 run.end；真崩溃则由流关闭 + 取回收尾。
    static func endsRun(_ ev: AgentEvent) -> Bool {
        switch ev {
        case .runEnd:                       return true
        case .fatal(_, let orphaned):       return orphaned
        default:                            return false
        }
    }

    // MARK: - 解码

    /// 一条 wire dict → 事件。**不容错补默认值**：关键字段缺失就返回 nil 丢弃该帧，
    /// 而不是渲染一个猜出来的东西（day-deck 的 decode 规矩，同源）。
    private static func decode(_ d: [String: Any]) -> WireEvent? {
        guard let type = d["type"] as? String else { return nil }
        let p = (d["payload"] as? [String: Any]) ?? [:]
        let seq = d["seq"] as? Int ?? -1
        let runId = d["run_id"] as? String ?? ""

        func wrap(_ ev: AgentEvent) -> WireEvent { WireEvent(seq: seq, runId: runId, event: ev) }

        switch type {
        case "run.start":
            guard let sid = p["session_id"] as? String else { return nil }
            return wrap(.runStart(sessionId: sid, provider: p["provider_selected"] as? String))
        case "step.start":
            guard let i = p["index"] as? Int, let k = p["kind"] as? String else { return nil }
            return wrap(.stepStart(index: i, kind: k))
        case "tool.call":
            guard let n = p["name"] as? String else { return nil }
            return wrap(.toolCall(name: n))
        case "tool.result":
            guard let n = p["name"] as? String, let ok = p["ok"] as? Bool else { return nil }
            return wrap(.toolResult(name: n, ok: ok, durationMs: p["duration_ms"] as? Int ?? 0))
        case "answer.delta":
            guard let t = p["text"] as? String else { return nil }
            return wrap(.answerDelta(text: t, reset: p["reset"] as? Bool ?? false))
        case "error":
            let msg = (p["message"] as? String) ?? "未知错误"
            if p["nonfatal"] as? Bool ?? false { return wrap(.notice(message: msg)) }
            // 良性孤儿句号**只认 kind=run_orphaned**。synthetic:true 还覆盖泵线程异常/
            // trace 坏行/无终态 bug —— 那些是必须报给用户的真实故障，判宽了会把后端
            // 崩溃静默固化成「已停止」，用户以为是自己停的（复审实锤）。
            let orphaned = (p["kind"] as? String) == "run_orphaned"
            return wrap(.fatal(message: msg, orphaned: orphaned))
        case "run.end":
            guard let terminal = p["terminal"] as? String else { return nil }
            let cites = (p["citations"] as? [[String: Any]] ?? []).compactMap { c -> Citation? in
                guard let kind = c["kind"] as? String, let src = c["source"] as? String else { return nil }
                return Citation(kind: kind, source: src, label: c["label"] as? String)
            }
            return wrap(.runEnd(terminal: terminal,
                                answer: p["answer"] as? String,
                                citations: cites,
                                wallMs: p["wall_ms"] as? Int ?? 0))
        default:
            return nil        // llm.request / retrieve / verify / heartbeat 等：本 app 不消费
        }
    }
}
