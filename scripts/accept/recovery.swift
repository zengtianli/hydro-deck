import Foundation

// 固定验收 · 故障与恢复（bash scripts/accept/_common.sh recovery）。
// 生产 ChatModel/ChatStream/Store 原样编译，传输层换成本地 URLProtocol；零真实网络、
// 不写钥匙串（不调 submitPassword / Gate.savePassword）、会话落临时目录。
// 语义依据：CLAUDE.md「停止/断线语义」+ ChatModel.swift 顶部注释 + ChatStream.swift 契约注释。

// MARK: - 本用例专用传输：AcceptKit 的 FakeBackend 只会一次性喂完再结束/断流，
// 这里补两种它表达不了的：① 挂住不结束的流（用来测「停止」与「进程中途被杀」）；
// ② 302 跳到 /_gate/（Gate.blocked 的判据是最终 URL 落在 /_gate/ 下）；
// ③ 喂完帧**隔一拍**再断流：FakeBackend.failAfterChunks 把数据与错误同一瞬间交给
//    URLSession，AsyncBytes 会先抛错、缓冲里的帧来不及被读 —— 真实断网时客户端早已
//    读完先到的帧，所以这里留 300ms 间隔才是同一故障形态。
final class ScriptedTransport: URLProtocol {
    enum Mode { case hang([Data]); case redirectToGate; case dropAfter([Data], URLError.Code) }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var modes: [String: Mode] = [:]   // 精确 path
    nonisolated(unsafe) private static var hits: [String] = []

    static func set(_ path: String, _ m: Mode?) { lock.lock(); modes[path] = m; lock.unlock() }
    static func clear() { lock.lock(); modes = [:]; hits = []; lock.unlock() }
    static var seen: [String] { lock.lock(); defer { lock.unlock() }; return hits }
    private static func mode(_ path: String) -> Mode? { lock.lock(); defer { lock.unlock() }; return modes[path] }

    override class func canInit(with request: URLRequest) -> Bool { mode(request.url?.path ?? "") != nil }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        Self.lock.lock(); Self.hits.append(url.path); Self.lock.unlock()
        switch Self.mode(url.path) {
        case .hang(let chunks)?:
            let r = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: SSE.headers)!
            client?.urlProtocol(self, didReceive: r, cacheStoragePolicy: .notAllowed)
            for c in chunks { client?.urlProtocol(self, didLoad: c) }
            // 不 finish：模拟后端还在跑、连接还开着。
        case .dropAfter(let chunks, let code)?:
            let r = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: SSE.headers)!
            client?.urlProtocol(self, didReceive: r, cacheStoragePolicy: .notAllowed)
            for c in chunks { client?.urlProtocol(self, didLoad: c) }
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { [self] in
                client?.urlProtocol(self, didFailWithError: URLError(code))
            }
        case .redirectToGate?:
            let to = URL(string: "https://hydro-agent.tianli.cyou/_gate/login?next=%2Fapi%2Fchat%2Fstream")!
            let r = HTTPURLResponse(url: url, statusCode: 302, httpVersion: "HTTP/1.1",
                                    headerFields: ["Location": to.absoluteString])!
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: to), redirectResponse: r)
        case nil:
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
        }
    }
    override func stopLoading() {}
}

final class Counter: @unchecked Sendable {
    private let l = NSLock(); private var n = 0
    func next() -> Int { l.lock(); defer { l.unlock() }; n += 1; return n }
}

// MARK: - 小工具

func ev(_ type: String, _ seq: Int, runId: String, _ payload: [String: Any] = [:],
        extra: [String: Any] = [:]) -> [String: Any] {
    var d: [String: Any] = ["type": type, "seq": seq, "run_id": runId, "payload": payload]
    for (k, v) in extra { d[k] = v }
    return d
}

func page(_ events: [[String: Any]], complete: Bool, lastSeq: Int) -> FakeBackend.Reply {
    let json = try! JSONSerialization.data(withJSONObject: ["complete": complete, "events": events, "last_seq": lastSeq])
    return .init(headers: ["Content-Type": "application/json"], chunks: [json])
}

func afterSeq(_ r: URLRequest) -> Int {
    Int(URLComponents(url: r.url!, resolvingAgainstBaseURL: false)?
        .queryItems?.first { $0.name == "after_seq" }?.value ?? "") ?? -999
}

func runsRequests() -> [FakeBackend.Seen] { FakeBackend.requests.filter { $0.url.path.hasPrefix("/api/runs/") } }
func streamPosts() -> Int { FakeBackend.requests.filter { $0.url.path == "/api/chat/stream" }.count }

@MainActor func onDisk(_ dir: URL) -> [ChatSession] { SessionStore(baseDir: dir).sessions }

@MainActor func fresh() {
    FakeBackend.reset()
    ScriptedTransport.clear()
}

@main struct RecoveryAcceptance {
    @MainActor static func main() async {
        _ = FakeBackend.install()
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [ScriptedTransport.self, FakeBackend.self]
        c.timeoutIntervalForRequest = 10
        ChatStream.session = URLSession(configuration: c)
        AIConsent.accept()
        let t0 = Date()

        // ── 1. 意外断流 → 按最后 seq 轮询取回 → 以 run.end 固化，且同一问只固化一次 ──
        do {
            fresh()
            let rid = "run-drop"
            ScriptedTransport.set("/api/chat/stream", .dropAfter([
                SSE.frame("run.start", seq: 0, runId: rid, payload: ["session_id": "srv-1"]),
                SSE.frame("step.start", seq: 1, runId: rid, payload: ["index": 0, "kind": "react"]),
                SSE.frame("answer.delta", seq: 2, runId: rid, payload: ["text": "部分"]),
            ], .networkConnectionLost))
            let n = Counter()
            FakeBackend.route("/api/runs/") { r in
                if n.next() == 1 {
                    return page([ev("answer.delta", 3, runId: rid, ["text": "续上"])], complete: false, lastSeq: 3)
                }
                return page([ev("run.end", 4, runId: rid, ["terminal": "answered", "answer": "完整成稿", "wall_ms": 1200])],
                            complete: true, lastSeq: 4)
            }
            let dir = Accept.tempDir("drop")
            let m = ChatModel(store: SessionStore(baseDir: dir))
            await m.send("断流问")
            let runs = runsRequests()
            let seqs = runs.map { afterSeq(URLRequest(url: $0.url)) }
            Accept.expect(runs.first?.url.path == "/api/runs/\(rid)/events" && seqs == [2, 3],
                          "断流后轮询 /api/runs/{id}/events?after_seq=<最后seq> 续取",
                          "paths=\(runs.map(\.url.path)) after_seq=\(seqs)")
            let disk = onDisk(dir)
            Accept.expect(m.turns.count == 1 && m.turns.first?.answer == "完整成稿" && m.turns.first?.terminal == "answered"
                          && m.failure == nil && !m.streaming && !m.catchingUp,
                          "取回终态后以 run.end 成稿固化、不进错误态",
                          "turns=\(m.turns.map { ($0.terminal, $0.answer) }) failure=\(String(describing: m.failure))")
            // 回归（2026-09-01）：见终态后不得 persistPending 复活欠账，再 resume 也不许补空 turn。
            let before = FakeBackend.requests.count
            await m.resumePendingIfAny()
            let disk2 = onDisk(dir)
            Accept.expect(disk.count == 1 && disk[0].turns.count == 1 && disk[0].pendingRun == nil
                          && disk2.first?.turns.count == 1 && m.turns.count == 1 && FakeBackend.requests.count == before,
                          "同一问只固化一次：盘上无残留欠账，再次 resume 不补 turn、不再取回",
                          "disk turns=\(disk.first?.turns.count ?? -1) pending=\(disk.first?.pendingRun != nil) after resume=\(m.turns.count)")
        }

        // ── 2. 停止 = 已流出部分固化为 aborted 轮，不再取回 ──
        do {
            fresh()
            let rid = "run-stop"
            ScriptedTransport.set("/api/chat/stream", .hang([
                SSE.frame("run.start", seq: 0, runId: rid, payload: ["session_id": "srv-2"]),
                SSE.frame("answer.delta", seq: 1, runId: rid, payload: ["text": "已流出的半段"]),
            ]))
            FakeBackend.route("/api/runs/") { _ in page([], complete: false, lastSeq: 1) }
            let dir = Accept.tempDir("stop")
            let m = ChatModel(store: SessionStore(baseDir: dir))
            let sending = Task { await m.send("停止问") }
            let got = await Accept.waitUntil(5) { m.draftAnswer == "已流出的半段" }
            m.stop()
            let syncTurns = m.turns.count          // 停止必须同步固化，不依赖取消路径
            await sending.value
            try? await Task.sleep(nanoseconds: 1_200_000_000)   // 超过一个 500ms 轮询周期
            let disk = onDisk(dir)
            Accept.expect(got && syncTurns == 1 && m.turns.count == 1 && m.turns[0].terminal == "aborted"
                          && m.turns[0].answer == "已流出的半段" && disk.first?.pendingRun == nil && !m.streaming,
                          "停止：已流出部分同步固化为 aborted 轮，欠账清零",
                          "got=\(got) sync=\(syncTurns) turns=\(m.turns.map { ($0.terminal, $0.answer) }) pending=\(disk.first?.pendingRun != nil)")
            Accept.expect(runsRequests().isEmpty && m.failure == nil,
                          "停止后不取回、不进错误态", "runs=\(runsRequests().count) failure=\(String(describing: m.failure))")
        }

        // ── 3. 孤儿合成终态（payload.kind=run_orphaned）当句号，不当红错 ──
        do {
            fresh()
            let rid = "run-orphan"
            ScriptedTransport.set("/api/chat/stream", .dropAfter([
                SSE.frame("run.start", seq: 0, runId: rid, payload: ["session_id": "srv-3"]),
                SSE.frame("answer.delta", seq: 1, runId: rid, payload: ["text": "孤儿前半"]),
            ], .networkConnectionLost))
            FakeBackend.route("/api/runs/") { _ in
                page([ev("error", 2, runId: rid, ["message": "run orphaned", "kind": "run_orphaned"],
                         extra: ["synthetic": true])], complete: true, lastSeq: 2)
            }
            let dir = Accept.tempDir("orphan")
            let m = ChatModel(store: SessionStore(baseDir: dir))
            await m.send("孤儿问")
            Accept.expect(m.failure == nil && m.turns.count == 1 && m.turns[0].terminal == "aborted"
                          && m.turns[0].answer == "孤儿前半" && onDisk(dir).first?.pendingRun == nil,
                          "孤儿合成终态：固化为 aborted 句号，failure 为空（非红错）",
                          "failure=\(String(describing: m.failure)) turns=\(m.turns.map { ($0.terminal, $0.answer) })")
        }

        // ── 4. 非孤儿 fatal 之后仍跟 run.end：以 run.end 为准 ──
        do {
            fresh()
            let rid = "run-fatal"
            FakeBackend.route("/api/chat/stream") { _ in
                .init(headers: SSE.headers, chunks: [
                    SSE.frame("run.start", seq: 0, runId: rid, payload: ["session_id": "srv-4"]),
                    SSE.frame("answer.delta", seq: 1, runId: rid, payload: ["text": "崩前草稿"]),
                    SSE.frame("error", seq: 2, runId: rid, payload: ["message": "工具进程崩了"]),
                    SSE.frame("run.end", seq: 3, runId: rid,
                              payload: ["terminal": "answered_degraded", "answer": "兜底成稿", "wall_ms": 900]),
                ])
            }
            let dir = Accept.tempDir("fatal")
            let m = ChatModel(store: SessionStore(baseDir: dir))
            await m.send("fatal 问")
            Accept.expect(m.failure == nil && m.turns.count == 1 && m.turns[0].answer == "兜底成稿"
                          && m.turns[0].terminal == "answered_degraded" && runsRequests().isEmpty,
                          "非孤儿 fatal 后跟 run.end：以 run.end 成稿/终态为准，清掉 failure，不取回",
                          "failure=\(String(describing: m.failure)) turns=\(m.turns.map { ($0.terminal, $0.answer) }) runs=\(runsRequests().count)")
        }

        // ── 5. HTTP 500 → 可读错误态；问题保留可重发；重发成功 ──
        do {
            fresh()
            let rid = "run-500"
            let n = Counter()
            FakeBackend.route("/api/chat/stream") { _ in
                if n.next() == 1 {
                    return .init(status: 500, headers: ["Content-Type": "text/plain"],
                                 chunks: [Data("internal boom\n".utf8)])
                }
                return .init(headers: SSE.headers, chunks: [
                    SSE.frame("run.start", seq: 0, runId: rid, payload: ["session_id": "srv-5"]),
                    SSE.frame("answer.delta", seq: 1, runId: rid, payload: ["text": "重发"]),
                    SSE.frame("run.end", seq: 2, runId: rid, payload: ["terminal": "answered", "answer": "重发成功"]),
                ])
            }
            let dir = Accept.tempDir("h500")
            let m = ChatModel(store: SessionStore(baseDir: dir))
            let q = "500 问"
            await m.send(q)
            let f = m.failure
            Accept.expect(f != nil && (f!.headline + f!.detail).contains("500") && m.turns.isEmpty
                          && !m.streaming && runsRequests().isEmpty,
                          "HTTP 500：进入可读错误态（failure 含状态码），不固化空轮、不盲取回",
                          "failure=\(String(describing: f)) turns=\(m.turns.count) runs=\(runsRequests().count)")
            // ChatView 发送时已清空输入框；能「保留可重发」的唯一模型通道是 unsentQuestion
            // （ChatView 用它回填输入框/显示「尚未发送」）。
            Accept.expect(m.unsentQuestion == q,
                          "HTTP 500：未成功发出的问题保留在 unsentQuestion 供重发",
                          "unsentQuestion=\(String(describing: m.unsentQuestion)) draftQuestion=\(String(describing: m.draftQuestion))")
            await m.send(q)
            Accept.expect(m.failure == nil && m.turns.count == 1 && m.turns[0].answer == "重发成功" && streamPosts() == 2,
                          "HTTP 500 后重发成功，失败态清除",
                          "failure=\(String(describing: m.failure)) turns=\(m.turns.map(\.answer)) posts=\(streamPosts())")
        }

        // ── 6. 闸拦截 + 本机无闸密码 → needGatePassword，不崩、不盲轮询 ──
        do {
            fresh()
            ScriptedTransport.set("/api/chat/stream", .redirectToGate)
            FakeBackend.route("/_gate/") { _ in
                .init(headers: ["Content-Type": "text/html"], chunks: [Data("<html>login</html>".utf8)])
            }
            // 若本机钥匙串意外有密码，登录也只打本地假端点并失败，不碰真网。
            FakeBackend.route("/_gate/api/login") { _ in
                .init(status: 401, headers: ["Content-Type": "application/json"],
                      chunks: [Data(#"{"ok":false,"error":"密码不对。"}"#.utf8)])
            }
            let dir = Accept.tempDir("gate")
            let m = ChatModel(store: SessionStore(baseDir: dir))
            let hadPw = Gate.hasPassword
            await m.send("闸问")
            try? await Task.sleep(nanoseconds: 700_000_000)
            let gateHit = FakeBackend.requests.contains { $0.url.path.hasPrefix("/_gate/") }
            Accept.expect(m.needGatePassword && !m.gateMessage.isEmpty && !m.streaming && !m.catchingUp
                          && runsRequests().isEmpty && m.turns.isEmpty && gateHit
                          && ScriptedTransport.seen.filter { $0 == "/api/chat/stream" }.count == 1,
                          "闸拦截（302→/_gate/）且无闸密码：进入 needGatePassword，不崩、不盲轮询、不重复发问",
                          "need=\(m.needGatePassword) msg=\(m.gateMessage) hadPw=\(hadPw) gateHit=\(gateHit) runs=\(runsRequests().count) posts=\(ScriptedTransport.seen)")
        }

        // ── 7. 进程「重启」：流中途落盘的 pendingRun，新 ChatModel(同目录) resume 取回成稿 ──
        do {
            fresh()
            let rid = "run-restart"
            ScriptedTransport.set("/api/chat/stream", .hang([
                SSE.frame("run.start", seq: 0, runId: rid, payload: ["session_id": "srv-7"]),
                SSE.frame("step.start", seq: 1, runId: rid, payload: ["index": 0, "kind": "react"]),
                SSE.frame("tool.call", seq: 2, runId: rid, payload: ["name": "kb.search"]),
                SSE.frame("answer.delta", seq: 3, runId: rid, payload: ["text": "未落盘的 delta"]),
            ]))
            FakeBackend.route("/api/runs/") { r in
                page([ev("answer.delta", 3, runId: rid, ["text": "未落盘的 delta"]),
                      ev("run.end", 4, runId: rid, ["terminal": "answered", "answer": "重启后取回的成稿"])],
                     complete: true, lastSeq: 4)
            }
            let dir = Accept.tempDir("restart")
            let a = ChatModel(store: SessionStore(baseDir: dir))
            _ = Task { await a.send("重启问") }   // 连接挂住不结束 = 进程在流中途被杀前的状态
            let persisted = await Accept.waitUntil(5) {
                let p = onDisk(dir).first?.pendingRun
                return p?.runId == rid && p?.lastSeq == 2
            }
            let p = onDisk(dir).first?.pendingRun
            Accept.expect(persisted && p?.question == "重启问" && p?.userStopped == false && p?.steps.count == 1,
                          "流中途结构性事件即落盘 pendingRun（runId/lastSeq/问题/步骤）",
                          "pending=\(String(describing: p))")

            let b = ChatModel(store: SessionStore(baseDir: dir))   // 新进程：同一 store 目录
            let pendingSeen = b.session.pendingRun?.runId == rid
            await b.resumePendingIfAny()
            let seqs = runsRequests().map { afterSeq(URLRequest(url: $0.url)) }
            let disk = onDisk(dir)
            Accept.expect(pendingSeen && seqs.first == 2 && b.turns.count == 1 && b.turns[0].answer == "重启后取回的成稿"
                          && b.turns[0].question == "重启问" && disk.first?.pendingRun == nil && disk.first?.turns.count == 1
                          && b.failure == nil,
                          "重启后 resumePendingIfAny 按落盘 lastSeq 取回并固化成稿，欠账清零",
                          "pendingSeen=\(pendingSeen) after_seq=\(seqs) turns=\(b.turns.map(\.answer)) disk pending=\(disk.first?.pendingRun != nil)")
            a.stop()   // 收掉旧「进程」的挂起连接（其写入发生在断言之后，不影响结论）
        }

        // ── 8. Store 目录里有坏 JSON：跳过但不删，其他会话照常加载 ──
        do {
            let dir = Accept.tempDir("badjson")
            let s = SessionStore(baseDir: dir)
            var good = s.newSession()
            good.turns.append(TurnRecord(question: "好会话", answer: "在", terminal: "answered", citations: [], wallMs: 1))
            s.save(good)
            let bad = dir.appendingPathComponent("session-broken.json")
            try? Data("{ 不是 JSON".utf8).write(to: bad)
            let reloaded = SessionStore(baseDir: dir)
            let m = ChatModel(store: reloaded)
            Accept.expect(reloaded.sessions.count == 1 && reloaded.sessions[0].id == good.id
                          && FileManager.default.fileExists(atPath: bad.path) && m.session.id == good.id
                          && m.turns.first?.question == "好会话",
                          "坏 JSON 会话文件被跳过且保留在盘上，好会话照常加载并成为当前会话",
                          "sessions=\(reloaded.sessions.map(\.id)) badExists=\(FileManager.default.fileExists(atPath: bad.path))")
        }

        Accept.finish(String(format: "故障与恢复 8 类场景，用时 %.1fs", Date().timeIntervalSince(t0)))
    }
}
