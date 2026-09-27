import Foundation
import CoreGraphics

// 固定验收：功能。生产 ChatModel/ChatStream/Backend/Store 走真实代码路径，传输层换成本地 FakeBackend。
// 不碰钥匙串（不调 submitPassword / Gate.savePassword），不连真实后端。

@main struct FunctionalityAcceptance {
    static func json(_ d: Data) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] ?? [:]
    }
    static func chatBodies() -> [[String: Any]] {
        FakeBackend.requests.filter { $0.url.path == "/api/chat/stream" }.map { json($0.body) }
    }
    static func sse(_ frames: [Data]) -> FakeBackend.Reply { .init(headers: SSE.headers, chunks: frames) }
    static func jsonReply(_ obj: [String: Any]) -> FakeBackend.Reply {
        .init(headers: ["Content-Type": "application/json"], chunks: [try! JSONSerialization.data(withJSONObject: obj)])
    }

    @MainActor static func main() async {
        _ = FakeBackend.install()
        AIConsent.accept()
        let dir = Accept.tempDir("sessions")
        let m = ChatModel(store: SessionStore(baseDir: dir))

        // ── 1. 一问一答：delta 累积、reset 清稿、步骤/工具、nonfatal、引文、run.end.answer 覆盖 ──
        FakeBackend.route("/api/chat/stream") { _ in sse([
            SSE.frame("run.start", seq: 0, payload: ["session_id": "srv-1", "provider_selected": "p1"]),
            SSE.frame("step.start", seq: 1, payload: ["index": 0, "kind": "react"]),
            SSE.frame("tool.call", seq: 2, payload: ["name": "kb.search"]),
            SSE.frame("tool.result", seq: 3, payload: ["name": "kb.search", "ok": true, "duration_ms": 42]),
            SSE.frame("answer.delta", seq: 4, payload: ["text": "旧稿"]),
            SSE.frame("answer.delta", seq: 5, payload: ["text": "作废", "reset": false]),
            SSE.frame("error", seq: 6, payload: ["message": "提示：检索降级", "nonfatal": true]),
            SSE.frame("step.start", seq: 7, payload: ["index": 1, "kind": "react"]),
            SSE.frame("tool.call", seq: 8, payload: ["name": "calc.flow"]),
            SSE.frame("tool.result", seq: 9, payload: ["name": "calc.flow", "ok": false, "duration_ms": 7]),
            SSE.frame("answer.delta", seq: 10, payload: ["text": "新稿", "reset": true]),
            SSE.frame("answer.delta", seq: 11, payload: ["text": "第二段"]),
            SSE.frame("unknown.event", seq: 12, payload: ["x": 1]),
            SSE.frame("run.end", seq: 13, payload: [
                "terminal": "answered", "wall_ms": 1234,
                "citations": [["kind": "rag", "source": "doc-42", "label": "规范第3条"],
                              ["kind": "tool", "source": "calc.flow"]]]),
        ]) }
        await m.send("第一问")
        let b1 = chatBodies().first ?? [:]
        Accept.expect(b1["message"] as? String == "第一问" && b1["paradigm"] as? String == "react",
                      "send: 请求 body 含 message 与 paradigm=react", "\(b1)")
        Accept.expect(b1["session_id"] == nil && b1["image_ids"] == nil,
                      "send: 首问不带 session_id / image_ids", "\(b1)")
        Accept.expect(!m.streaming && m.draftQuestion == nil && m.draftAnswer.isEmpty,
                      "send: 结束后流式态与草稿清空")
        Accept.expect(m.turns.count == 1, "send: 一问一答固化成 1 个 turn", "turns=\(m.turns.count)")
        let t1 = m.turns.first
        Accept.expect(t1?.question == "第一问" && t1?.terminal == "answered" && t1?.wallMs == 1234,
                      "turn: 问题/终态/wall_ms 正确", "\(String(describing: t1))")
        Accept.expect(t1?.answer == "新稿第二段",
                      "delta: 累积拼接且 reset=true 清掉旧稿重接（无 run.end.answer 时用拼接结果）",
                      "answer=\(t1?.answer ?? "nil")")
        let steps = t1?.steps ?? []
        Accept.expect(steps.map(\.index) == [0, 1], "steps: step.start 进入 turn.steps", "\(steps)")
        Accept.expect(steps.count == 2
                      && steps[0].tools.map(\.name) == ["kb.search"] && steps[0].tools.first?.ok == true
                      && steps[0].tools.first?.durationMs == 42
                      && steps[1].tools.map(\.name) == ["calc.flow"] && steps[1].tools.first?.ok == false,
                      "steps: tool.call/tool.result 记到对应步（名称、成败、耗时）", "\(steps)")
        let cites = t1?.citations ?? []
        Accept.expect(cites.count == 2 && cites[0].kind == "rag" && cites[0].source == "doc-42"
                      && cites[0].label == "规范第3条" && cites[1].source == "calc.flow" && cites[1].label == nil,
                      "citations: run.end 引文保存进 turn", "\(cites)")
        Accept.expect(m.failure == nil && t1?.notices == ["提示：检索降级"],
                      "nonfatal error: 记为提示、不进错误态、run 继续到 answered",
                      "failure=\(String(describing: m.failure)) notices=\(t1?.notices ?? [])")
        Accept.expect(m.session.serverSessionId == "srv-1", "run.start: 记住服务端 session_id",
                      "\(String(describing: m.session.serverSessionId))")
        Accept.expect(m.session.pendingRun == nil, "run.end: 欠账清零")

        // ── 2. 第二问：带上 server session_id；run.end.answer 权威覆盖；fatal 后 run.end 兜底清错 ──
        FakeBackend.route("/api/chat/stream") { _ in sse([
            SSE.frame("run.start", seq: 0, runId: "run-2", payload: ["session_id": "srv-OTHER"]),
            SSE.frame("answer.delta", seq: 1, runId: "run-2", payload: ["text": "拼接的"]),
            SSE.frame("error", seq: 2, runId: "run-2", payload: ["message": "工具崩了"]),
            SSE.frame("run.end", seq: 3, runId: "run-2",
                      payload: ["terminal": "answered_degraded", "answer": "权威成稿"]),
        ]) }
        await m.send("第二问")
        let b2 = chatBodies().last ?? [:]
        Accept.expect(chatBodies().count == 2 && b2["session_id"] as? String == "srv-1"
                      && b2["message"] as? String == "第二问",
                      "多轮: 第二问 body 带 run.start 给的 session_id", "\(b2)")
        Accept.expect(m.session.serverSessionId == "srv-1",
                      "多轮: 已有 server session_id 不被后续 run.start 覆盖",
                      "\(String(describing: m.session.serverSessionId))")
        Accept.expect(m.turns.count == 2 && m.turns.last?.answer == "权威成稿",
                      "run.end.answer: 覆盖 delta 拼接结果", "\(m.turns.last?.answer ?? "nil")")
        Accept.expect(m.turns.last?.terminal == "answered_degraded"
                      && ChatModel.terminalLabel("answered_degraded") != nil,
                      "终态: answered_degraded 如实保存且有标注")
        Accept.expect(m.failure == nil, "fatal error 后跟 run.end: 权威终态清掉错误态",
                      "\(String(describing: m.failure))")

        // ── 3. 持久化：同目录新建 SessionStore 读回 ──
        let firstId = m.session.id
        let reread = SessionStore(baseDir: dir)
        let back = reread.sessions.first { $0.id == firstId }
        Accept.expect(back != nil && back?.serverSessionId == "srv-1"
                      && back?.turns.map(\.answer) == ["新稿第二段", "权威成稿"]
                      && back?.turns.first?.citations.first?.source == "doc-42"
                      && back?.turns.first?.steps.count == 2,
                      "持久化: 新 SessionStore(同目录) 读回会话、答案、引文、步骤",
                      "\(String(describing: back))")
        let m2 = ChatModel(store: SessionStore(baseDir: dir))
        Accept.expect(m2.session.id == firstId && m2.turns.count == 2,
                      "持久化: 新 ChatModel 启动落在最近会话上", "id=\(m2.session.id) turns=\(m2.turns.count)")

        // ── 4. 多会话 newSession / switchTo / deleteSession ──
        m.newSession()
        let secondId = m.session.id
        Accept.expect(secondId != firstId && m.turns.isEmpty && m.session.serverSessionId == nil,
                      "newSession: 新会话为空且无 server session_id")
        Accept.expect(!m.store.sessions.contains { $0.id == secondId },
                      "newSession: 空会话不落盘（首问后才保存）")
        FakeBackend.route("/api/chat/stream") { _ in sse([
            SSE.frame("run.start", seq: 0, runId: "run-3", payload: ["session_id": "srv-2"]),
            SSE.frame("run.end", seq: 1, runId: "run-3", payload: ["terminal": "answered", "answer": "新会话答案"]),
        ]) }
        await m.send("新会话问题")
        let b3 = chatBodies().last ?? [:]
        Accept.expect(b3["session_id"] == nil, "newSession: 新会话首问不带旧 session_id", "\(b3)")
        Accept.expect(m.store.sessions.count == 2 && m.session.serverSessionId == "srv-2"
                      && m.turns.map(\.answer) == ["新会话答案"],
                      "newSession: 首问后保存为第二个会话", "count=\(m.store.sessions.count)")
        m.switchTo(firstId)
        Accept.expect(m.session.id == firstId && m.turns.count == 2 && m.session.serverSessionId == "srv-1",
                      "switchTo: 切回旧会话，历史与 server session_id 恢复")
        m.switchTo("不存在的会话")
        Accept.expect(m.session.id == firstId, "switchTo: 未知 id 不切换")
        m.deleteSession(secondId)
        Accept.expect(m.session.id == firstId && !m.store.sessions.contains { $0.id == secondId }
                      && !FileManager.default.fileExists(atPath: dir.appendingPathComponent("session-\(secondId).json").path),
                      "deleteSession: 删除非当前会话，文件与索引都移除，当前会话不动")
        m.deleteSession(firstId)
        Accept.expect(m.session.id != firstId && m.store.sessions.isEmpty && m.turns.isEmpty,
                      "deleteSession: 删除当前且唯一会话后落到新空会话",
                      "sessions=\(m.store.sessions.count)")
        Accept.expect(SessionStore(baseDir: dir).sessions.isEmpty, "deleteSession: 盘上已无会话文件")

        // ── 5. 图片附件：attach → multipart 上传 → image_id 进下一问 body ──
        FakeBackend.route("/api/vision/upload") { _ in jsonReply(["image_id": "img-7", "w": 64, "h": 48]) }
        let img = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 48)).image { ctx in
            ctx.cgContext.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
        }
        guard let auth = try? AIConsent.capture() else {
            Accept.expect(false, "attach: 授权可捕获"); Accept.finish("授权捕获失败")
        }
        await m.attach(img, authorization: auth)
        let up = FakeBackend.requests.last { $0.url.path == "/api/vision/upload" }
        let ctype = up?.headers["Content-Type"] ?? ""
        let bodyStr = String(decoding: up?.body ?? Data(), as: UTF8.self)
        let hasJPEG = (up?.body ?? Data()).range(of: Data([0xFF, 0xD8, 0xFF])) != nil
        Accept.expect(up?.method == "POST" && ctype.hasPrefix("multipart/form-data; boundary=")
                      && bodyStr.contains("name=\"file\"; filename=\"photo.jpg\"")
                      && bodyStr.contains("Content-Type: image/jpeg") && hasJPEG,
                      "attach: 走 /api/vision/upload multipart（字段 file、JPEG 内容）",
                      "method=\(up?.method ?? "nil") ctype=\(ctype) bytes=\(up?.body.count ?? 0)")
        Accept.expect(m.attachments.map(\.id) == ["img-7"] && !m.uploadingImage && m.failure == nil,
                      "attach: 拿到 image_id 作为附件", "\(m.attachments.map(\.id)) \(String(describing: m.failure))")
        FakeBackend.route("/api/chat/stream") { _ in sse([
            SSE.frame("run.start", seq: 0, runId: "run-4", payload: ["session_id": "srv-3"]),
            SSE.frame("run.end", seq: 1, runId: "run-4", payload: ["terminal": "answered", "answer": "看图答"]),
        ]) }
        await m.send("看这张图")
        let b4 = chatBodies().last ?? [:]
        Accept.expect(b4["image_ids"] as? [String] == ["img-7"], "attach: 下一问 body 的 image_ids 带上该图", "\(b4)")
        Accept.expect(m.attachments.isEmpty && m.turns.last?.imageCount == 1,
                      "attach: run.start 后附件清空，turn 记图片数", "att=\(m.attachments.count) img=\(m.turns.last?.imageCount ?? -1)")
        // uploadJPEG 直调同路径
        let direct = try? await Backend.uploadJPEG(Data([0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3]), authorization: auth)
        Accept.expect(direct == "img-7", "uploadJPEG: 直调解析 image_id", "\(String(describing: direct))")
        FakeBackend.route("/api/vision/upload") { _ in jsonReply(["w": 1]) }
        var missing = false
        do { _ = try await Backend.uploadJPEG(Data([0xFF, 0xD8]), authorization: auth) }
        catch let e as BackendError { if case .contract = e { missing = true } } catch {}
        Accept.expect(missing, "uploadJPEG: 响应缺 image_id 报契约错误而非猜值")

        // ── 6. 引文回原文：POST /api/tools/kb.read_doc/invoke ──
        FakeBackend.route("/api/tools/kb.read_doc/invoke") { _ in jsonReply([
            "ok": true, "result": ["title": "防洪标准", "display_path": "规范/GB50201.md",
                                   "text": "第一章 总则", "truncated": true, "next_offset": 4000]]) }
        let page = try? await Backend.readDoc(docId: "doc-42")
        let rd = FakeBackend.requests.last { $0.url.path == "/api/tools/kb.read_doc/invoke" }
        let args = json(rd?.body ?? Data())["args"] as? [String: Any] ?? [:]
        Accept.expect(rd?.method == "POST" && args["doc_id"] as? String == "doc-42"
                      && args["offset"] as? Int == 0 && args["max_chars"] as? Int == 4000,
                      "readDoc: POST kb.read_doc/invoke，args 含 doc_id/offset/max_chars", "\(args)")
        Accept.expect(page?.title == "防洪标准" && page?.displayPath == "规范/GB50201.md"
                      && page?.text == "第一章 总则" && page?.nextOffset == 4000,
                      "readDoc: 解析 title/display_path/text/next_offset", "\(String(describing: page))")
        FakeBackend.route("/api/tools/kb.read_doc/invoke") { _ in jsonReply([
            "ok": true, "result": ["text": "末页", "truncated": false, "next_offset": 9999]]) }
        let last = try? await Backend.readDoc(docId: "doc-9", offset: 4000)
        Accept.expect(last?.title == "doc-9" && last?.nextOffset == nil && last?.text == "末页",
                      "readDoc: 未截断时无下一页，标题缺省回 doc_id", "\(String(describing: last))")
        FakeBackend.route("/api/tools/kb.read_doc/invoke") { _ in jsonReply([
            "ok": false, "error": ["code": "not_found", "message": "文档不存在"]]) }
        var errMsg = ""
        do { _ = try await Backend.readDoc(docId: "nope") }
        catch let e as BackendError { if case .contract(let s) = e { errMsg = s } } catch {}
        Accept.expect(errMsg == "文档不存在", "readDoc: ok=false 抛出后端原话", errMsg)

        Accept.finish("生产 send/attach/readDoc 路径 + SessionStore 持久化与多会话，共 \(FakeBackend.requests.count) 次本地请求")
    }
}
