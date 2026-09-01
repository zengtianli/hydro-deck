import Foundation

// =============================================================================
// hydro-agent 的 SSE 客户端。
//
// 契约 SSOT = 后端 `obs/events.py`（判别字段 `type`，业务字段在 `payload`）。
// 帧形状（后端 `app/sse.py::encode_frame`，实测三行 + 空行）：
//     event: tool.call
//     data: {"type":"tool.call","payload":{...},"seq":3,...}
//     id: 3
// 心跳是 `: ping` 注释帧（10s 一发），SSE 规范里冒号开头 = 注释，直接丢。
//
// **白名单消费**：只解下面 enum 里列的事件，未知 type 静默忽略 ——
// 后端加诊断事件不需要动 app。三条硬语义（后端 2026-09-01 立的结构轴）：
//   · answer.delta.reset == true → 新一稿第一段，清掉已累积正文再接
//   · error.nonfatal == true    → 提示性事件，run 照常继续，不进错误态
//   · run.end.answer            → 权威成稿，覆盖 delta 拼接结果
// =============================================================================

struct Citation: Identifiable, Equatable {
    let id = UUID()
    let kind: String        // rag | tool
    let source: String
    let label: String?
}

enum AgentEvent {
    case runStart(sessionId: String, provider: String?)
    case stepStart(index: Int, kind: String)
    case toolCall(name: String)
    case toolResult(name: String, ok: Bool, durationMs: Int)
    case answerDelta(text: String, reset: Bool)
    case notice(message: String)                       // error 且 nonfatal
    case fatal(message: String)                        // error 且 !nonfatal（终态）
    case runEnd(terminal: String, answer: String?, citations: [Citation], wallMs: Int)
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
        // 60s 收不到任何字节才算断。
        c.timeoutIntervalForRequest = 60
        c.timeoutIntervalForResource = 600
        return URLSession(configuration: c)
    }()

    /// 发一问，返回事件流。撞闸时抛 `StreamError.gateBlocked`，
    /// 由调用方决定「拿钥匙串密码换会话重试一次」还是「向人要密码」——
    /// 重试策略不写死在这层（day-deck 的教训：只准重试一次，无限重试 = 拿错密码撞限流）。
    static func open(message: String, sessionId: String?) async throws
        -> AsyncThrowingStream<AgentEvent, Error>
    {
        var req = URLRequest(url: URL(string: base + "/api/chat/stream")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        var body: [String: Any] = ["message": message, "paradigm": "react"]
        if let sid = sessionId { body["session_id"] = sid }
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
                        if case .runEnd = ev { break }
                        if case .fatal = ev { break }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: StreamError.network((error as NSError).localizedDescription))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// 一条 wire dict → 事件。**不容错补默认值**：关键字段缺失就返回 nil 丢弃该帧，
    /// 而不是渲染一个猜出来的东西（day-deck 的 decode 规矩，同源）。
    private static func decode(_ d: [String: Any]) -> AgentEvent? {
        guard let type = d["type"] as? String else { return nil }
        let p = (d["payload"] as? [String: Any]) ?? [:]
        switch type {
        case "run.start":
            guard let sid = p["session_id"] as? String else { return nil }
            return .runStart(sessionId: sid, provider: p["provider_selected"] as? String)
        case "step.start":
            guard let i = p["index"] as? Int, let k = p["kind"] as? String else { return nil }
            return .stepStart(index: i, kind: k)
        case "tool.call":
            guard let n = p["name"] as? String else { return nil }
            return .toolCall(name: n)
        case "tool.result":
            guard let n = p["name"] as? String, let ok = p["ok"] as? Bool else { return nil }
            return .toolResult(name: n, ok: ok, durationMs: p["duration_ms"] as? Int ?? 0)
        case "answer.delta":
            guard let t = p["text"] as? String else { return nil }
            return .answerDelta(text: t, reset: p["reset"] as? Bool ?? false)
        case "error":
            let msg = (p["message"] as? String) ?? "未知错误"
            let nonfatal = p["nonfatal"] as? Bool ?? false
            return nonfatal ? .notice(message: msg) : .fatal(message: msg)
        case "run.end":
            guard let terminal = p["terminal"] as? String else { return nil }
            let cites = (p["citations"] as? [[String: Any]] ?? []).compactMap { c -> Citation? in
                guard let kind = c["kind"] as? String, let src = c["source"] as? String else { return nil }
                return Citation(kind: kind, source: src, label: c["label"] as? String)
            }
            return .runEnd(terminal: terminal,
                           answer: p["answer"] as? String,
                           citations: cites,
                           wallMs: p["wall_ms"] as? Int ?? 0)
        default:
            return nil        // llm.request / retrieve / verify / heartbeat 等：本 app 不消费
        }
    }
}
